import Foundation

/// Day of week. String-raw so LLM structured output emits readable values
/// (`"monday"`), with a stable `CaseIterable` order Monday→Sunday.
///
/// Conversion to/from Foundation's Sunday-first `Calendar` weekday numbering
/// happens only here, keeping the domain model locale-independent.
public enum Weekday: String, Codable, CaseIterable, Sendable, Hashable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    /// Build from Foundation's `Calendar` weekday (1 = Sunday ... 7 = Saturday).
    public init(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1: self = .sunday
        case 2: self = .monday
        case 3: self = .tuesday
        case 4: self = .wednesday
        case 5: self = .thursday
        case 6: self = .friday
        default: self = .saturday
        }
    }

    /// Foundation `Calendar` weekday (1 = Sunday ... 7 = Saturday).
    public var calendarWeekday: Int {
        switch self {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }

    public var isWeekend: Bool { self == .saturday || self == .sunday }

    /// Capitalised three-letter abbreviation, e.g. "Mon".
    public var shortName: String {
        let abbrev = String(rawValue.prefix(3))
        return abbrev.prefix(1).uppercased() + abbrev.dropFirst()
    }
}

/// A half-open span of minutes-from-midnight within a single day: `[start, end)`.
///
/// Storing windows as minute-of-day (rather than absolute `Date`s) is the core
/// of the plan's timezone/DST strategy (docs/PLAN.md §9): a "07:00–08:00 run"
/// stays 07:00 local regardless of travel, because nothing absolute is persisted.
public struct MinuteWindow: Codable, Sendable, Hashable, Comparable {
    /// Minutes from local midnight, 0...1440.
    public let start: Int
    /// Minutes from local midnight, 0...1440. Must be >= start.
    public let end: Int

    public init(start: Int, end: Int) {
        precondition(start >= 0 && end <= 24 * 60, "MinuteWindow out of day bounds")
        precondition(end >= start, "MinuteWindow end before start")
        self.start = start
        self.end = end
    }

    /// Convenience initialiser from wall-clock components.
    public init(startHour: Int, startMinute: Int = 0, endHour: Int, endMinute: Int = 0) {
        self.init(start: startHour * 60 + startMinute, end: endHour * 60 + endMinute)
    }

    public var durationMinutes: Int { end - start }

    public func overlaps(_ other: MinuteWindow) -> Bool {
        start < other.end && other.start < end
    }

    public func contains(_ other: MinuteWindow) -> Bool {
        other.start >= start && other.end <= end
    }

    /// Subtract `other` from `self`, returning 0, 1 or 2 remaining sub-windows.
    public func subtracting(_ other: MinuteWindow) -> [MinuteWindow] {
        guard overlaps(other) else { return [self] }
        var result: [MinuteWindow] = []
        if other.start > start { result.append(MinuteWindow(start: start, end: other.start)) }
        if other.end < end { result.append(MinuteWindow(start: other.end, end: end)) }
        return result
    }

    public static func < (lhs: MinuteWindow, rhs: MinuteWindow) -> Bool {
        lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }
}

/// A calendar day expressed as year/month/day, independent of timezone.
///
/// Like `MinuteWindow`, `CalendarDay` keeps the scheduler timezone-stable:
/// occurrences are anchored to a local day + minute window, never a UTC instant.
public struct CalendarDay: Codable, Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// The `Date` at the given minute-of-day for this calendar day.
    public func date(atMinute minute: Int = 0, calendar: Calendar) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = minute / 60; c.minute = minute % 60
        return calendar.date(from: c) ?? Date()
    }

    public func weekday(in calendar: Calendar) -> Weekday {
        let wd = calendar.component(.weekday, from: date(calendar: calendar))
        return Weekday(calendarWeekday: wd)
    }

    public func adding(days: Int, calendar: Calendar) -> CalendarDay {
        let base = date(calendar: calendar)
        let next = calendar.date(byAdding: .day, value: days, to: base) ?? base
        return CalendarDay(date: next, calendar: calendar)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static func today(_ calendar: Calendar, now: Date = Date()) -> CalendarDay {
        CalendarDay(date: now, calendar: calendar)
    }
}
