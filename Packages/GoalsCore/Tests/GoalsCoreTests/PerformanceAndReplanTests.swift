import XCTest
@testable import GoalsCore

final class PerformanceAnalyzerTests: XCTestCase {

    private let cal = Fixtures.calendar

    private func occurrence(_ template: TaskTemplate, dayOffset: Int,
                            status: OccurrenceStatus,
                            windowStart: Int = 7 * 60) -> TaskOccurrence {
        TaskOccurrence(templateID: template.id, goalID: template.goalID,
                       title: template.title, effortMinutes: template.effortMinutes,
                       day: Fixtures.day(dayOffset),
                       window: MinuteWindow(start: windowStart, end: windowStart + template.effortMinutes),
                       status: status,
                       completedAt: status == .done ? Date() : nil)
    }

    func testMissStreakCountsRecentConsecutiveMisses() {
        let plan = Fixtures.plan()
        let t = plan.templates[0]
        let occs = [
            occurrence(t, dayOffset: 0, status: .done),
            occurrence(t, dayOffset: 1, status: .skipped),
            occurrence(t, dayOffset: 2, status: .skipped),
            occurrence(t, dayOffset: 3, status: .skipped)
        ]
        let analyzer = PerformanceAnalyzer(calendar: cal)
        let snap = analyzer.snapshot(plan: plan, occurrences: occs,
                                     windowStart: Fixtures.day(0), windowEnd: Fixtures.day(7),
                                     today: Fixtures.day(3))
        XCTAssertEqual(snap.templates.first?.currentMissStreak, 3)
        XCTAssertEqual(snap.templates.first?.completed, 1)
        XCTAssertFalse(snap.strugglingTemplates().isEmpty)
    }

    func testCompletionRateAndBestTime() {
        let plan = Fixtures.plan()
        let t = plan.templates[0]
        let occs = [
            occurrence(t, dayOffset: 0, status: .done, windowStart: 6 * 60),   // earlyMorning
            occurrence(t, dayOffset: 1, status: .done, windowStart: 6 * 60),   // earlyMorning
            occurrence(t, dayOffset: 2, status: .skipped, windowStart: 18 * 60)
        ]
        let analyzer = PerformanceAnalyzer(calendar: cal)
        let snap = analyzer.snapshot(plan: plan, occurrences: occs,
                                     windowStart: Fixtures.day(0), windowEnd: Fixtures.day(7),
                                     today: Fixtures.day(2))
        let perf = snap.templates.first!
        XCTAssertEqual(perf.completed, 2)
        XCTAssertEqual(perf.scheduled, 3)
        XCTAssertEqual(perf.bestTimeOfDay, .earlyMorning)
        XCTAssertEqual(perf.completionRate, 2.0 / 3.0, accuracy: 0.001)
    }
}

final class AdaptationPolicyTests: XCTestCase {

    func testOvercommitTakesPriority() {
        let plan = Fixtures.plan()
        let snap = PerformanceSnapshot(goalID: plan.goal.id,
                                       windowStart: Fixtures.day(0), windowEnd: Fixtures.day(7),
                                       templates: [], scheduledWeeklyMinutes: 500,
                                       weeklyBudgetMinutes: 300)
        XCTAssertEqual(AdaptationPolicy().evaluate(snapshot: snap, schedulerOvercommitted: false),
                       .overcommitted)
    }

    func testMissStreakTriggersAdaptation() {
        let plan = Fixtures.plan()
        let perf = TemplatePerformance(templateID: plan.templates[0].id, title: "Run",
                                       scheduled: 4, completed: 1, skipped: 3,
                                       currentMissStreak: 3, bestTimeOfDay: nil, averageDifficulty: nil)
        let snap = PerformanceSnapshot(goalID: plan.goal.id,
                                       windowStart: Fixtures.day(0), windowEnd: Fixtures.day(7),
                                       templates: [perf], scheduledWeeklyMinutes: 120,
                                       weeklyBudgetMinutes: 300)
        XCTAssertEqual(AdaptationPolicy().evaluate(snapshot: snap, schedulerOvercommitted: false),
                       .missedTasks)
    }

