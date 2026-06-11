import XCTest
@testable import GoalsCore

/// Phase 2 spec: the deterministic concreteness gate and the `onboardingTurn`
/// stage machine that is the offline oracle for the Guided Discovery Interview.
final class OnboardingTests: XCTestCase {

    // MARK: ConcretenessCheck truth table

    private func concreteReading() -> AspirationDraft {
        AspirationDraft(id: "a", rawWish: "read more", title: "Finish Atomic Habits",
                        type: .outcome, status: .exploring,
                        specifics: .reading(.numbered(bookTitle: "Atomic Habits", chapterCount: 12)),
                        successCriteria: "Finish Atomic Habits.",
                        weeklyBudgetMinutes: 105, suggestedTimesPerWeek: 5,
                        resolvedDimensions: ConcretenessDimension.allCases)
    }

    func testGatePassesForAFullyConcreteAspiration() {
        XCTAssertTrue(ConcretenessCheck.isConcrete(concreteReading()))
    }

    func testGateFailsWithAnyRequiredDimensionUnresolved() {
        var a = concreteReading()
        a.resolvedDimensions = [.object, .startState, .targetState, .cadence] // missing .capacity
        XCTAssertFalse(ConcretenessCheck.isConcrete(a))
        XCTAssertEqual(ConcretenessCheck.missingDimensions(a), [.capacity])
    }

    func testGateRejectsReadingGoalWithoutANamedBook() {
        // The model marked every dimension resolved but never pinned the book —
        // Swift's independent field check (rule 2) rejects it anyway.
        var a = concreteReading()
        a.specifics = nil
        XCTAssertFalse(ConcretenessCheck.isConcrete(a), "you cannot 'read' without a book")
    }

    func testGateRejectsTitleEqualToRawWish() {
        var a = concreteReading()
        a.title = a.rawWish
        XCTAssertFalse(ConcretenessCheck.isConcrete(a))
    }

    func testGateRejectsZeroCapacityOrCadence() {
        var a = concreteReading()
        a.weeklyBudgetMinutes = 0
        XCTAssertFalse(ConcretenessCheck.isConcrete(a))
        a = concreteReading()
        a.suggestedTimesPerWeek = 0
        XCTAssertFalse(ConcretenessCheck.isConcrete(a))
    }

    func testHabitGoalDoesNotRequireTargetState() {
        var a = concreteReading()
        a.type = .habit
        a.specifics = nil           // not series-based
        a.rawWish = "meditate"; a.title = "Meditate daily"
        a.successCriteria = "Meditate most days."
        a.resolvedDimensions = [.object, .startState, .cadence, .capacity] // no .targetState
        XCTAssertTrue(ConcretenessCheck.isConcrete(a))
    }

    // MARK: canFormalize (capacity cap for 1–3 goals)

    private func groundedState(_ aspirations: [AspirationDraft]) -> OnboardingState {
        OnboardingState(person: PersonSketch(oneLine: "Dev, two kids", dailyShape: "evenings are quiet"),
                        aspirations: aspirations,
                        focusAspirationIDs: aspirations.map(\.id),
                        stage: .readyToFormalize)
    }

    func testCanFormalizeWithRoomInTheWeek() {
        let state = groundedState([concreteReading()])
        XCTAssertTrue(ConcretenessCheck.canFormalize(state, availableWeeklyMinutes: 840))
    }

    func testCannotFormalizeWhenCombinedBudgetExceedsCapacity() {
        var a = concreteReading(); a.weeklyBudgetMinutes = 600
        var b = concreteReading(); b.id = "b"; b.weeklyBudgetMinutes = 600
        let state = groundedState([a, b]) // 1200 minutes
        XCTAssertFalse(ConcretenessCheck.canFormalize(state, availableWeeklyMinutes: 840))
        XCTAssertTrue(ConcretenessCheck.blockers(state, availableWeeklyMinutes: 840)
            .contains { $0.contains("more time than your week") })
    }

    func testCannotFormalizeUngroundedOrUnconcrete() {
        var a = concreteReading(); a.resolvedDimensions = [] // not concrete
        let state = groundedState([a])
        XCTAssertFalse(ConcretenessCheck.canFormalize(state, availableWeeklyMinutes: 840))
    }

    // MARK: Scripted onboardingTurn runs

    private let mock = MockLLMService(calendar: Fixtures.calendar)

