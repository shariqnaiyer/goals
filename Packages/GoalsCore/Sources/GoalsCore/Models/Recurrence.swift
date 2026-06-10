import Foundation

/// A simplified, RFC-5545-inspired recurrence rule.
///
/// The plan calls for "RFC 5545-style" recurrence (docs/PLAN.md §4). Full RRULE
/// is overkill for self-improvement tasks, so we model the cases that actually
/// occur — "3× per week", "every day", "specific weekdays", "every N days" — and
/// keep the door open to richer rules later. Frequency is interpreted against the
/// task's `preferredWeekdays`; the Scheduler decides concrete dates.
public struct RecurrenceRule: Codable, Sendable, Hashable {
    public enum Cadence: String, Codable, Sendable {
        /// Occurs on each weekday listed in `weekdays`.
        case specificWeekdays
        /// Occurs `timesPerWeek` times per week; the Scheduler picks the days,
        /// biased toward `weekdays` if provided.
        case timesPerWeek
        /// Occurs every `interval` days starting from the plan anchor.
        case everyNDays
        /// A single, one-off occurrence (used for outcome-goal checkpoints).
        case once
    }

    public var cadence: Cadence
    /// Preferred / required weekdays depending on `cadence`.
    public var weekdays: Set<Weekday>
    /// Used by `.timesPerWeek`.
    public var timesPerWeek: Int
    /// Used by `.everyNDays`.
    public var interval: Int

    public init(cadence: Cadence,
                weekdays: Set<Weekday> = [],
                timesPerWeek: Int = 0,
                interval: Int = 1) {
        self.cadence = cadence
        self.weekdays = weekdays
        self.timesPerWeek = max(0, timesPerWeek)
        self.interval = max(1, interval)
    }

    // MARK: Convenience constructors

    public static func daily() -> RecurrenceRule {
        RecurrenceRule(cadence: .specificWeekdays, weekdays: Set(Weekday.allCases))
    }

    public static func weekly(_ days: Set<Weekday>) -> RecurrenceRule {
        RecurrenceRule(cadence: .specificWeekdays, weekdays: days)
    }

    public static func times(_ n: Int, preferring days: Set<Weekday> = []) -> RecurrenceRule {
        RecurrenceRule(cadence: .timesPerWeek, weekdays: days, timesPerWeek: n)
    }

    public static func once() -> RecurrenceRule {
        RecurrenceRule(cadence: .once)
    }

    /// Expected occurrences per 7-day window — used by the load/budget validator.
    public var occurrencesPerWeek: Int {
        switch cadence {
        case .specificWeekdays: return weekdays.count
        case .timesPerWeek: return timesPerWeek
        case .everyNDays: return max(1, 7 / interval)
        case .once: return 0 // amortises to ~0/week for budgeting
        }
    }
}
