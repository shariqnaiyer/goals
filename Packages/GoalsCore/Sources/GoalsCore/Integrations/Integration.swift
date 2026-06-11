import Foundation

/// External services the app can connect to. v1 ships Google Calendar; the
/// rest are surfaced as "coming soon" so the UI communicates the roadmap
/// without dead code paths.
public enum IntegrationKind: String, Codable, CaseIterable, Sendable, Hashable {
    case googleCalendar
    case appleCalendar
    case notion
    case todoist
    case things
    case strava
}

public enum IntegrationAvailability: Sendable, Hashable {
    case available
    case comingSoon
}

/// Static, UI-facing metadata for one integration. Kept here (not in the app
/// layer) so the catalog is a single source of truth; `systemImage` is a plain
/// SF Symbol name string, so no UI framework is imported.
public struct IntegrationDescriptor: Sendable, Identifiable {
    public let kind: IntegrationKind
    public let displayName: String
    public let subtitle: String
    public let systemImage: String
    public let availability: IntegrationAvailability

    public var id: IntegrationKind { kind }

    public init(kind: IntegrationKind,
                displayName: String,
                subtitle: String,
                systemImage: String,
                availability: IntegrationAvailability) {
        self.kind = kind
        self.displayName = displayName
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.availability = availability
    }

    /// The full catalog, in display order. Adding an integration later means
    /// flipping its availability here and registering a provider in the app.
    public static let catalog: [IntegrationDescriptor] = [
        IntegrationDescriptor(
            kind: .googleCalendar,
            displayName: "Google Calendar",
            subtitle: "Schedule around your meetings",
            systemImage: "calendar",
            availability: .available),
        IntegrationDescriptor(
            kind: .appleCalendar,
            displayName: "Apple Calendar",
            subtitle: "Schedule around your events",
            systemImage: "calendar.badge.clock",
            availability: .comingSoon),
        IntegrationDescriptor(
            kind: .notion,
            displayName: "Notion",
            subtitle: "Sync notes and progress",
            systemImage: "doc.text",
            availability: .comingSoon),
        IntegrationDescriptor(
            kind: .todoist,
            displayName: "Todoist",
            subtitle: "Keep your to-dos in step",
            systemImage: "checklist",
            availability: .comingSoon),
        IntegrationDescriptor(
            kind: .things,
            displayName: "Things",
            subtitle: "Keep your to-dos in step",
            systemImage: "checkmark.circle",
            availability: .comingSoon),
        IntegrationDescriptor(
            kind: .strava,
            displayName: "Strava",
            subtitle: "Count workouts automatically",
            systemImage: "figure.run",
            availability: .comingSoon),
    ]
}

/// Per-account settings for the Google Calendar integration. Lives inside
/// `IntegrationState` so settings persist as one JSON payload.
public struct GoogleCalendarSettings: Codable, Sendable, Hashable {
    /// Calendar IDs whose events count as busy time for the scheduler.
    public var busyCalendarIDs: Set<String>
    /// Whether scheduled sessions are exported to the dedicated Goals calendar.
    public var exportEnabled: Bool
    /// All-day events (birthdays, holidays) usually shouldn't zero out a whole
    /// day of availability, so they're ignored unless the user opts in.
    public var includeAllDayEvents: Bool
    /// The app-created "Goals" calendar that exported sessions live in.
    public var goalsCalendarID: String?

    public init(busyCalendarIDs: Set<String> = [],
                exportEnabled: Bool = true,
                includeAllDayEvents: Bool = false,
                goalsCalendarID: String? = nil) {
        self.busyCalendarIDs = busyCalendarIDs
        self.exportEnabled = exportEnabled
        self.includeAllDayEvents = includeAllDayEvents
        self.goalsCalendarID = goalsCalendarID
    }
}

/// Persisted connection + sync state for one integration (the JSON payload of
/// `SDIntegration` in the app layer).
public struct IntegrationState: Codable, Sendable {
    public var kind: IntegrationKind
    public var isConnected: Bool
    /// Human-readable account identity, e.g. the Google account email.
    public var accountLabel: String?
    public var connectedAt: Date?
    public var google: GoogleCalendarSettings?
    public var lastImportAt: Date?
    public var lastExportAt: Date?
    public var lastSyncError: String?

    public init(kind: IntegrationKind,
                isConnected: Bool = false,
                accountLabel: String? = nil,
                connectedAt: Date? = nil,
                google: GoogleCalendarSettings? = nil,
                lastImportAt: Date? = nil,
                lastExportAt: Date? = nil,
                lastSyncError: String? = nil) {
        self.kind = kind
        self.isConnected = isConnected
        self.accountLabel = accountLabel
        self.connectedAt = connectedAt
        self.google = google
        self.lastImportAt = lastImportAt
        self.lastExportAt = lastExportAt
        self.lastSyncError = lastSyncError
    }
}
