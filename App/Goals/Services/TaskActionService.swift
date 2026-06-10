import Foundation
import GoalsCore

/// Handles the daily task interactions from the Today screen and notifications:
/// complete, skip-with-reason, snooze. After each action it checks the
/// `AdaptationPolicy` and, when a struggle threshold is crossed, surfaces a
/// proactive replan proposal (docs/PLAN.md §2.3 "event-driven", §5).
@MainActor
final class TaskActionService {
    private let schedule: ScheduleRepository
    private let goals: GoalRepository
    private let performance: PerformanceService
    private let scheduling: SchedulingCoordinator
    private let clock: Clock
    private let policy = AdaptationPolicy()

    init(schedule: ScheduleRepository,
         goals: GoalRepository,
         performance: PerformanceService,
         scheduling: SchedulingCoordinator,
         clock: Clock) {
        self.schedule = schedule
        self.goals = goals
        self.performance = performance
        self.scheduling = scheduling
        self.clock = clock
    }

    func complete(_ occurrence: TaskOccurrence, difficulty: Int? = nil) {
        var occ = occurrence
        occ.status = .done
        occ.completedAt = clock.now()
        occ.difficultyRating = difficulty
        schedule.update(occ)
    }

    func skip(_ occurrence: TaskOccurrence, reason: String?) -> RevisionTrigger? {
        var occ = occurrence
        occ.status = .skipped
        occ.skipReason = reason
        schedule.update(occ)
        return adaptationTrigger(for: occurrence.goalID)
    }

    /// Move an occurrence to later today (or tomorrow) without penalty.
    func snooze(_ occurrence: TaskOccurrence, toTomorrow: Bool = false) {
        var occ = occurrence
        if toTomorrow {
            occ.day = occurrence.day.adding(days: 1, calendar: clock.calendar)
        }
        // Nudge the window later in the day if one exists.
        if let w = occ.window {
            let shifted = min(w.start + 120, 22 * 60)
            occ.window = MinuteWindow(start: shifted, end: min(shifted + w.durationMinutes, 24 * 60))
        }
        schedule.update(occ)
    }

    /// Re-evaluate whether this goal now warrants an adaptation proposal.
    func adaptationTrigger(for goalID: UUID) -> RevisionTrigger? {
        guard let plan = goals.plan(for: goalID), plan.goal.status == .active else { return nil }
        let snapshot = performance.snapshot(for: plan)
        return policy.evaluate(snapshot: snapshot, schedulerOvercommitted: false)
    }
}
