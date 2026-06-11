import Foundation
import Observation
import GoalsCore

/// Backs the Integrations screens: the catalog list and the Google Calendar
/// detail (connect / busy calendars / export / sync status). Thin glue over
/// `IntegrationService` + `GoogleCalendarIntegration`.
@MainActor
@Observable
final class IntegrationsViewModel {
    private let app: AppContainer

    var availableCalendars: [GoogleCalendarInfo] = []
    var isBusy = false
    var errorMessage: String?

    init(app: AppContainer) {
        self.app = app
    }

    var descriptors: [IntegrationDescriptor] { app.integrations.descriptors }
    func status(for kind: IntegrationKind) -> IntegrationStatus { app.integrations.status(for: kind) }
    var connectedCount: Int { app.integrations.connectedCount }

    var google: GoogleCalendarIntegration { app.integrations.google }
    var googleState: IntegrationState { google.state }
    var googleSettings: GoogleCalendarSettings { google.settings }

    // MARK: Google Calendar intents

    func connectGoogle() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await google.connect()
            await app.integrations.refreshBusyAndRescheduleIfChanged()
            await loadCalendars()
        } catch is CancellationError {
            // User dismissed the sign-in sheet — not an error.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectGoogle() async {
        isBusy = true
        defer { isBusy = false }
        await google.disconnect()
        availableCalendars = []
        // Busy windows from the old account no longer apply.
        app.scheduling.rescheduleAll()
    }

    func loadCalendars() async {
        guard google.isConnected else { return }
        availableCalendars = (try? await google.availableCalendars()) ?? []
    }

    func isBusyCalendar(_ id: String) -> Bool {
        googleSettings.busyCalendarIDs.contains(id)
    }

    func toggleBusyCalendar(_ id: String) async {
        var settings = googleSettings
        if settings.busyCalendarIDs.contains(id) {
            settings.busyCalendarIDs.remove(id)
        } else {
            settings.busyCalendarIDs.insert(id)
        }
        google.update(settings: settings)
        await app.integrations.refreshBusyAndRescheduleIfChanged()
    }

    func setIncludeAllDay(_ include: Bool) async {
        var settings = googleSettings
        settings.includeAllDayEvents = include
        google.update(settings: settings)
        await app.integrations.refreshBusyAndRescheduleIfChanged()
    }

    func setExportEnabled(_ enabled: Bool) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        if enabled {
            do {
                try await google.enableExport()
                await app.integrations.exportNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            await google.disableExport()
        }
    }

    func syncNow() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        await app.integrations.refreshBusyAndRescheduleIfChanged()
        await app.integrations.exportNow()
    }
}
