import Foundation
import GoalsCore

/// Injectable source of "now" and the active calendar, so scheduling and
/// adaptation are deterministic in tests and consistent across the app.
struct Clock: Sendable {
    var now: @Sendable () -> Date
    var calendar: Calendar

    init(now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    var today: CalendarDay { CalendarDay(date: now(), calendar: calendar) }

    func day(offset: Int) -> CalendarDay { today.adding(days: offset, calendar: calendar) }

    static let live = Clock()
}
