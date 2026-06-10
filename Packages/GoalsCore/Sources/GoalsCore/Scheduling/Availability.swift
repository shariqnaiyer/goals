import Foundation

/// A busy interval on a specific day (e.g. an EventKit event), used to carve
/// time out of availability. Always same-day; multi-day events are split at the
/// app edge before reaching the Scheduler.
public struct BusyInterval: Sendable, Hashable {
    public var day: CalendarDay
    public var window: MinuteWindow
    public init(day: CalendarDay, window: MinuteWindow) {
        self.day = day
        self.window = window
    }
}

/// Computes free windows for a single day given the constraint profile and any
/// busy intervals. Pure and deterministic.
public enum Availability {

    /// Free `MinuteWindow`s for `day`, sorted ascending, after removing work,
    /// busy intervals and (implicitly) sleep via the awake span. Returns `[]`
    /// for blackout days.
    public static func freeWindows(day: CalendarDay,
                                   weekday: Weekday,
                                   profile: ConstraintProfile,
                                   busy: [MinuteWindow]) -> [MinuteWindow] {
        if profile.blackoutDays.contains(day) { return [] }

        var free = [profile.awakeWindow(weekday)]
        var blockers: [MinuteWindow] = []
        if let work = profile.workHours[weekday] { blockers.append(work) }
        blockers.append(contentsOf: busy)

        for blocker in blockers.sorted() {
            free = free.flatMap { $0.subtracting(blocker) }
        }
        return free.filter { $0.durationMinutes > 0 }.sorted()
    }

    /// Total free minutes for a day.
    public static func freeMinutes(day: CalendarDay,
                                   weekday: Weekday,
                                   profile: ConstraintProfile,
                                   busy: [MinuteWindow]) -> Int {
        freeWindows(day: day, weekday: weekday, profile: profile, busy: busy)
            .reduce(0) { $0 + $1.durationMinutes }
    }
}
