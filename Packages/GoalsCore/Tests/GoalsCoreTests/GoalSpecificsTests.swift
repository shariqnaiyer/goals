import XCTest
@testable import GoalsCore

/// Phase 1 spec: the concrete-object model (`GoalSpecifics`), its wire format,
/// `materialise` carrying it through, and the `Sequencer` that stamps a concrete
/// `SessionSlice` ("Chapter 4") onto each sequential session.
final class GoalSpecificsTests: XCTestCase {

    // MARK: Codable wire format

    func testReadingSpecificsRoundTripsWithKindDiscriminator() throws {
        let specifics = GoalSpecifics.reading(
            .numbered(bookTitle: "Atomic Habits", chapterCount: 20))
        let data = try JSONEncoder().encode(specifics)
        let json = String(decoding: data, as: UTF8.self)
        // Explicit, stable discriminator (not Swift's synthesized "_0" shape).
        XCTAssertTrue(json.contains("\"kind\":\"reading\""), json)
        let decoded = try JSONDecoder().decode(GoalSpecifics.self, from: data)
        XCTAssertEqual(decoded, specifics)
        XCTAssertEqual(decoded.seriesUnits.count, 20)
        XCTAssertEqual(decoded.unitNoun, "chapter")
        XCTAssertEqual(decoded.displayName, "Atomic Habits")
    }

