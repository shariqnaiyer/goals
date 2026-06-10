import Foundation
@testable import GoalsCore

enum Fixtures {
    /// A fixed, timezone-stable calendar for deterministic tests.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday, matches our Weekday ordering at the edge
        return c
    }

    /// Monday, 2026-06-01.
    static let monday = CalendarDay(year: 2026, month: 6, day: 1)

    static func day(_ offset: Int) -> CalendarDay {
        monday.adding(days: offset, calendar: calendar)
    }

    static func goal(weeklyBudget: Int = 300) -> Goal {
        Goal(title: "Run a 10k",
             motivationStatement: "I want to feel strong again.",
             type: .outcome,
             successCriteria: "Run 10k without stopping.",
             targetDate: day(60),
             weeklyBudgetMinutes: weeklyBudget)
    }

    static func runTemplate(goalID: UUID,
                            timesPerWeek: Int = 3,
                            effort: Int = 40) -> TaskTemplate {
        TaskTemplate(goalID: goalID,
                     title: "Run",
                     effortMinutes: effort,
                     recurrence: .times(timesPerWeek, preferring: [.monday, .wednesday, .friday]),
                     preferredWindows: [:],
                     flexibility: .flexible,
                     minimumViableVariant: "10-minute walk")
    }

    static func plan(weeklyBudget: Int = 300) -> Plan {
        let g = goal(weeklyBudget: weeklyBudget)
        let m = Milestone(goalID: g.id, title: "Build a base", order: 0)
        let t = runTemplate(goalID: g.id)
        return Plan(goal: g, milestones: [m], templates: [t])
    }
}
