import Foundation
import Observation
import GoalsCore

/// Backs the Goals list (docs/PLAN.md §2.2 tab 2).
@MainActor
@Observable
final class GoalsListViewModel {
    struct Row: Identifiable {
        let goal: Goal
        let milestoneProgress: Double
        let completedMilestones: Int
        let totalMilestones: Int
        var id: UUID { goal.id }
    }

    private let app: AppContainer
    var rows: [Row] = []

    init(app: AppContainer) { self.app = app }

    func load() {
        rows = app.store.allGoals().map { goal in
            let plan = app.store.plan(for: goal.id)
            let milestones = plan?.milestones ?? []
            let done = milestones.filter { $0.status == .completed }.count
            let total = max(milestones.count, 1)
            return Row(goal: goal,
                       milestoneProgress: Double(done) / Double(total),
                       completedMilestones: done,
                       totalMilestones: milestones.count)
        }
    }
}

/// Backs a single goal's detail (milestones, upcoming tasks, plan history) and
/// its lifecycle + adaptation actions (docs/PLAN.md §2.2, §5).
@MainActor
@Observable
final class GoalDetailViewModel {
    private let app: AppContainer
    let goalID: UUID

    var plan: Plan?
    var upcoming: [TaskOccurrence] = []
    var revisions: [PlanRevision] = []
    var snapshot: PerformanceSnapshot?

    // Adaptation preview state.
    var isProposing = false
    var proposedResult: ReplanService.Result?
    var proposalError: String?

    init(app: AppContainer, goalID: UUID) {
        self.app = app
        self.goalID = goalID
    }

    func load() {
        plan = app.store.plan(for: goalID)
        revisions = app.store.revisions(goalID: goalID)
        if let plan { snapshot = app.performance.snapshot(for: plan) }
        let today = app.clock.today
        upcoming = app.store.occurrences(goalID: goalID)
            .filter { $0.day >= today && $0.status == .pending }
            .sorted { ($0.day, $0.window?.start ?? 0) < ($1.day, $1.window?.start ?? 0) }
    }

    var completionRate: Double { snapshot?.overallCompletionRate ?? 0 }

    // MARK: Adaptation

    func proposeRevision(userMessage: String? = nil, trigger: RevisionTrigger = .userRequest) async {
        isProposing = true
        proposalError = nil
        defer { isProposing = false }
        do {
            proposedResult = try await app.planEngine.proposeRevision(
                goalID: goalID, trigger: trigger, userMessage: userMessage)
        } catch {
            proposalError = "I couldn't put together a change just now — try again in a moment."
        }
    }

    func acceptProposal() {
        guard let result = proposedResult, !result.diff.isQuestionOnly else { return }
        app.planEngine.apply(diff: result.diff, to: goalID, trigger: result.trigger)
        proposedResult = nil
        load()
    }

    /// Mark a concrete series unit (a chapter) done — routed through `PlanEngine`
    /// like any plan change (validate → apply → record → reschedule).
    func markUnitComplete(_ unitID: UUID) {
        guard let title = plan?.goal.specifics?.seriesUnits.first(where: { $0.id == unitID })?.title else { return }
        let diff = PlanDiff(summary: "Marked “\(title)” done",
                            operations: [PlanOperation(kind: .markUnitComplete, targetUnitID: unitID,
                                                       note: "Mark “\(title)” done")])
        app.planEngine.apply(diff: diff, to: goalID, trigger: .userRequest)
        load()
    }

    func rejectProposal() {
        if let result = proposedResult {
            app.planEngine.recordRejected(diff: result.diff, goalID: goalID, trigger: result.trigger)
        }
        proposedResult = nil
        load()
    }

    // MARK: Lifecycle

    func pause() { app.planEngine.setStatus(.paused, for: goalID); load() }
    func resume() { app.planEngine.setStatus(.active, for: goalID); load() }
    func complete() { app.planEngine.setStatus(.completed, for: goalID); load() }
    func abandon(reason: String?) { app.planEngine.setStatus(.abandoned, for: goalID, reason: reason); load() }
}