    func testFitnessSpecificsRoundTripsWithRoutines() throws {
        let specifics = GoalSpecifics.fitness(
            FitnessSpecifics(baseline: "sedentary", target: "run 5K", programName: "Couch to 5K",
                             routines: [Routine(name: "Run A", exercises: [
                                ExercisePrescription(name: "Easy jog", sets: 1, reps: "20 min")])]))
        let data = try JSONEncoder().encode(specifics)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"kind\":\"fitness\""))
        XCTAssertEqual(try JSONDecoder().decode(GoalSpecifics.self, from: data), specifics)
        XCTAssertEqual(specifics.displayName, "Couch to 5K")
        XCTAssertEqual(specifics.routines.count, 1)
        XCTAssertEqual(specifics.unitNoun, "workout")
    }

    func testLegacyGoalDecodesWithoutHorizonOrParent() throws {
        // A goal written before horizon/parent existed must still decode, defaulting
        // to long-term (effectiveHorizon).
        let goal = Goal(title: "Run a 10k", type: .outcome)
        let data = try JSONEncoder().encode(goal)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("horizon"))
        XCTAssertFalse(json.contains("parentGoalID"))
        let decoded = try JSONDecoder().decode(Goal.self, from: data)
        XCTAssertNil(decoded.horizon)
        XCTAssertEqual(decoded.effectiveHorizon, .longTerm)
    }

    func testSequencerRotatesThroughRoutines() {
        let a = Routine(name: "Workout A", exercises: [ExercisePrescription(name: "Squat", sets: 5, reps: "5")])
        let b = Routine(name: "Workout B", exercises: [ExercisePrescription(name: "Deadlift", sets: 1, reps: "5")])
        let specifics = GoalSpecifics.fitness(FitnessSpecifics(programName: "5×5", routines: [a, b]))
        let goal = Goal(title: "Strength", type: .outcome, specifics: specifics)
        let template = TaskTemplate(goalID: goal.id, title: "Workout", effortMinutes: 45,
                                    recurrence: .daily(),
                                    detail: .rotating(routineIDs: [a.id, b.id]))
        let plan = Plan(goal: goal, milestones: [], templates: [template])
        let pending = (0..<4).map { i in
            TaskOccurrence(templateID: template.id, goalID: goal.id, title: "Workout",
                           effortMinutes: 45, day: Fixtures.day(i),
                           window: MinuteWindow(startHour: 7, endHour: 8))
        }
        let result = Sequencer.assignSlices(pending: pending, specifics: specifics, templates: plan.templates)
        XCTAssertEqual(result.map { $0.slice?.label }, ["Workout A", "Workout B", "Workout A", "Workout B"])
        XCTAssertEqual(result.first?.slice?.detail, "Squat · 5×5")
    }

    func testGenericSpecificsRoundTrips() throws {
        let specifics = GoalSpecifics.generic(
            GenericSpecifics(unitNoun: "lesson",
                             units: [SeriesUnit(order: 0, title: "Lesson 1"),
                                     SeriesUnit(order: 1, title: "Lesson 2")]))
        let data = try JSONEncoder().encode(specifics)
        XCTAssertEqual(try JSONDecoder().decode(GoalSpecifics.self, from: data), specifics)
        XCTAssertEqual(specifics.unitNoun, "lesson")
        XCTAssertNil(specifics.displayName)
    }

    func testTemplateDetailRoundTrips() throws {
        for detail in [TemplateDetail.sequential, .rotating(routineIDs: [UUID(), UUID()])] {
            let data = try JSONEncoder().encode(detail)
            XCTAssertEqual(try JSONDecoder().decode(TemplateDetail.self, from: data), detail)
        }
    }

    // MARK: Legacy decode (additive fields stay backward compatible)

    func testLegacyGoalDecodesWithoutSpecificsKey() throws {
        // A goal with no specifics encodes without the key — exactly how a row
        // written before this feature looks — and must decode to nil.
        let goal = Goal(title: "Run a 10k", type: .outcome)
        let data = try JSONEncoder().encode(goal)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("specifics"))
        let decoded = try JSONDecoder().decode(Goal.self, from: data)
        XCTAssertNil(decoded.specifics)
    }

    func testLegacyOccurrenceDecodesWithoutSliceKey() throws {
        let occ = TaskOccurrence(templateID: UUID(), goalID: UUID(),
                                 title: "Run", effortMinutes: 30, day: Fixtures.day(0))
        let data = try JSONEncoder().encode(occ)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("slice"))
        XCTAssertNil(try JSONDecoder().decode(TaskOccurrence.self, from: data).slice)
    }

    // MARK: materialise carries specifics + detail into persisted entities

    func testMaterialiseLiftsSpecificsOntoGoalAndDetailOntoTemplate() {
        let spec = GoalSpec(title: "Finish Atomic Habits", motivationStatement: "",
                            type: .outcome, successCriteria: "", targetDate: nil,
                            currentLevel: "", weeklyBudgetMinutes: 150,
                            isComplete: true, nextQuestion: nil)
        let proposal = PlanProposal(
            goalTitle: "Finish Atomic Habits", successCriteria: "Read all chapters",
            milestones: [ProposedMilestone(key: "m1", title: "Read", order: 0,
                                           completionCriteria: "", targetDate: nil)],
            templates: [ProposedTemplate(title: "Reading session", milestoneKey: "m1",
                                         effortMinutes: 20, cadence: .timesPerWeek,
                                         weekdays: [.monday], timesPerWeek: 5, intervalDays: 1,
                                         preferredTimeOfDay: .evening, flexibility: .flexible,
                                         minimumViableVariant: "Read 2 pages",
                                         detail: .sequential)],
            specifics: .reading(.numbered(bookTitle: "Atomic Habits", chapterCount: 20)))

        let plan = proposal.materialise(spec: spec, calendar: Fixtures.calendar,
                                        now: Fixtures.monday.date(calendar: Fixtures.calendar))
        XCTAssertEqual(plan.goal.specifics?.displayName, "Atomic Habits")
        XCTAssertEqual(plan.goal.specifics?.totalUnitCount, 20)
        XCTAssertEqual(plan.templates.first?.detail, .sequential)
    }

    // MARK: Sequencer

    private func readingPlan(chapterCount: Int = 5) -> (Plan, GoalSpecifics) {
        let goal = Goal(title: "Finish Atomic Habits", type: .outcome,
                        specifics: .reading(.numbered(bookTitle: "Atomic Habits",
                                                      chapterCount: chapterCount)))
        let template = TaskTemplate(goalID: goal.id, title: "Reading session",
                                    effortMinutes: 20, recurrence: .daily(),
                                    detail: .sequential)
        return (Plan(goal: goal, milestones: [], templates: [template]), goal.specifics!)
    }

    private func pendingOccurrences(_ plan: Plan, days: Int) -> [TaskOccurrence] {
        let template = plan.templates[0]
        return (0..<days).map { i in
            TaskOccurrence(templateID: template.id, goalID: plan.goal.id,
                           title: template.title, effortMinutes: 20,
                           day: Fixtures.day(i), window: MinuteWindow(startHour: 21, endHour: 22))
        }
    }

    func testSequencerWalksTheSeriesInOrder() {
        let (plan, _) = readingPlan(chapterCount: 5)
        let pending = pendingOccurrences(plan, days: 3)
        let result = Sequencer.assignSlices(pending: pending, specifics: plan.goal.specifics,
                                            templates: plan.templates)
        XCTAssertEqual(result.map { $0.slice?.label }, ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    func testSequencerNeverReassignsConsumedUnits() {
        let (plan, specifics) = readingPlan(chapterCount: 5)
        // Chapters 1 and 2 already read.
        let consumed = Set(specifics.seriesUnits.prefix(2).map(\.id))
        let pending = pendingOccurrences(plan, days: 3)
        let result = Sequencer.assignSlices(pending: pending, specifics: plan.goal.specifics,
                                            templates: plan.templates, consumedUnitIDs: consumed)
        XCTAssertEqual(result.map { $0.slice?.label }, ["Chapter 3", "Chapter 4", "Chapter 5"])
    }

    func testSequencerLeavesSessionsPastTheLastUnitUnsliced() {
        let (plan, _) = readingPlan(chapterCount: 2)
        let pending = pendingOccurrences(plan, days: 4)
        let result = Sequencer.assignSlices(pending: pending, specifics: plan.goal.specifics,
                                            templates: plan.templates)
        XCTAssertEqual(result.map { $0.slice?.label }, ["Chapter 1", "Chapter 2", nil, nil])
    }

    func testSequencerIsNoOpWithoutSpecificsOrSequentialTemplate() {
        let (plan, _) = readingPlan(chapterCount: 5)
        let pending = pendingOccurrences(plan, days: 2)
        // No specifics → untouched.
        XCTAssertTrue(Sequencer.assignSlices(pending: pending, specifics: nil,
                                             templates: plan.templates).allSatisfy { $0.slice == nil })
        // Specifics present but the template isn't sequential → untouched.
        let plainTemplate = TaskTemplate(goalID: plan.goal.id, title: "Reading session",
                                         effortMinutes: 20, recurrence: .daily())
        let plainPending = pending.map { occ -> TaskOccurrence in
            var c = occ; c.templateID = plainTemplate.id; return c
        }
        XCTAssertTrue(Sequencer.assignSlices(pending: plainPending, specifics: plan.goal.specifics,
                                             templates: [plainTemplate]).allSatisfy { $0.slice == nil })
    }

    // MARK: MockLLMService emits reading specifics end to end

    func testMockGeneratePlanEmitsReadingSpecificsForReadingGoal() async throws {
        let mock = MockLLMService(calendar: Fixtures.calendar)
        let spec = GoalSpec(title: "Read Atomic Habits", motivationStatement: "",
                            type: .outcome, successCriteria: "", targetDate: nil,
                            currentLevel: "", weeklyBudgetMinutes: 150,
                            isComplete: true, nextQuestion: nil)
        let proposal = try await mock.generatePlan(spec: spec, profile: .makeDefault())
        guard case .reading(let reading)? = proposal.specifics else {
            return XCTFail("expected reading specifics, got \(String(describing: proposal.specifics))")
        }
        XCTAssertEqual(reading.bookTitle, "Atomic Habits")
        XCTAssertEqual(proposal.templates.first?.detail, .sequential)
    }

    func testMockGeneratePlanLeavesNonReadingGoalsGeneric() async throws {
        let mock = MockLLMService(calendar: Fixtures.calendar)
        let spec = GoalSpec(title: "Run a 10k", motivationStatement: "",
                            type: .outcome, successCriteria: "", targetDate: nil,
                            currentLevel: "", weeklyBudgetMinutes: 150,
                            isComplete: true, nextQuestion: nil)
        let proposal = try await mock.generatePlan(spec: spec, profile: .makeDefault())
        XCTAssertNil(proposal.specifics)
        XCTAssertNil(proposal.templates.first?.detail)
    }
}
