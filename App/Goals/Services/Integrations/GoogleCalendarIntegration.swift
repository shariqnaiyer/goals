import Foundation
import GoalsCore

/// The Google Calendar provider: orchestrates auth, busy-time import and
/// schedule export. All calendar math is delegated to the pure
/// `BusyWindowConverter` / `CalendarSyncPlanner`; all persistence goes through
/// `IntegrationRepository`. Sync is best-effort — failures land in
/// `IntegrationState.lastSyncError`, never block scheduling.
@MainActor
@Observable
final class GoogleCalendarIntegration: IntegrationProvider, BusyTimeIntegration, ExportIntegration {

    nonisolated let kind: IntegrationKind = .googleCalendar

    private let auth: GoogleAuthService
    private let client: GoogleCalendarClient
    private let repo: IntegrationRepository
    private let clock: Clock

    private(set) var state: IntegrationState

    init(auth: GoogleAuthService,
         client: GoogleCalendarClient,
         repo: IntegrationRepository,
         clock: Clock) {
        self.auth = auth
        self.client = client
        self.repo = repo
        self.clock = clock
        self.state = repo.integrationState(.googleCalendar)
            ?? IntegrationState(kind: .googleCalendar)
    }

    var isConnected: Bool { state.isConnected }
    var accountLabel: String? { state.accountLabel }
    var settings: GoogleCalendarSettings { state.google ?? GoogleCalendarSettings() }

    // MARK: IntegrationProvider

    /// Restore the Keychain session on launch. If Google lost the grant (e.g.
    /// the user revoked access), surface that as disconnected.
    func restoreConnection() async {
        guard state.isConnected else { return }
        let restored = await auth.restorePreviousSignIn()
        if !restored {
            state.isConnected = false
            state.lastSyncError = "Signed out of Google — reconnect in Settings."
            persist()
        }
    }

    func connect() async throws {
        let email = try await auth.signIn()
        var settings = state.google ?? GoogleCalendarSettings()
        state.isConnected = true
        state.accountLabel = email
        state.connectedAt = clock.now()
        state.lastSyncError = nil

        // Default the busy set to the primary calendar.
        if settings.busyCalendarIDs.isEmpty {
            if let primary = try? await client.calendarList().first(where: \.isPrimary) {
                settings.busyCalendarIDs = [primary.id]
            }
        }
        state.google = settings
        persist()

        // Export is on by default; the extra scope + Goals calendar are
        // best-effort here (the user may decline — import still works).
        if settings.exportEnabled {
            try? await enableExport()
        }
    }

    func disconnect() async {
        // Leave nothing behind: delete exported events while we still have a
        // token, then drop local records, cache and the session.
        if let calendarID = settings.goalsCalendarID {
            for record in repo.syncedEvents() {
                try? await client.deleteEvent(calendarID: calendarID, eventID: record.eventID)
            }
        }
        await auth.disconnect()
        repo.clearIntegrationData(.googleCalendar)
        state = IntegrationState(kind: .googleCalendar)
    }

    // MARK: Settings

    func availableCalendars() async throws -> [GoogleCalendarInfo] {
        try await client.calendarList().filter { $0.id != settings.goalsCalendarID }
    }

    func update(settings newSettings: GoogleCalendarSettings) {
        state.google = newSettings
        persist()
    }

    /// Request the write scope and make sure the "Goals" calendar exists.
    func enableExport() async throws {
        try await auth.ensureScopes([GoogleAuthService.Scope.calendarAppCreated])
        var settings = self.settings
        if settings.goalsCalendarID == nil {
            settings.goalsCalendarID = try await client.createCalendar(summary: "Goals")
        }
        settings.exportEnabled = true
        state.google = settings
        persist()
    }

    /// Turn export off and remove the events we created.
    func disableExport() async {
        var settings = self.settings
        settings.exportEnabled = false
        state.google = settings
        persist()
        if let calendarID = settings.goalsCalendarID {
            for record in repo.syncedEvents() {
                try? await client.deleteEvent(calendarID: calendarID, eventID: record.eventID)
            }
        }
        repo.replaceSyncedEvents([])
    }

    // MARK: BusyTimeIntegration

