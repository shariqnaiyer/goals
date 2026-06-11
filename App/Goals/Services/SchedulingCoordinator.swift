import Foundation
import GoalsCore

/// Runs the deterministic Scheduler over a goal's active templates and persists
/// the resulting occurrences (docs/PLAN.md §5, Layer 1). Pending future
/// occurrences are regenerated; completed/skipped history is preserved and fed
/// back as "busy" time so nothing double-books over what already happened.
@MainActor
final class SchedulingCoordinator {
    private let goals: GoalRepository
    private let schedule: ScheduleRepository
    private let constraints: ConstraintRepository
    private let performance: PerformanceService
    private let notifications: NotificationService
    private let clock: Clock
    private let horizonDays: Int

    /// External busy time (calendar integrations), merged into `busyByDay`
    /// before placement. A closure (wired in AppContainer) rather than the
    /// integration service itself, to keep the dependency direction clean.
    var externalBusy: (() -> [CalendarDay: [MinuteWindow]])?
    /// Fired after occurrences change, so integrations can mirror the schedule
    /// outward (debounced on the receiving side).
    var onScheduleChanged: (() -> Void)?

    init(goals: GoalRepository,
         schedule: ScheduleRepository,
         constraints: ConstraintRepository,
         performance: PerformanceService,
         notifications: NotificationService,
         clock: Clock,
         horizonDays: Int = 14) {
        self.goals = goals
        self.schedule = schedule
        self.constraints = constraints
        self.performance = performance
        self.notifications = notifications
        self.clock = clock
        self.horizonDays = horizonDays
    }

    /// Reschedule a single goal from today forward.
    @discardableResult
    func reschedule(goalID: UUID) -> Scheduler.Output? {
        guard let plan = goals.plan(for: goalID), plan.goal.status == .active else {
            // Paused/abandoned goals get their pending occurrences cleared.
            schedule.deletePending(goalID: goalID, from: clock.today)
            refreshNotifications()
            onScheduleChanged?()
            return nil
        }

        let profile = constraints.profile()
        let snapshot = performance.snapshot(for: plan)
        let hints = PerformanceAnalyzer(calendar: clock.calendar).bestTimeHints(from: snapshot)

        // Existing non-pending occurrences become busy intervals so re-runs don't
        // collide with what the user already did today.
        let existing = schedule.occurrences(goalID: goalID)
        var busyByDay: [CalendarDay: [MinuteWindow]] = [:]
        for occ in existing where occ.status != .pending {
            if let w = occ.window { busyByDay[occ.day, default: []].append(w) }
        }

        // External commitments (e.g. Google Calendar events) block placement
        // the same way. Read from the local cache — works offline.
        for (day, windows) in externalBusy?() ?? [:] {
            busyByDay[day, default: []] += windows
        }

        // Series units already completed must not be handed out again by the
        // Sequencer below — that would falsify progress (re-offering a read chapter).
        let consumedUnitIDs = Set(existing
            .filter { $0.status == .done }
            .compactMap { $0.slice?.unitID })

        schedule.deletePending(goalID: goalID, from: clock.today)

        let input = Scheduler.Input(
            templates: plan.activeTemplates,
            profile: profile,
            busyByDay: busyByDay,
            bestTimeHints: hints,
            startDay: clock.today,
            horizonDays: horizonDays,
            anchorDay: CalendarDay(date: plan.goal.createdAt, calendar: clock.calendar),
            calendar: clock.calendar)

        var output = Scheduler().schedule(input)
        // Layer 1.5: stamp concrete content ("Chapter 4") onto sequential sessions.
        // No-op for goals without specifics, so legacy goals are unaffected.
        output.occurrences = Sequencer.assignSlices(
            pending: output.occurrences,
            specifics: plan.goal.specifics,
            templates: plan.activeTemplates,
            consumedUnitIDs: consumedUnitIDs)
        schedule.upsert(output.occurrences)
        refreshNotifications()
        onScheduleChanged?()
        return output
    }

    /// Reschedule every active goal (used on app launch / after constraint edits).
    func rescheduleAll() {
        for goal in goals.activeGoals() where goal.status == .active {
            _ = reschedule(goalID: goal.id)
        }
    }

    private func refreshNotifications() {
        let upcoming = schedule.occurrencesFrom(clock.today).filter { $0.status == .pending }
        notifications.reschedule(for: upcoming, calendar: clock.calendar)
    }
}
