import Foundation
import SwiftData
import GoalsCore

// SwiftData persistence (docs/PLAN.md §3.1). To stay robust against SwiftData's
// evolving handling of nested value types — and to keep the domain layer the
// single source of truth — each record stores a few *queryable* columns plus a
// JSON `payload` of the corresponding `GoalsCore` value type. The repositories
// are the only code that touches these classes; everything above them speaks in
// pure domain structs, so swapping SwiftData for GRDB later stays contained
// (the "repository seam" insurance from the plan).
//
// Trade-off: the id/status columns are duplicated inside the payload. That
// denormalisation is deliberate — it buys simple, reliable persistence and
// fast predicates without fighting macro codegen we can't unit-test.

enum DayKey {
    /// Sortable Int form of a CalendarDay: yyyymmdd.
    static func make(_ day: CalendarDay) -> Int { day.year * 10000 + day.month * 100 + day.day }
}

@Model
final class SDGoal {
    @Attribute(.unique) var id: UUID
    var statusRaw: String
    var createdAt: Date
    var payload: Data

    init(goal: Goal) {
        self.id = goal.id
        self.statusRaw = goal.status.rawValue
        self.createdAt = goal.createdAt
        self.payload = JSON.encode(goal)
    }
    var domain: Goal? { JSON.decode(Goal.self, from: payload) }
}

@Model
final class SDMilestone {
    @Attribute(.unique) var id: UUID
    var goalID: UUID
    var order: Int
    var payload: Data

    init(milestone: Milestone) {
        self.id = milestone.id
        self.goalID = milestone.goalID
        self.order = milestone.order
        self.payload = JSON.encode(milestone)
    }
    var domain: Milestone? { JSON.decode(Milestone.self, from: payload) }
}

@Model
final class SDTemplate {
    @Attribute(.unique) var id: UUID
    var goalID: UUID
    var isActive: Bool
    var payload: Data

    init(template: TaskTemplate) {
        self.id = template.id
        self.goalID = template.goalID
        self.isActive = template.isActive
        self.payload = JSON.encode(template)
    }
    var domain: TaskTemplate? { JSON.decode(TaskTemplate.self, from: payload) }
}

@Model
final class SDOccurrence {
    @Attribute(.unique) var id: UUID
    var goalID: UUID
    var templateID: UUID?
    var dayKey: Int
    var statusRaw: String
    var payload: Data

    init(occurrence: TaskOccurrence) {
        self.id = occurrence.id
        self.goalID = occurrence.goalID
        self.templateID = occurrence.templateID
        self.dayKey = DayKey.make(occurrence.day)
        self.statusRaw = occurrence.status.rawValue
        self.payload = JSON.encode(occurrence)
    }
    var domain: TaskOccurrence? { JSON.decode(TaskOccurrence.self, from: payload) }
}

@Model
final class SDRevision {
    @Attribute(.unique) var id: UUID
    var goalID: UUID
    var timestamp: Date
    var payload: Data

    init(revision: PlanRevision) {
        self.id = revision.id
        self.goalID = revision.goalID
        self.timestamp = revision.timestamp
        self.payload = JSON.encode(revision)
    }
    var domain: PlanRevision? { JSON.decode(PlanRevision.self, from: payload) }
}

@Model
final class SDChatMessage {
    @Attribute(.unique) var id: UUID
    var threadID: String
    var createdAt: Date
    var payload: Data

    init(message: ChatMessage) {
        self.id = message.id
        self.threadID = message.threadID
        self.createdAt = message.createdAt
        self.payload = JSON.encode(message)
    }
    var domain: ChatMessage? { JSON.decode(ChatMessage.self, from: payload) }
}

@Model
final class SDConstraintProfile {
    @Attribute(.unique) var id: String   // singleton key "default"
    var payload: Data

    init(profile: ConstraintProfile) {
        self.id = "default"
        self.payload = JSON.encode(profile)
    }
    var domain: ConstraintProfile? { JSON.decode(ConstraintProfile.self, from: payload) }
}

@Model
final class SDUserProfile {
    @Attribute(.unique) var id: String   // singleton key "default"
    var payload: Data

    init(profile: UserProfile) {
        self.id = "default"
        self.payload = JSON.encode(profile)
    }
    var domain: UserProfile? { JSON.decode(UserProfile.self, from: payload) }
}

@Model
final class SDAppState {
    @Attribute(.unique) var id: String   // singleton key "app"
    var lastReviewDate: Date?
    var hasCompletedOnboarding: Bool

    init(lastReviewDate: Date? = nil, hasCompletedOnboarding: Bool = false) {
        self.id = "app"
        self.lastReviewDate = lastReviewDate
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

@Model
final class SDIntegration {
    @Attribute(.unique) var id: String   // IntegrationKind.rawValue
    var isConnected: Bool
    var payload: Data

    init(state: IntegrationState) {
        self.id = state.kind.rawValue
        self.isConnected = state.isConnected
        self.payload = JSON.encode(state)
    }
    var domain: IntegrationState? { JSON.decode(IntegrationState.self, from: payload) }
}

@Model
final class SDSyncedEvent {
    @Attribute(.unique) var eventID: String
    var occurrenceID: UUID
    var dayKey: Int
    var payload: Data

    init(record: SyncedEventRecord) {
        self.eventID = record.eventID
        self.occurrenceID = record.occurrenceID
        self.dayKey = DayKey.make(record.day)
        self.payload = JSON.encode(record)
    }
    var domain: SyncedEventRecord? { JSON.decode(SyncedEventRecord.self, from: payload) }
}

@Model
final class SDBusyCache {
    @Attribute(.unique) var id: String   // IntegrationKind.rawValue
    var fetchedAt: Date
    var payload: Data

    init(kind: IntegrationKind, cache: CachedBusyWindows, fetchedAt: Date) {
        self.id = kind.rawValue
        self.fetchedAt = fetchedAt
        self.payload = JSON.encode(cache)
    }
    var domain: CachedBusyWindows? { JSON.decode(CachedBusyWindows.self, from: payload) }
}

/// Shared JSON coder for payloads. ISO dates keep payloads human-readable in the
/// store and stable across migrations.
enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static func encode<T: Encodable>(_ value: T) -> Data { (try? encoder.encode(value)) ?? Data() }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}

/// The full schema, referenced when building the `ModelContainer`.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        SDGoal.self, SDMilestone.self, SDTemplate.self, SDOccurrence.self,
        SDRevision.self, SDChatMessage.self, SDConstraintProfile.self,
        SDUserProfile.self, SDAppState.self,
        SDIntegration.self, SDSyncedEvent.self, SDBusyCache.self
    ]
}