    /// Drive grounding + surfacing, returning the state with aspirations surfaced.
    private func driveToSurfaced(_ goalsText: String) async throws -> OnboardingState {
        var r = try await mock.onboardingTurn(state: OnboardingState(),
            latestUserText: "I'm a developer with two young kids; evenings after 9 are my only quiet time, and I want more headspace.")
        XCTAssertEqual(r.stage, .surfacing)
        XCTAssertTrue(r.state.person.isGrounded)
        r = try await mock.onboardingTurn(state: r.state, latestUserText: goalsText)
        XCTAssertEqual(r.stage, .surfacing)
        XCTAssertFalse(r.state.aspirations.isEmpty)
        return r.state
    }

    func testScriptedReadingOnboardingReachesReadyAndIsConcrete() async throws {
        var state = try await driveToSurfaced("I want to read more")
        // Simulate the user tapping the (only) aspiration to start now.
        state.focusAspirationIDs = [state.aspirations[0].id]

        var r = try await mock.onboardingTurn(state: state, latestUserText: "")
        XCTAssertEqual(r.stage, .concretizing)
        XCTAssertFalse(r.choices.isEmpty, "object probe should offer book chips")

        r = try await mock.onboardingTurn(state: r.state, latestUserText: "Atomic Habits")
        XCTAssertEqual(r.stage, .readyToFormalize)

        let asp = r.state.focusAspirations[0]
        XCTAssertTrue(ConcretenessCheck.isConcrete(asp))
        guard case .reading(let reading)? = asp.specifics else {
            return XCTFail("expected reading specifics")
        }
        XCTAssertEqual(reading.bookTitle, "Atomic Habits")
        XCTAssertTrue(ConcretenessCheck.canFormalize(r.state, availableWeeklyMinutes: 840))
    }

    func testScriptedFitnessGoalProbesObjectThenStartState() async throws {
        var state = try await driveToSurfaced("I want to get fit")
        state.focusAspirationIDs = [state.aspirations[0].id]

        // First probe: object.
        var r = try await mock.onboardingTurn(state: state, latestUserText: "")
        XCTAssertEqual(r.stage, .concretizing)
        XCTAssertFalse(ConcretenessCheck.isConcrete(r.state.focusAspirations[0]),
                       "fitness shouldn't concretize from a single answer like reading does")

        // Walk the remaining probes until the gate passes (object → start → target → cadence → capacity).
        var guardCount = 0
        while r.stage == .concretizing && guardCount < 8 {
            r = try await mock.onboardingTurn(state: r.state, latestUserText: "30 minutes, three days a week")
            guardCount += 1
        }
        XCTAssertEqual(r.stage, .readyToFormalize)
        XCTAssertTrue(ConcretenessCheck.isConcrete(r.state.focusAspirations[0]))
    }

    func testScriptedFitnessGoalProducesTypedRoutines() async throws {
        var state = try await driveToSurfaced("I want to build strength")
        state.focusAspirationIDs = [state.aspirations[0].id]
        var r = try await mock.onboardingTurn(state: state, latestUserText: "")
        var guardCount = 0
        while r.stage == .concretizing && guardCount < 8 {
            r = try await mock.onboardingTurn(state: r.state, latestUserText: "Build strength, 45 minutes, three days")
            guardCount += 1
        }
        XCTAssertEqual(r.stage, .readyToFormalize)
        let asp = r.state.focusAspirations[0]
        guard case .fitness(let fitness)? = asp.specifics else {
            return XCTFail("expected fitness specifics, got \(String(describing: asp.specifics))")
        }
        XCTAssertFalse(fitness.routines.isEmpty)
        XCTAssertTrue(fitness.routines.allSatisfy { !$0.exercises.isEmpty })

        // And it generates a rotating-routine plan.
        let proposal = try await mock.generatePlan(spec: asp.toGoalSpec(), profile: .makeDefault())
        if case .rotating(let ids)? = proposal.templates.first?.detail {
            XCTAssertEqual(Set(ids), Set(fitness.routines.map(\.id)))
        } else {
            XCTFail("expected a rotating fitness template")
        }
    }

    func testScriptedMultiGoalConcretizesEachSelectedGoal() async throws {
        var state = try await driveToSurfaced("read more, get fit")
        XCTAssertGreaterThanOrEqual(state.aspirations.count, 2)
        state.focusAspirationIDs = Array(state.aspirations.prefix(2).map(\.id))

        var r = try await mock.onboardingTurn(state: state, latestUserText: "")
        var guardCount = 0
        while r.stage == .concretizing && guardCount < 14 {
            r = try await mock.onboardingTurn(state: r.state, latestUserText: "Atomic Habits, 30 minutes, three days")
            guardCount += 1
        }
        XCTAssertEqual(r.stage, .readyToFormalize)
        XCTAssertTrue(r.state.focusAspirations.allSatisfy(ConcretenessCheck.isConcrete),
                      "every selected goal must be concrete before formalizing")
    }
}