    func testNoTriggerWhenHealthy() {
        let plan = Fixtures.plan()
        let snap = PerformanceSnapshot(goalID: plan.goal.id,
                                       windowStart: Fixtures.day(0), windowEnd: Fixtures.day(7),
                                       templates: [], scheduledWeeklyMinutes: 120,
                                       weeklyBudgetMinutes: 300)
        XCTAssertNil(AdaptationPolicy().evaluate(snapshot: snap, schedulerOvercommitted: false))
    }
}

final class ReplanServiceTests: XCTestCase {

    /// A service that emits an invalid diff first, then a valid one — verifies
    /// the validate-and-retry loop feeds violations back and recovers.
    private struct FlakyLLM: LLMService {
        let validTemplateID: UUID
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()

        func interview(history: [ChatMessage], draft: GoalSpec?) async throws -> InterviewResult {
            fatalError("unused")
        }
        func generatePlan(spec: GoalSpec, profile: ConstraintProfile) async throws -> PlanProposal {
            fatalError("unused")
        }
        func replan(plan: Plan, snapshot: PerformanceSnapshot, trigger: RevisionTrigger,
                    userMessage: String?, priorViolations: [String]) async throws -> PlanDiff {
            counter.n += 1
            if counter.n == 1 {
                // Invalid: references a non-existent template.
                return PlanDiff(summary: "bad", operations: [
                    PlanOperation(kind: .pauseTemplate, targetTemplateID: UUID())
                ])
            }
            return PlanDiff(summary: "good", operations: [
                PlanOperation(kind: .pauseTemplate, targetTemplateID: validTemplateID)
            ])
        }
        func coachTurn(plan: Plan?, snapshot: PerformanceSnapshot?, history: [ChatMessage],
                       userMessage: String) async throws -> CoachReply { fatalError("unused") }
        func reviewNarrative(snapshot: PerformanceSnapshot, plan: Plan) async throws -> String {
            fatalError("unused")
        }
    }

    func testRetriesPastInvalidDiff() async throws {
        let plan = Fixtures.plan()
        let llm = FlakyLLM(validTemplateID: plan.templates[0].id)
        let service = ReplanService(llm: llm, validator: PlanValidator(calendar: Fixtures.calendar))
        let snap = PerformanceSnapshot(goalID: plan.goal.id,
                                       windowStart: Fixtures.day(0), windowEnd: Fixtures.day(7),
                                       templates: [], scheduledWeeklyMinutes: 120, weeklyBudgetMinutes: 300)
        let result = try await service.proposeRevision(plan: plan, snapshot: snap,
                                                       profile: .makeDefault(), trigger: .missedTasks)
        XCTAssertEqual(result.diff.summary, "good")
        XCTAssertFalse(result.previewPlan.templates[0].isActive)
        XCTAssertEqual(llm.counter.n, 2)
    }

    func testMockServiceProducesValidEasingDiff() async throws {
        let plan = Fixtures.plan()
        let analyzer = PerformanceAnalyzer(calendar: Fixtures.calendar)
        // Build a snapshot with a struggling template.
        let perf = TemplatePerformance(templateID: plan.templates[0].id, title: "Run",
                                       scheduled: 4, completed: 0, skipped: 4,
                                       currentMissStreak: 4, bestTimeOfDay: nil, averageDifficulty: nil)
        let snap = PerformanceSnapshot(goalID: plan.goal.id,
                                       windowStart: Fixtures.day(0), windowEnd: Fixtures.day(7),
                                       templates: [perf], scheduledWeeklyMinutes: 120, weeklyBudgetMinutes: 300)
        let service = ReplanService(llm: MockLLMService(calendar: Fixtures.calendar),
                                    validator: PlanValidator(calendar: Fixtures.calendar))
        let result = try await service.proposeRevision(plan: plan, snapshot: snap,
                                                       profile: .makeDefault(), trigger: .missedTasks)
        XCTAssertFalse(result.diff.operations.isEmpty)
        _ = analyzer // silence unused in case
    }
}
