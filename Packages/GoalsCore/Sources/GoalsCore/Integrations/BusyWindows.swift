import Foundation

/// A provider-agnostic external calendar event. Google events (and later
/// EventKit ones) are mapped into this at the app edge; everything below —
/// conversion to busy windows, caching, scheduling — is provider-blind.
public struct BusyEvent: Sendable, Hashable {
    public let externalID: String
    public let calendarID: String
    public let title: String?
    /// Absolute instants from the provider (RFC3339 parsed upstream). The
    /// converter is the only place these touch the timezone-stable day model.
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(externalID: String,
                calendarID: String,
                title: String? = nil,
                start: Date,
                end: Date,
                isAllDay: Bool = false) {
        self.externalID = externalID
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// The locally persisted result of a busy-time import, so scheduling keeps
/// working offline from the last-known calendar state.
public struct CachedBusyWindows: Codable, Sendable, Equatable {
    public var startDay: CalendarDay
    public var horizonDays: Int
    public var byDay: [CalendarDay: [MinuteWindow]]

    public init(startDay: CalendarDay, horizonDays: Int, byDay: [CalendarDay: [MinuteWindow]]) {
        self.startDay = startDay
        self.horizonDays = horizonDays
        self.byDay = byDay
    }
}

/// Converts absolute external events into the scheduler's local-day minute
/// windows. This is the seam where provider time (UTC instants) meets the
/// timezone-stable domain model (docs/PLAN.md §9): all day/minute math goes
/// through the supplied local `Calendar`, never raw interval arithmetic.
public enum BusyWindowConverter {

    /// Busy windows per local day over `[startDay, startDay + horizonDays)`.
    /// Multi-day events are split per day and clamped to [0, 1440); events
    /// crossing midnight produce a tail window on day one and a head window on
    /// day two; all-day and zero-length events are skipped (all-day optionally
    /// included); overlapping windows are merged per day.
    public static func busyByDay(events: [BusyEvent],
                                 startDay: CalendarDay,
                                 horizonDays: Int,
                                 calendar: Calendar,
                                 includeAllDay: Bool = false) -> [CalendarDay: [MinuteWindow]] {
        guard horizonDays > 0 else { return [:] }
        let horizonEnd = startDay.adding(days: horizonDays, calendar: calendar)

        var result: [CalendarDay: [MinuteWindow]] = [:]
        for event in events {
            if event.isAllDay && !includeAllDay { continue }
            guard event.end > event.start else { continue }

            var day = CalendarDay(date: event.start, calendar: calendar)
            // Walk the local days the event touches, clipping to the horizon.
            // Bounded defensively in case of degenerate calendar math.
            var guardrail = 0
            while day < horizonEnd, guardrail < 366 {
                guardrail += 1
                let dayStart = day.date(atMinute: 0, calendar: calendar)
                let nextDay = day.adding(days: 1, calendar: calendar)
                let nextDayStart = nextDay.date(atMinute: 0, calendar: calendar)
                if dayStart >= event.end { break }

                if day >= startDay {
                    let sliceStart = max(event.start, dayStart)
                    let sliceEnd = min(event.end, nextDayStart)
                    if sliceEnd > sliceStart {
                        let startMinute = minuteOfDay(sliceStart, calendar: calendar)
                        let endMinute = sliceEnd >= nextDayStart ? 24 * 60 : minuteOfDay(sliceEnd, calendar: calendar)
                        if endMinute > startMinute {
                            result[day, default: []]
                                .append(MinuteWindow(start: startMinute, end: endMinute))
                        }
                    }
                }
                day = nextDay
            }
        }
        return result.mapValues { merged($0) }
    }

    /// Merge overlapping or touching windows into a minimal sorted set.
    public static func merged(_ windows: [MinuteWindow]) -> [MinuteWindow] {
        guard !windows.isEmpty else { return [] }
        var out: [MinuteWindow] = []
        for w in windows.sorted() {
            if let last = out.last, w.start <= last.end {
                out[out.count - 1] = MinuteWindow(start: last.start, end: max(last.end, w.end))
            } else {
                out.append(w)
            }
        }
        return out
    }

    /// Wall-clock minute-of-day via calendar components (not interval math),
    /// so DST transitions can't skew the result. Clamped to the day bounds.
    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return min(max(minute, 0), 24 * 60)
    }
}
