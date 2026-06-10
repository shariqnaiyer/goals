import Foundation
import GoalsCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications (docs/PLAN.md §6). Deliberately gentle: a morning digest
/// plus at most a couple of per-task reminders, hard-capped at ~3/day to avoid
/// the notification fatigue the plan flags as the #1 churn risk. All scheduling
/// is local — no pushes, no server.
@MainActor
final class NotificationService {

    static let taskCategoryID = "TASK_REMINDER"
    static let doneActionID = "MARK_DONE"
    static let snoozeActionID = "SNOOZE"
    static let dailyCap = 3
    private let digestHour = 8

    #if canImport(UserNotifications)
    private var center: UNUserNotificationCenter { .current() }
    #endif

    func registerCategories() {
        #if canImport(UserNotifications)
        let done = UNNotificationAction(identifier: Self.doneActionID, title: "Mark done",
                                        options: [.authenticationRequired])
        let snooze = UNNotificationAction(identifier: Self.snoozeActionID, title: "Snooze",
                                          options: [])
        let category = UNNotificationCategory(identifier: Self.taskCategoryID,
                                              actions: [done, snooze],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        #endif
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Clear and rebuild the notification schedule from current pending occurrences.
    func reschedule(for occurrences: [TaskOccurrence], calendar: Calendar) {
        #if canImport(UserNotifications)
        center.removeAllPendingNotificationRequests()

        let byDay = Dictionary(grouping: occurrences.filter { $0.status == .pending }, by: \.day)
        for (day, dayOccurrences) in byDay {
            let sorted = dayOccurrences.sorted { ($0.window?.start ?? 0) < ($1.window?.start ?? 0) }
            scheduleDigest(day: day, count: sorted.count, calendar: calendar)

            // Up to (cap - 1) per-task reminders, preferring those with a window.
            let reminders = sorted.filter { $0.window != nil }.prefix(Self.dailyCap - 1)
            for occ in reminders { scheduleTaskReminder(occ, calendar: calendar) }
        }
        #endif
    }

    #if canImport(UserNotifications)
    private func scheduleDigest(day: CalendarDay, count: Int, calendar: Calendar) {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Today's plan"
        content.body = count == 1 ? "You've got 1 thing planned today." : "You've got \(count) things planned today."
        content.sound = .default

        var comps = DateComponents()
        comps.year = day.year; comps.month = day.month; comps.day = day.day
        comps.hour = digestHour; comps.minute = 0
        add(id: "digest-\(DayKey.make(day))", content: content, dateComponents: comps, calendar: calendar)
    }

    private func scheduleTaskReminder(_ occ: TaskOccurrence, calendar: Calendar) {
        guard let window = occ.window else { return }
        let content = UNMutableNotificationContent()
        content.title = occ.title
        content.body = "Time for \(occ.title.lowercased()) — \(occ.effortMinutes) min."
        content.sound = .default
        content.categoryIdentifier = Self.taskCategoryID
        content.userInfo = ["occurrenceID": occ.id.uuidString]

        var comps = DateComponents()
        comps.year = occ.day.year; comps.month = occ.day.month; comps.day = occ.day.day
        comps.hour = window.start / 60; comps.minute = window.start % 60
        add(id: "task-\(occ.id.uuidString)", content: content, dateComponents: comps, calendar: calendar)
    }

    private func add(id: String, content: UNMutableNotificationContent,
                     dateComponents: DateComponents, calendar: Calendar) {
        var comps = dateComponents
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        // Only schedule future fire dates.
        if let fire = calendar.date(from: comps), fire < Date() { return }
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
    #endif
}
