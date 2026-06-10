import Foundation
import Observation
import GoalsCore

/// Backs the weekly review (docs/PLAN.md §2.2 #4): a short, consensual reflection
/// where adaptation becomes visible. Builds a per-goal narrative + optional diff.
@MainActor
@Observable
final class WeeklyReviewViewModel {
    struct GoalReview: Identifiable {
        let goalID: UUID
        let title: String
        let narrative: String
        let snapshot: PerformanceSnapshot
        var proposal: ReplanService.Result?
        var id: UUID { goalID }
    }

    private let app: AppContainer
    var reviews: [GoalReview] = []
    var isLoading = false

    init(app: AppContainer) { self.app = app }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        var built: [GoalReview] = []
        for goal in app.store.activeGoals() where goal.status == .active {
            guard let plan = app.store.plan(for: goal.id) else { continue }
            let snapshot = app.performance.snapshot(for: plan)
            let narrative = (try? await app.llm.reviewNarrative(snapshot: snapshot, plan: plan))
                ?? "Here's how your week went."
            // Offer an adjustment only when the data suggests one is needed.
            var proposal: ReplanService.Result?
            if AdaptationPolicy().evaluate(snapshot: snapshot, schedulerOvercommitted: false) != nil
                || snapshot.overallCompletionRate < 0.5 {
                proposal = try? await app.planEngine.proposeRevision(
                    goalID: goal.id, trigger: .weeklyReview)
            }
            built.append(GoalReview(goalID: goal.id, title: goal.title,
                                    narrative: narrative, snapshot: snapshot, proposal: proposal))
        }
        reviews = built
    }

    func accept(_ review: GoalReview) {
        guard let result = review.proposal, !result.diff.isQuestionOnly else { return }
        app.planEngine.apply(diff: result.diff, to: review.goalID, trigger: .weeklyReview)
        markReviewed()
        remove(review)
    }

    func dismiss(_ review: GoalReview) {
        if let result = review.proposal {
            app.planEngine.recordRejected(diff: result.diff, goalID: review.goalID, trigger: .weeklyReview)
        }
        markReviewed()
        remove(review)
    }

    private func remove(_ review: GoalReview) { reviews.removeAll { $0.id == review.id } }
    func markReviewed() { app.store.setLastReviewDate(app.clock.now()) }

    var isDue: Bool {
        AdaptationPolicy().isWeeklyReviewDue(lastReview: app.store.lastReviewDate(),
                                             now: app.clock.now(), calendar: app.clock.calendar)
    }
}

/// Backs Settings (docs/PLAN.md §2.2 #5, §7): constraint editing, notifications,
/// and the privacy controls (export / erase).
@MainActor
@Observable
final class SettingsViewModel {
    private let app: AppContainer
    var profile: ConstraintProfile

    init(app: AppContainer) {
        self.app = app
        self.profile = app.store.profile()
    }

    func save() {
        app.store.save(profile)
        app.scheduling.rescheduleAll() // re-place tasks against new constraints
    }

    func wakeBinding(for day: Weekday) -> Int {
        profile.wakeMinute[day] ?? ConstraintProfile.defaultWake
    }
    func setWake(_ minute: Int, for day: Weekday) { profile.wakeMinute[day] = minute }

    func bedtimeBinding(for day: Weekday) -> Int {
        profile.bedtimeMinute[day] ?? ConstraintProfile.defaultBedtime
    }
    func setBedtime(_ minute: Int, for day: Weekday) { profile.bedtimeMinute[day] = minute }

    var usingLiveBackend: Bool { app.usingLiveBackend }

    /// Export everything as JSON (docs/PLAN.md §7 user control).
    func exportJSON() -> Data? {
        struct Export: Encodable {
            let goals: [Goal]
            let profile: ConstraintProfile
        }
        let export = Export(goals: app.store.allGoals(), profile: profile)
        return try? JSON.encoder.encode(export)
    }

    /// One-tap erase of all goals (and their plans/occurrences/history).
    func eraseAll() {
        for goal in app.store.allGoals() { app.store.deleteGoal(goal.id) }
    }
}
