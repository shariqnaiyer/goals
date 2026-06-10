import XCTest
@testable import GoalsCore

final class SchedulerTests: XCTestCase {

    private let cal = Fixtures.calendar

    func testRespectsWorkAndSleepWindows() {
        let profile = ConstraintProfile.makeDefault() // 9-17 work, 7-23 awake
        let free = Availability.freeWindows(day: Fixtures.monday, weekday: .monday,
                                            profile: profile, busy: [])
        // Expect 07:00-09:00 and 17:00-23:00 free.
        XCTAssertEqual(free, [MinuteWindow(startHour: 7, endHour: 9),
                              MinuteWindow(startHour: 17, endHour: 23)])
    }

    func testBlackoutDayHasNoAvailability() {
        var profile = ConstraintProfile.makeDefault()
        profile.blackoutDays = [Fixtures.monday]
        let free = Availability.freeWindows(day: Fixtures.monday, weekday: .monday,
                                            profile: profile, busy: [])
        XCTAssertTrue(free.isEmpty)
    }

    func testSchedulesThreeRunsPerWeek() {
        let plan = Fixtures.plan()
        let input = Scheduler.Input(templates: plan.templates,
                                    profile: .makeDefault(),
                                    startDay: Fixtures.monday,
                                    horizonDays: 7,
                                    anchorDay: Fixtures.monday,
                                    calendar: cal)
        let out = Scheduler().schedule(input)
        XCTAssertEqual(out.occurrences.count, 3)
        XCTAssertFalse(out.isOvercommitted)
        // All placed inside free windows and inside the awake span.
        for occ in out.occurrences {
            let w = try! XCTUnwrap(occ.window)
            XCTAssertGreaterThanOrEqual(w.start, 7 * 60)
            XCTAssertLessThanOrEqual(w.end, 23 * 60)
            // Not during 9-17 work.
            XCTAssertFalse(w.overlaps(MinuteWindow(startHour: 9, endHour: 17)))
        }
    }

    func testHonoursPreferredTimeOfDayViaHints() {
        var plan = Fixtures.plan()
        plan.templates[0].preferredWindows = [:]
        let hints = [plan.templates[0].id: TimeOfDay.evening]
        let input = Scheduler.Input(templates: plan.templates,
                                    profile: .makeDefault(),
                                    bestTimeHints: hints,
                                    startDay: Fixtures.monday,
                                    horizonDays: 7,
                                    anchorDay: Fixtures.monday,
                                    calendar: cal)
        let out = Scheduler().schedule(input)
        // Evening representative start is 18:00; placements should land at/after 17:00.
        for occ in out.occurrences {
            XCTAssertGreaterThanOrEqual(occ.window!.start, 17 * 60)
        }
    }

    func testOvercommitSignalWhenDailyCapTooLow() {
        var plan = Fixtures.plan()
        // One daily 60-min task, but a 30-min daily cap → every day overcommits.
        plan.templates = [TaskTemplate(goalID: plan.goal.id, title: "Long run",
                                       effortMinutes: 60, recurrence: .daily())]
        var profile = ConstraintProfile.makeDefault()
        profile.maxDailyTaskMinutes = 30
        let input = Scheduler.Input(templates: plan.templates, profile: profile,
                                    startDay: Fixtures.monday, horizonDays: 3,
                                    anchorDay: Fixtures.monday, calendar: cal)
        let out = Scheduler().schedule(input)
        XCTAssertTrue(out.isOvercommitted)
        XCTAssertTrue(out.occurrences.isEmpty)
        XCTAssertTrue(out.overcommit.allSatisfy { $0.reason == .dailyCapReached })
    }

    func testNoDoubleBookingWithinADay() {
        let plan = Fixtures.plan()
        var templates = plan.templates
        // Two daily 60-min tasks both preferring early morning; must not overlap.
        templates = [
            TaskTemplate(goalID: plan.goal.id, title: "A", effortMinutes: 60,
                         recurrence: .daily(),
                         preferredWindows: [.monday: MinuteWindow(startHour: 7, endHour: 8)]),
            TaskTemplate(goalID: plan.goal.id, title: "B", effortMinutes: 60,
                         recurrence: .daily(),
                         preferredWindows: [.monday: MinuteWindow(startHour: 7, endHour: 8)])
        ]
        var profile = ConstraintProfile.makeDefault()
        profile.maxDailyTaskMinutes = 240
        let input = Scheduler.Input(templates: templates, profile: profile,
                                    startDay: Fixtures.monday, horizonDays: 1,
                                    anchorDay: Fixtures.monday, calendar: cal)
        let out = Scheduler().schedule(input)
        let mondayOccs = out.occurrences.filter { $0.day == Fixtures.monday }
        XCTAssertEqual(mondayOccs.count, 2)
        XCTAssertFalse(mondayOccs[0].window!.overlaps(mondayOccs[1].window!))
    }

    func testCalendarBusyIntervalsBlockPlacement() {
        let plan = Fixtures.plan()
        var templates = plan.templates
        templates = [TaskTemplate(goalID: plan.goal.id, title: "Run", effortMinutes: 60,
                                  recurrence: .weekly([.monday]),
                                  preferredWindows: [.monday: MinuteWindow(startHour: 7, endHour: 8)])]
        // Busy 7-9 blocks the only morning slot; should fall to evening.
        let busy = [Fixtures.monday: [MinuteWindow(startHour: 7, endHour: 9)]]
        let input = Scheduler.Input(templates: templates, profile: .makeDefault(),
                                    busyByDay: busy, startDay: Fixtures.monday,
                                    horizonDays: 1, anchorDay: Fixtures.monday, calendar: cal)
        let out = Scheduler().schedule(input)
        XCTAssertEqual(out.occurrences.count, 1)
        XCTAssertGreaterThanOrEqual(out.occurrences[0].window!.start, 17 * 60)
    }
}
