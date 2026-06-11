import Foundation
import SwiftData
import GoalsCore

// Repository protocols — the seam the plan calls for (docs/PLAN.md §3.1). Code
// above this line speaks only in `GoalsCore` value types; only the concrete
// SwiftData implementations below know about persistence.

@MainActor
protocol GoalRepository {
    func allGoals() -> [Goal]
    func activeGoals() -> [Goal]
    func goal(_ id: UUID) -> Goal?
    func plan(for goalID: UUID) -> Plan?
    func save(plan: Plan)
    func updateGoal(_ goal: Goal)
    func deleteGoal(_ id: UUID)
}

@MainActor
protocol ScheduleRepository {
    func occurrences(goalID: UUID) -> [TaskOccurrence]
    func occurrences(on day: CalendarDay) -> [TaskOccurrence]
    func occurrencesFrom(_ start: CalendarDay) -> [TaskOccurrence]
    func upsert(_ occurrences: [TaskOccurrence])
    func update(_ occurrence: TaskOccurrence)
    /// Remove pending occurrences on/after `day` (used before rescheduling).
    func deletePending(goalID: UUID, from day: CalendarDay)
}

@MainActor
protocol RevisionRepository {
    func revisions(goalID: UUID) -> [PlanRevision]
    func add(_ revision: PlanRevision)
}

@MainActor
protocol ChatRepository {
    func messages(threadID: String) -> [ChatMessage]
    func add(_ message: ChatMessage)
}

@MainActor
protocol ConstraintRepository {
    func profile() -> ConstraintProfile
    func save(_ profile: ConstraintProfile)
}

@MainActor
protocol UserProfileRepository {
    func userProfile() -> UserProfile
    func save(_ profile: UserProfile)
}

@MainActor
protocol AppStateRepository {
    func hasCompletedOnboarding() -> Bool
    func setCompletedOnboarding(_ value: Bool)
    func lastReviewDate() -> Date?
    func setLastReviewDate(_ date: Date)
}

@MainActor
protocol IntegrationRepository {
    func integrationState(_ kind: IntegrationKind) -> IntegrationState?
    func save(_ state: IntegrationState)
    func syncedEvents() -> [SyncedEventRecord]
    /// Wholesale replace after a sync pass (small sets; simplest correct path).
    func replaceSyncedEvents(_ records: [SyncedEventRecord])
    func busyCache(_ kind: IntegrationKind) -> (fetchedAt: Date, cache: CachedBusyWindows)?
    func saveBusyCache(_ kind: IntegrationKind, cache: CachedBusyWindows, fetchedAt: Date)
    func clearIntegrationData(_ kind: IntegrationKind)
}

// MARK: - SwiftData implementations

