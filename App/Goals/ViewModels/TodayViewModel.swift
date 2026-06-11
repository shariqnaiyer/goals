import Foundation
import Observation
import GoalsCore

/// Backs the Today screen (docs/PLAN.md §2.2 tab 1). Surfaces today's (and
/// tomorrow's) occurrences with their goal titles, handles complete/skip/snooze,
/// and watches for a struggle threshold that should offer a gentle replan.
@MainActor
@Observable
final class TodayViewModel {
    struct Item: Identifiable {
        let occurrence: TaskOccurrence
        let goalTitle: String
        /// The template's lighter fallback ("Read 2 pages"), for the daily-minimum UI.
        var minimumViableVariant: String?
        var id: UUID { occurrence.id }
    }

    /// A pending proactive adaptation surfaced after repeated misses.
    struct AdaptationPrompt: Identifiable {
        let goalID: UUID
        let goalTitle: String
        let trigger: RevisionTrigger
        var id: UUID { goalID }
    }

    private let app: AppContainer

    var todayItems: [Item] = []
    var tomorrowItems: [Item] = []
    var adaptationPrompt: AdaptationPrompt?

    init(app: AppContainer) { self.app = app }

    var today: CalendarDay { app.clock.today }

    var completedToday: Int { todayItems.filter { $0.occurrence.status == .done }.count }
    var totalToday: Int { todayItems.count }
    var allDoneToday: Bool { totalToday > 0 && completedToday == totalToday }

    func load() {
        let tomorrow = app.clock.day(offset: 1)
        let titles = goalTitles()
        let minimums = templateMinimums()
        todayItems = items(on: today, titles: titles, minimums: minimums)
        tomorrowItems = items(on: tomorrow, titles: titles, minimums: minimums)
    }

    private func items(on day: CalendarDay, titles: [UUID: String], minimums: [UUID: String]) -> [Item] {
        app.store.occurrences(on: day)
            .filter { titles[$0.goalID] != nil }
            .sorted { ($0.window?.start ?? 0) < ($1.window?.start ?? 0) }
            .map { Item(occurrence: $0, goalTitle: titles[$0.goalID] ?? "Goal",
                        minimumViableVariant: $0.templateID.flatMap { minimums[$0] }) }
    }

    private func goalTitles() -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: app.store.activeGoals().map { ($0.id, $0.title) })
    }

    private func templateMinimums() -> [UUID: String] {
        var map: [UUID: String] = [:]
        for goal in app.store.activeGoals() {
            guard let plan = app.store.plan(for: goal.id) else { continue }
            for template in plan.templates where template.minimumViableVariant != nil {
                map[template.id] = template.minimumViableVariant
            }
        }
        return map
    }

    // MARK: Actions

    func complete(_ item: Item, difficulty: Int? = nil) {
        app.taskActions.complete(item.occurrence, difficulty: difficulty)
        load()
    }

    func skip(_ item: Item, reason: String?) {
        if let trigger = app.taskActions.skip(item.occurrence, reason: reason) {
            adaptationPrompt = AdaptationPrompt(goalID: item.occurrence.goalID,
                                                goalTitle: item.goalTitle, trigger: trigger)
        }
        load()
    }

    func snooze(_ item: Item, toTomorrow: Bool) {
        app.taskActions.snooze(item.occurrence, toTomorrow: toTomorrow)
        app.scheduling.reschedule(goalID: item.occurrence.goalID)
        load()
    }

    func dismissAdaptationPrompt() { adaptationPrompt = nil }
}
