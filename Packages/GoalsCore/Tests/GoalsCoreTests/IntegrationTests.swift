import XCTest
@testable import GoalsCore

/// Specs for the integrations layer: BusyWindowConverter (external events →
/// timezone-stable busy windows) and CalendarSyncPlanner (export diffing,
/// including the fresh-UUID churn the scheduler produces every reschedule).
final class IntegrationTests: XCTestCase {

    private let calendar = Fixtures.calendar
    private let monday = Fixtures.monday

    private func date(day: CalendarDay, hour: Int, minute: Int = 0) -> Date {
        day.date(atMinute: hour * 60 + minute, calendar: calendar)
    }

    private func event(start: Date, end: Date, allDay: Bool = false, id: String = "e1") -> BusyEvent {
        BusyEvent(externalID: id, calendarID: "primary", title: "Meeting",
                  start: start, end: end, isAllDay: allDay)
    }

    // MARK: - BusyWindowConverter

    func testSimpleEventMapsToDayWindow() {
        let e = event(start: date(day: monday, hour: 10), end: date(day: monday, hour: 11, minute: 30))
        let busy = BusyWindowConverter.busyByDay(events: [e], startDay: monday,
                                                 horizonDays: 14, calendar: calendar)
        XCTAssertEqual(busy[monday], [MinuteWindow(start: 600, end: 690)])
        XCTAssertEqual(busy.count, 1)
    }

    func testEventCrossingMidnightSplitsAcrossDays() {
        let tuesday = Fixtures.day(1)
        let e = event(start: date(day: monday, hour: 23), end: date(day: tuesday, hour: 1))
        let busy = BusyWindowConverter.busyByDay(events: [e], startDay: monday,
                                                 horizonDays: 14, calendar: calendar)
        XCTAssertEqual(busy[monday], [MinuteWindow(start: 1380, end: 1440)])
        XCTAssertEqual(busy[tuesday], [MinuteWindow(start: 0, end: 60)])
    }

    func testMultiDayEventCoversFullMiddleDays() {
        let thursday = Fixtures.day(3)
        let e = event(start: date(day: monday, hour: 18), end: date(day: thursday, hour: 9))
        let busy = BusyWindowConverter.busyByDay(events: [e], startDay: monday,
                                                 horizonDays: 14, calendar: calendar)
        XCTAssertEqual(busy[monday], [MinuteWindow(start: 1080, end: 1440)])
        XCTAssertEqual(busy[Fixtures.day(1)], [MinuteWindow(start: 0, end: 1440)])
        XCTAssertEqual(busy[Fixtures.day(2)], [MinuteWindow(start: 0, end: 1440)])
        XCTAssertEqual(busy[thursday], [MinuteWindow(start: 0, end: 540)])
    }

    func testAllDayEventsSkippedByDefaultIncludedWhenFlagged() {
        let e = event(start: date(day: monday, hour: 0), end: date(day: Fixtures.day(1), hour: 0), allDay: true)
        let skipped = BusyWindowConverter.busyByDay(events: [e], startDay: monday,
                                                    horizonDays: 14, calendar: calendar)
        XCTAssertTrue(skipped.isEmpty)

        let included = BusyWindowConverter.busyByDay(events: [e], startDay: monday,
                                                     horizonDays: 14, calendar: calendar,
                                                     includeAllDay: true)
        XCTAssertEqual(included[monday], [MinuteWindow(start: 0, end: 1440)])
    }

    func testEventsOutsideHorizonAreDropped() {
        let before = event(start: date(day: Fixtures.day(-2), hour: 10),
                           end: date(day: Fixtures.day(-2), hour: 11), id: "past")
        let after = event(start: date(day: Fixtures.day(20), hour: 10),
                          end: date(day: Fixtures.day(20), hour: 11), id: "far")
        let busy = BusyWindowConverter.busyByDay(events: [before, after], startDay: monday,
                                                 horizonDays: 14, calendar: calendar)
        XCTAssertTrue(busy.isEmpty)
    }

