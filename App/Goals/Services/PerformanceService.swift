import Foundation
import GoalsCore

/// Builds `PerformanceSnapshot`s from persisted occurrences for a goal — the
/// behavioural input to adaptation (docs/PLAN.md §5).
@MainActor
struct PerformanceService {
    let schedule: ScheduleRepository
    let clock: Clock

    func snapshot(for plan: Plan, lookbackDays: Int = 14) -> PerformanceSnapshot {
        let analyzer = PerformanceAnalyzer(calendar: clock.calendar)
        let start = clock.day(offset: -lookbackDays)
        let occurrences = schedule.occurrences(goalID: plan.goal.id)
        return analyzer.snapshot(plan: plan,
                                 occurrences: occurrences,
                                 windowStart: start,
                                 windowEnd: clock.day(offset: 7),
                                 today: clock.today)
    }
}
