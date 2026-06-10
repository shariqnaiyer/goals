import Foundation
import GoalsCore

/// Display helpers mapping domain value types to user-facing strings.
enum Format {

    static func time(_ minuteOfDay: Int) -> String {
        var comps = DateComponents()
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func window(_ window: MinuteWindow?) -> String {
        guard let window else { return "Anytime" }
        return "\(time(window.start))–\(time(window.end))"
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h)h \(m)m"
    }

    static func day(_ day: CalendarDay, calendar: Calendar = .current) -> String {
        let date = day.date(calendar: calendar)
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    static func relativeDay(_ day: CalendarDay, today: CalendarDay, calendar: Calendar = .current) -> String {
        if day == today { return "Today" }
        if day == today.adding(days: 1, calendar: calendar) { return "Tomorrow" }
        if day == today.adding(days: -1, calendar: calendar) { return "Yesterday" }
        return self.day(day, calendar: calendar)
    }

    static func date(_ day: CalendarDay?, calendar: Calendar = .current) -> String {
        guard let day else { return "Open-ended" }
        let date = day.date(calendar: calendar)
        let f = DateFormatter()
        f.calendar = calendar
        f.dateStyle = .medium
        return f.string(from: date)
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func cadence(_ rule: RecurrenceRule) -> String {
        switch rule.cadence {
        case .specificWeekdays:
            if rule.weekdays.count == 7 { return "Every day" }
            let names = rule.weekdays.sorted { $0.calendarWeekday < $1.calendarWeekday }
                .map { $0.rawValue.prefix(3).capitalized }
            return names.joined(separator: ", ")
        case .timesPerWeek:
            return "\(rule.timesPerWeek)× per week"
        case .everyNDays:
            return rule.interval == 1 ? "Every day" : "Every \(rule.interval) days"
        case .once:
            return "One-off"
        }
    }
}