    func testEventStraddlingHorizonStartKeepsInHorizonPortion() {
        let sunday = Fixtures.day(-1)
        let e = event(start: date(day: sunday, hour: 22), end: date(day: monday, hour: 2))
        let busy = BusyWindowConverter.busyByDay(events: [e], startDay: monday,
                                                 horizonDays: 14, calendar: calendar)
        XCTAssertNil(busy[sunday])
        XCTAssertEqual(busy[monday], [MinuteWindow(start: 0, end: 120)])
    }

    func testOverlappingEventsMergePerDay() {
        let a = event(start: date(day: monday, hour: 9), end: date(day: monday, hour: 10, minute: 30), id: "a")
        let b = event(start: date(day: monday, hour: 10), end: date(day: monday, hour: 11), id: "b")
        let c = event(start: date(day: monday, hour: 14), end: date(day: monday, hour: 15), id: "c")
        let busy = BusyWindowConverter.busyByDay(events: [a, b, c], startDay: monday,
                                                 horizonDays: 14, calendar: calendar)
        XCTAssertEqual(busy[monday], [MinuteWindow(start: 540, end: 660),
                                      MinuteWindow(start: 840, end: 900)])
    }

    func testZeroLengthEventsIgnored() {
        let e = event(start: date(day: monday, hour: 10), end: date(day: monday, hour: 10))
        let busy = BusyWindowConverter.busyByDay(events: [e], startDay: monday,
                                                 horizonDays: 14, calendar: calendar)
        XCTAssertTrue(busy.isEmpty)
    }

    func testConversionRespectsLocalTimezone() {
        // 22:00 UTC on Monday is 10:00 Tuesday in Auckland (UTC+12, June).
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let utcStart = monday.date(atMinute: 22 * 60, calendar: calendar)
        let utcEnd = monday.date(atMinute: 23 * 60, calendar: calendar)
        let e = event(start: utcStart, end: utcEnd)

        let localMonday = CalendarDay(date: utcStart, calendar: auckland)
        let busy = BusyWindowConverter.busyByDay(events: [e],
                                                 startDay: localMonday,
                                                 horizonDays: 14,
                                                 calendar: auckland)
        XCTAssertEqual(localMonday, CalendarDay(year: 2026, month: 6, day: 2))
        XCTAssertEqual(busy[localMonday], [MinuteWindow(start: 600, end: 660)])
    }

    func testMergedJoinsTouchingWindows() {
        let merged = BusyWindowConverter.merged([
            MinuteWindow(start: 60, end: 120),
            MinuteWindow(start: 120, end: 180),
            MinuteWindow(start: 300, end: 360),
        ])
        XCTAssertEqual(merged, [MinuteWindow(start: 60, end: 180),
                                MinuteWindow(start: 300, end: 360)])
    }

    func testCachedBusyWindowsRoundTripsThroughCodable() throws {
        let cache = CachedBusyWindows(
            startDay: monday, horizonDays: 14,
            byDay: [monday: [MinuteWindow(start: 600, end: 660)],
                    Fixtures.day(3): [MinuteWindow(start: 0, end: 1440)]])
        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(CachedBusyWindows.self, from: data)
        XCTAssertEqual(decoded, cache)
    }

    // MARK: - CalendarSyncPlanner

    private func desired(_ title: String = "Run",
                         day: CalendarDay? = nil,
                         window: MinuteWindow = MinuteWindow(start: 420, end: 460),
                         id: UUID = UUID()) -> DesiredCalendarEvent {
        DesiredCalendarEvent(occurrenceID: id, title: title,
                             day: day ?? monday, window: window)
    }

    private func record(for d: DesiredCalendarEvent, eventID: String = "g1") -> SyncedEventRecord {
        SyncedEventRecord(occurrenceID: d.occurrenceID, eventID: eventID,
                          day: d.day, contentKey: d.contentKey)
    }

    func testEmptyKnownProducesAllCreates() {
        let d = [desired(), desired("Read", day: Fixtures.day(1))]
        let plan = CalendarSyncPlanner.plan(desired: d, known: [], today: monday)
        XCTAssertEqual(plan.creates.count, 2)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertTrue(plan.unchanged.isEmpty)
    }

