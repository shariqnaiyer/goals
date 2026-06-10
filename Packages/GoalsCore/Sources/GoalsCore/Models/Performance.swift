import Foundation

/// Per-template behavioural rollup. This is the *only* behavioural aggregate
/// ever sent to the LLM (docs/PLAN.md §4, §7) — raw occurrence history never is.
public struct TemplatePerformance: Codable, Sendable, Hashable {
    public var templateID: UUID
    public var title: String
    public var scheduled: Int
    public var completed: Int
    public var skipped: Int
    /// Consecutive most-recent misses (skipped or past-due pending).
    public var currentMissStreak: Int
    /// Coarse bucket where this task is most often completed.
    public var bestTimeOfDay: TimeOfDay?
    public var averageDifficulty: Double?

    public init(templateID: UUID,
                title: String,
                scheduled: Int,
                completed: Int,
                skipped: Int,
                currentMissStreak: Int,
                bestTimeOfDay: TimeOfDay?,
                averageDifficulty: Double?) {
        self.templateID = templateID
        self.title = title
        self.scheduled = scheduled
        self.completed = completed
        self.skipped = skipped
        self.currentMissStreak = currentMissStreak
        self.bestTimeOfDay = bestTimeOfDay
        self.averageDifficulty = averageDifficulty
    }

    public var completionRate: Double {
        scheduled == 0 ? 0 : Double(completed) / Double(scheduled)
    }
}

public enum TimeOfDay: String, Codable, Sendable, CaseIterable {
    case earlyMorning   // 05:00–08:00
    case morning        // 08:00–12:00
    case afternoon      // 12:00–17:00
    case evening        // 17:00–21:00
    case night          // 21:00–05:00

    public init(minuteOfDay: Int) {
        switch minuteOfDay {
        case (5 * 60)..<(8 * 60): self = .earlyMorning
        case (8 * 60)..<(12 * 60): self = .morning
        case (12 * 60)..<(17 * 60): self = .afternoon
        case (17 * 60)..<(21 * 60): self = .evening
        default: self = .night
        }
    }

    /// A representative window for placement nudging.
    public var representativeWindowStart: Int {
        switch self {
        case .earlyMorning: return 6 * 60
        case .morning: return 9 * 60
        case .afternoon: return 14 * 60
        case .evening: return 18 * 60
        case .night: return 21 * 60
        }
    }
}

/// A compact, privacy-preserving snapshot of how the user is doing, computed
/// weekly and cached. The adaptation engine's only behavioural input.
public struct PerformanceSnapshot: Codable, Sendable, Hashable {
    public var goalID: UUID
    public var windowStart: CalendarDay
    public var windowEnd: CalendarDay
    public var templates: [TemplatePerformance]
    /// Active weekly load vs. the user's stated budget, in minutes.
    public var scheduledWeeklyMinutes: Int
    public var weeklyBudgetMinutes: Int

    public init(goalID: UUID,
                windowStart: CalendarDay,
                windowEnd: CalendarDay,
                templates: [TemplatePerformance],
                scheduledWeeklyMinutes: Int,
                weeklyBudgetMinutes: Int) {
        self.goalID = goalID
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.templates = templates
        self.scheduledWeeklyMinutes = scheduledWeeklyMinutes
        self.weeklyBudgetMinutes = weeklyBudgetMinutes
    }

    public var overallCompletionRate: Double {
        let scheduled = templates.reduce(0) { $0 + $1.scheduled }
        let completed = templates.reduce(0) { $0 + $1.completed }
        return scheduled == 0 ? 0 : Double(completed) / Double(scheduled)
    }

    public var isOverBudget: Bool {
        weeklyBudgetMinutes > 0 && scheduledWeeklyMinutes > weeklyBudgetMinutes
    }

    /// Templates whose miss streak has reached the adaptation threshold.
    public func strugglingTemplates(threshold: Int = 3) -> [TemplatePerformance] {
        templates.filter { $0.currentMissStreak >= threshold }
    }
}