@MainActor
final class SwiftDataStore: GoalRepository, ScheduleRepository, RevisionRepository,
                            ChatRepository, ConstraintRepository, UserProfileRepository,
                            AppStateRepository, IntegrationRepository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    private func saveContext() {
        do { try context.save() } catch { print("SwiftData save error: \(error)") }
    }

    // MARK: GoalRepository

    func allGoals() -> [Goal] {
        fetch(SDGoal.self).compactMap(\.domain).sorted { $0.createdAt > $1.createdAt }
    }

    func activeGoals() -> [Goal] {
        allGoals().filter { $0.status == .active || $0.status == .paused }
    }

    func goal(_ id: UUID) -> Goal? {
        sdGoal(id)?.domain
    }

    func plan(for goalID: UUID) -> Plan? {
        guard let goal = goal(goalID) else { return nil }
        let milestones = fetch(SDMilestone.self, predicate: #Predicate { $0.goalID == goalID })
            .compactMap(\.domain)
        let templates = fetch(SDTemplate.self, predicate: #Predicate { $0.goalID == goalID })
            .compactMap(\.domain)
        return Plan(goal: goal, milestones: milestones, templates: templates)
    }

    func save(plan: Plan) {
        // Upsert goal.
        upsertGoal(plan.goal)
        // Replace milestones & templates for this goal (small sets; simplest correct path).
        let goalID = plan.goal.id
        delete(SDMilestone.self, predicate: #Predicate { $0.goalID == goalID })
        delete(SDTemplate.self, predicate: #Predicate { $0.goalID == goalID })
        for m in plan.milestones { context.insert(SDMilestone(milestone: m)) }
        for t in plan.templates { context.insert(SDTemplate(template: t)) }
        saveContext()
    }

    func updateGoal(_ goal: Goal) {
        upsertGoal(goal)
        saveContext()
    }

    func deleteGoal(_ id: UUID) {
        delete(SDGoal.self, predicate: #Predicate { $0.id == id })
        delete(SDMilestone.self, predicate: #Predicate { $0.goalID == id })
        delete(SDTemplate.self, predicate: #Predicate { $0.goalID == id })
        delete(SDOccurrence.self, predicate: #Predicate { $0.goalID == id })
        delete(SDRevision.self, predicate: #Predicate { $0.goalID == id })
        saveContext()
    }

    private func upsertGoal(_ goal: Goal) {
        if let existing = sdGoal(goal.id) {
            existing.statusRaw = goal.status.rawValue
            existing.payload = JSON.encode(goal)
        } else {
            context.insert(SDGoal(goal: goal))
        }
    }

    private func sdGoal(_ id: UUID) -> SDGoal? {
        fetch(SDGoal.self, predicate: #Predicate { $0.id == id }).first
    }

    // MARK: ScheduleRepository

    func occurrences(goalID: UUID) -> [TaskOccurrence] {
        fetch(SDOccurrence.self, predicate: #Predicate { $0.goalID == goalID }).compactMap(\.domain)
    }

    func occurrences(on day: CalendarDay) -> [TaskOccurrence] {
        let key = DayKey.make(day)
        return fetch(SDOccurrence.self, predicate: #Predicate { $0.dayKey == key }).compactMap(\.domain)
    }

    func occurrencesFrom(_ start: CalendarDay) -> [TaskOccurrence] {
        let key = DayKey.make(start)
        return fetch(SDOccurrence.self, predicate: #Predicate { $0.dayKey >= key }).compactMap(\.domain)
    }

    func upsert(_ occurrences: [TaskOccurrence]) {
        for occ in occurrences {
            let id = occ.id
            if let existing = fetch(SDOccurrence.self, predicate: #Predicate { $0.id == id }).first {
                existing.statusRaw = occ.status.rawValue
                existing.dayKey = DayKey.make(occ.day)
                existing.payload = JSON.encode(occ)
            } else {
                context.insert(SDOccurrence(occurrence: occ))
            }
        }
        saveContext()
    }

    func update(_ occurrence: TaskOccurrence) { upsert([occurrence]) }

    func deletePending(goalID: UUID, from day: CalendarDay) {
        let key = DayKey.make(day)
        let pending = OccurrenceStatus.pending.rawValue
        delete(SDOccurrence.self, predicate: #Predicate {
            $0.goalID == goalID && $0.dayKey >= key && $0.statusRaw == pending
        })
        saveContext()
    }

    // MARK: RevisionRepository

    func revisions(goalID: UUID) -> [PlanRevision] {
        fetch(SDRevision.self, predicate: #Predicate { $0.goalID == goalID })
            .compactMap(\.domain).sorted { $0.timestamp > $1.timestamp }
    }

    func add(_ revision: PlanRevision) {
        context.insert(SDRevision(revision: revision))
        saveContext()
    }

    // MARK: ChatRepository

    func messages(threadID: String) -> [ChatMessage] {
        fetch(SDChatMessage.self, predicate: #Predicate { $0.threadID == threadID })
            .compactMap(\.domain).sorted { $0.createdAt < $1.createdAt }
    }

    func add(_ message: ChatMessage) {
        context.insert(SDChatMessage(message: message))
        saveContext()
    }

    // MARK: ConstraintRepository

    func profile() -> ConstraintProfile {
        fetch(SDConstraintProfile.self).first?.domain ?? .makeDefault()
    }

    func save(_ profile: ConstraintProfile) {
        if let existing = fetch(SDConstraintProfile.self).first {
            existing.payload = JSON.encode(profile)
        } else {
            context.insert(SDConstraintProfile(profile: profile))
        }
        saveContext()
    }

    // MARK: UserProfileRepository

    func userProfile() -> UserProfile {
        fetch(SDUserProfile.self).first?.domain ?? UserProfile()
    }

    func save(_ profile: UserProfile) {
        if let existing = fetch(SDUserProfile.self).first {
            existing.payload = JSON.encode(profile)
        } else {
            context.insert(SDUserProfile(profile: profile))
        }
        saveContext()
    }

    // MARK: AppStateRepository

    private func appState() -> SDAppState {
        if let existing = fetch(SDAppState.self).first { return existing }
        let new = SDAppState()
        context.insert(new)
        return new
    }

    func hasCompletedOnboarding() -> Bool { appState().hasCompletedOnboarding }
    func setCompletedOnboarding(_ value: Bool) { appState().hasCompletedOnboarding = value; saveContext() }
    func lastReviewDate() -> Date? { appState().lastReviewDate }
    func setLastReviewDate(_ date: Date) { appState().lastReviewDate = date; saveContext() }

    // MARK: IntegrationRepository

    func integrationState(_ kind: IntegrationKind) -> IntegrationState? {
        let key = kind.rawValue
        return fetch(SDIntegration.self, predicate: #Predicate { $0.id == key }).first?.domain
    }

    func save(_ state: IntegrationState) {
        let key = state.kind.rawValue
        if let existing = fetch(SDIntegration.self, predicate: #Predicate { $0.id == key }).first {
            existing.isConnected = state.isConnected
            existing.payload = JSON.encode(state)
        } else {
            context.insert(SDIntegration(state: state))
        }
        saveContext()
    }

    func syncedEvents() -> [SyncedEventRecord] {
        fetch(SDSyncedEvent.self).compactMap(\.domain)
    }

    func replaceSyncedEvents(_ records: [SyncedEventRecord]) {
        for item in fetch(SDSyncedEvent.self) { context.delete(item) }
        for record in records { context.insert(SDSyncedEvent(record: record)) }
        saveContext()
    }

    func busyCache(_ kind: IntegrationKind) -> (fetchedAt: Date, cache: CachedBusyWindows)? {
        let key = kind.rawValue
        guard let sd = fetch(SDBusyCache.self, predicate: #Predicate { $0.id == key }).first,
              let cache = sd.domain else { return nil }
        return (sd.fetchedAt, cache)
    }

    func saveBusyCache(_ kind: IntegrationKind, cache: CachedBusyWindows, fetchedAt: Date) {
        let key = kind.rawValue
        if let existing = fetch(SDBusyCache.self, predicate: #Predicate { $0.id == key }).first {
            existing.fetchedAt = fetchedAt
            existing.payload = JSON.encode(cache)
        } else {
            context.insert(SDBusyCache(kind: kind, cache: cache, fetchedAt: fetchedAt))
        }
        saveContext()
    }

    /// Remove an integration's connection state, busy cache and sync records
    /// (used on disconnect). Provider-side cleanup happens before this.
    func clearIntegrationData(_ kind: IntegrationKind) {
        let key = kind.rawValue
        delete(SDIntegration.self, predicate: #Predicate { $0.id == key })
        delete(SDBusyCache.self, predicate: #Predicate { $0.id == key })
        // Synced events are only produced by Google Calendar in v1.
        if kind == .googleCalendar {
            for item in fetch(SDSyncedEvent.self) { context.delete(item) }
        }
        saveContext()
    }

    // MARK: Fetch helpers

    private func fetch<T: PersistentModel>(_ type: T.Type,
                                           predicate: Predicate<T>? = nil) -> [T] {
        var descriptor = FetchDescriptor<T>()
        descriptor.predicate = predicate
        return (try? context.fetch(descriptor)) ?? []
    }

    private func delete<T: PersistentModel>(_ type: T.Type, predicate: Predicate<T>) {
        let items = fetch(type, predicate: predicate)
        for item in items { context.delete(item) }
    }
}