    func testIdenticalDesiredAndKnownIsAllUnchanged() {
        let d = desired()
        let plan = CalendarSyncPlanner.plan(desired: [d], known: [record(for: d)], today: monday)
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertEqual(plan.unchanged, [record(for: d)])
    }

    func testMovedWindowWithSameOccurrenceIDIsAnUpdate() {
        let original = desired()
        let known = record(for: original)
        let moved = DesiredCalendarEvent(occurrenceID: original.occurrenceID,
                                         title: original.title,
                                         day: original.day,
                                         window: MinuteWindow(start: 1080, end: 1120))
        let plan = CalendarSyncPlanner.plan(desired: [moved], known: [known], today: monday)
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.updates.first?.record.eventID, "g1")
        XCTAssertEqual(plan.updates.first?.desired, moved)
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    /// The critical churn case: every reschedule deletes pending occurrences
    /// and recreates them with fresh UUIDs. Same content ⇒ zero API calls,
    /// records re-keyed to the new occurrence IDs.
    func testNoOpRescheduleChurnIsAllUnchangedWithRekeyedRecords() {
        let old1 = desired("Run")
        let old2 = desired("Read", day: Fixtures.day(1), window: MinuteWindow(start: 1200, end: 1230))
        let known = [record(for: old1, eventID: "g1"), record(for: old2, eventID: "g2")]

        // Same slots, brand-new occurrence IDs.
        let new1 = DesiredCalendarEvent(occurrenceID: UUID(), title: "Run",
                                        day: old1.day, window: old1.window)
        let new2 = DesiredCalendarEvent(occurrenceID: UUID(), title: "Read",
                                        day: old2.day, window: old2.window)

        let plan = CalendarSyncPlanner.plan(desired: [new1, new2], known: known, today: monday)
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertEqual(plan.unchanged.count, 2)
        XCTAssertEqual(Set(plan.unchanged.map(\.occurrenceID)),
                       [new1.occurrenceID, new2.occurrenceID])
        XCTAssertEqual(Set(plan.unchanged.map(\.eventID)), ["g1", "g2"])
    }

    func testRemovedFutureOccurrenceIsDeletedPastIsPruned() {
        let past = desired("Run", day: Fixtures.day(-3))
        let future = desired("Run", day: Fixtures.day(2))
        let known = [record(for: past, eventID: "old"), record(for: future, eventID: "next")]
        let plan = CalendarSyncPlanner.plan(desired: [], known: known, today: monday)
        XCTAssertEqual(plan.deletes.map(\.eventID), ["next"])
        XCTAssertEqual(plan.prune.map(\.eventID), ["old"])
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertTrue(plan.unchanged.isEmpty)
    }

    func testChangedScheduleWithFreshIDsCreatesAndDeletes() {
        // Yesterday's plan had a Monday run; the new plan moved it to Tuesday
        // with a fresh UUID and different content key.
        let old = desired("Run", day: monday)
        let known = [record(for: old, eventID: "g1")]
        let new = DesiredCalendarEvent(occurrenceID: UUID(), title: "Run",
                                       day: Fixtures.day(1),
                                       window: old.window)
        let plan = CalendarSyncPlanner.plan(desired: [new], known: known, today: monday)
        XCTAssertEqual(plan.creates, [new])
        XCTAssertEqual(plan.deletes.map(\.eventID), ["g1"])
        XCTAssertTrue(plan.unchanged.isEmpty)
    }

    func testDuplicateContentSlotsAdoptOneOrphanEach() {
        // Two identical sessions in the same slot (defensive: shouldn't happen,
        // but the planner must not double-adopt one record).
        let oldA = desired("Run")
        let known = [record(for: oldA, eventID: "g1")]
        let newA = DesiredCalendarEvent(occurrenceID: UUID(), title: "Run",
                                        day: oldA.day, window: oldA.window)
        let newB = DesiredCalendarEvent(occurrenceID: UUID(), title: "Run",
                                        day: oldA.day, window: oldA.window)
        let plan = CalendarSyncPlanner.plan(desired: [newA, newB], known: known, today: monday)
        XCTAssertEqual(plan.unchanged.count, 1)
        XCTAssertEqual(plan.creates.count, 1)
        XCTAssertTrue(plan.deletes.isEmpty)
    }
}
