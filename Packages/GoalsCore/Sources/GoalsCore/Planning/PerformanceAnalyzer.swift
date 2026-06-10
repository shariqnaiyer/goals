import Foundation

/// Computes a `PerformanceSnapshot` from raw occurrences — the only place raw
/// behavioural history is read, and the only behavioural data that ever leaves
/// the device (in aggregate form) for the LLM adapter (docs/PLAN.md §5, §7).
public struct PerformanceAnalyzer {

    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// - Parameters:
    ///   - plan: the goal's current plan (for active templates / budget).
    ///   - occurrences: all occurrences for the goal.
    ///   - windowStart/windowEnd: inclusive analysis window.
    ///   - today: reference day for "past due" determination.
    public func snapshot(plan: Plan,
                         occurrences: [TaskOccurrence],
                         windowStart: CalendarDay,
                         windowEnd: CalendarDay,
                         today: CalendarDay) -> PerformanceSnapshot {
        let inWindow = occurrences.filter { $0.day >= windowStart && $0.day <= windowEnd }
        let byTemplate = Dictionary(grouping: inWindow, by: { $0.templateID })

        var perfs: [TemplatePerformance] = []
        for template in plan.templates where template.isActive {
            let occ = (byTemplate[template.id] ?? []).sorted { $0.day < $1.day }
            perfs.append(templatePerformance(template: template, occurrences: occ, today: today))
        }

        return PerformanceSnapshot(
            goalID: plan.goal.id,
            windowStart: windowStart,
            windowEnd: windowEnd,
            templates: perfs,
            scheduledWeeklyMinutes: plan.weeklyLoadMinutes,
            weeklyBudgetMinutes: plan.goal.weeklyBudgetMinutes)
    }

    private func templatePerformance(template: TaskTemplate,
                                     occurrences: [TaskOccurrence],
                                     today: CalendarDay) -> TemplatePerformance {
        // "Scheduled" = occurrences that should already have happened.
        let due = occurrences.filter { $0.day <= today }
        let completed = due.filter { $0.status == .done }
        let missed = due.filter { isMiss($0) }

        // Difficulty: mean rating across completed occurrences.
        let ratings = completed.compactMap(\.difficultyRating)
        let avgDifficulty = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)

        return TemplatePerformance(
            templateID: template.id,
            title: template.title,
            scheduled: due.count,
            completed: completed.count,
            skipped: missed.count,
            currentMissStreak: missStreak(due),
            bestTimeOfDay: bestTimeOfDay(completed),
            averageDifficulty: avgDifficulty)
    }

    /// A miss is an explicit skip, or a past-due occurrence still pending.
    private func isMiss(_ o: TaskOccurrence) -> Bool {
        o.status == .skipped || o.status == .pending
    }

    /// Count consecutive most-recent misses, stopping at the first completion.
    private func missStreak(_ due: [TaskOccurrence]) -> Int {
        var streak = 0
        for o in due.reversed() {
            if o.status == .done { break }
            if isMiss(o) { streak += 1 }
        }
        return streak
    }

    /// Modal time-of-day among completed occurrences, using the scheduled
    /// window start (falling back to completion timestamp).
    private func bestTimeOfDay(_ completed: [TaskOccurrence]) -> TimeOfDay? {
        guard !completed.isEmpty else { return nil }
        var counts: [TimeOfDay: Int] = [:]
        for o in completed {
            let minute: Int
            if let start = o.window?.start {
                minute = start
            } else if let done = o.completedAt {
                let comps = calendar.dateComponents([.hour, .minute], from: done)
                minute = (comps.hour ?? 12) * 60 + (comps.minute ?? 0)
            } else {
                continue
            }
            counts[TimeOfDay(minuteOfDay: minute), default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Build best-time hints for the Scheduler from a snapshot.
    public func bestTimeHints(from snapshot: PerformanceSnapshot) -> [UUID: TimeOfDay] {
        var hints: [UUID: TimeOfDay] = [:]
        for t in snapshot.templates {
            if let best = t.bestTimeOfDay { hints[t.templateID] = best }
        }
        return hints
    }
}
