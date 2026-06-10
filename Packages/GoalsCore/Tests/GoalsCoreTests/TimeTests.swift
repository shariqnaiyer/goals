import XCTest
@testable import GoalsCore

final class TimeTests: XCTestCase {

    func testMinuteWindowSubtractMiddleProducesTwoWindows() {
        let day = MinuteWindow(startHour: 9, endHour: 17)
        let lunch = MinuteWindow(startHour: 12, endHour: 13)
        let result = day.subtracting(lunch)
        XCTAssertEqual(result, [MinuteWindow(startHour: 9, endHour: 12),
                                MinuteWindow(startHour: 13, endHour: 17)])
    }

    func testMinuteWindowSubtractNonOverlapping() {
        let morning = MinuteWindow(startHour: 6, endHour: 8)
        let evening = MinuteWindow(startHour: 18, endHour: 20)
        XCTAssertEqual(morning.subtracting(evening), [morning])
    }

    func testMinuteWindowOverlapAndContains() {
        let a = MinuteWindow(startHour: 9, endHour: 12)
        let b = MinuteWindow(startHour: 11, endHour: 14)
        XCTAssertTrue(a.overlaps(b))
        XCTAssertTrue(a.contains(MinuteWindow(startHour: 10, endHour: 11)))
        XCTAssertFalse(a.contains(b))
    }

    func testWeekdayRoundTripsThroughCalendarNumbering() {
        for day in Weekday.allCases {
            XCTAssertEqual(Weekday(calendarWeekday: day.calendarWeekday), day)
        }
    }

    func testCalendarDayWeekday() {
        // 2026-06-01 is a Monday.
        XCTAssertEqual(Fixtures.monday.weekday(in: Fixtures.calendar), .monday)
        XCTAssertEqual(Fixtures.day(5).weekday(in: Fixtures.calendar), .saturday)
    }

    func testCalendarDayAddingCrossesMonthBoundary() {
        let near = CalendarDay(year: 2026, month: 6, day: 30)
        XCTAssertEqual(near.adding(days: 1, calendar: Fixtures.calendar),
                       CalendarDay(year: 2026, month: 7, day: 1))
    }
}