    /// Refresh the local busy-window cache from Google. Returns true when the
    /// busy data changed (callers reschedule only then). Never throws — the
    /// scheduler keeps working from the previous cache.
    func refreshBusyCache(start: CalendarDay, horizonDays: Int) async -> Bool {
        guard state.isConnected, !settings.busyCalendarIDs.isEmpty else { return false }
        let calendar = clock.calendar
        let timeMin = start.date(atMinute: 0, calendar: calendar)
        let timeMax = start.adding(days: horizonDays, calendar: calendar)
            .date(atMinute: 0, calendar: calendar)

        var events: [BusyEvent] = []
        do {
            // Never import our own exported events as busy time, or every
            // reschedule would block the slots it just placed.
            for calendarID in settings.busyCalendarIDs where calendarID != settings.goalsCalendarID {
                events += try await client.events(calendarID: calendarID,
                                                  timeMin: timeMin, timeMax: timeMax)
            }
        } catch {
            state.lastSyncError = error.localizedDescription
            persist()
            return false
        }

        let byDay = BusyWindowConverter.busyByDay(events: events,
                                                  startDay: start,
                                                  horizonDays: horizonDays,
                                                  calendar: calendar,
                                                  includeAllDay: settings.includeAllDayEvents)
        let cache = CachedBusyWindows(startDay: start, horizonDays: horizonDays, byDay: byDay)
        let previous = repo.busyCache(.googleCalendar)?.cache
        repo.saveBusyCache(.googleCalendar, cache: cache, fetchedAt: clock.now())
        state.lastImportAt = clock.now()
        state.lastSyncError = nil
        persist()
        return cache != previous
    }

    /// Last-known busy windows, read synchronously so scheduling works offline.
    func cachedBusyByDay() -> [CalendarDay: [MinuteWindow]] {
        guard state.isConnected else { return [:] }
        return repo.busyCache(.googleCalendar)?.cache.byDay ?? [:]
    }

    // MARK: ExportIntegration

    /// Reconcile the Goals calendar with the current schedule. The planner's
    /// content matching makes a no-op reschedule cost zero API calls despite
    /// the scheduler regenerating occurrence UUIDs every run.
    func exportSchedule(occurrences: [TaskOccurrence]) async {
        guard state.isConnected, settings.exportEnabled,
              let calendarID = settings.goalsCalendarID else { return }

        let desired = occurrences.compactMap { occ -> DesiredCalendarEvent? in
            guard occ.status == .pending, let window = occ.window else { return nil }
            var title = occ.title
            if let label = occ.slice?.label { title += " — \(label)" }
            return DesiredCalendarEvent(occurrenceID: occ.id,
                                        title: title,
                                        day: occ.day,
                                        window: window,
                                        notes: occ.slice?.detail)
        }

        let plan = CalendarSyncPlanner.plan(desired: desired,
                                            known: repo.syncedEvents(),
                                            today: clock.today)
        let calendar = clock.calendar
        var confirmed: [SyncedEventRecord] = plan.unchanged

        // On failure, unprocessed deletes/updates keep their old records so the
        // next sync retries them; unprocessed creates simply have no record and
        // get re-created. Nothing is silently orphaned on the calendar.
        var remainingDeletes = plan.deletes
        var remainingUpdates = plan.updates
        do {
            while let record = remainingDeletes.first {
                try await client.deleteEvent(calendarID: calendarID, eventID: record.eventID)
                remainingDeletes.removeFirst()
            }
            while let (record, desired) = remainingUpdates.first {
                try await client.patchEvent(calendarID: calendarID, eventID: record.eventID,
                                            desired, calendar: calendar)
                remainingUpdates.removeFirst()
                confirmed.append(SyncedEventRecord(occurrenceID: desired.occurrenceID,
                                                   eventID: record.eventID,
                                                   day: desired.day,
                                                   contentKey: desired.contentKey))
            }
            for desired in plan.creates {
                let eventID = try await client.insertEvent(calendarID: calendarID,
                                                           desired, calendar: calendar)
                confirmed.append(SyncedEventRecord(occurrenceID: desired.occurrenceID,
                                                   eventID: eventID,
                                                   day: desired.day,
                                                   contentKey: desired.contentKey))
            }
            state.lastExportAt = clock.now()
            state.lastSyncError = nil
        } catch {
            confirmed += remainingDeletes
            confirmed += remainingUpdates.map(\.record)
            state.lastSyncError = error.localizedDescription
        }
        repo.replaceSyncedEvents(confirmed)
        persist()
    }

    private func persist() {
        repo.save(state)
    }
}
