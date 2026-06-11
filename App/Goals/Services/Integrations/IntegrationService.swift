import Foundation
import GoalsCore

/// One connectable external service. v1 registers only Google Calendar;
/// adding another integration means a new conforming class plus a catalog
/// flip in `IntegrationDescriptor.catalog` — nothing else changes.
@MainActor
protocol IntegrationProvider: AnyObject {
    nonisolated var kind: IntegrationKind { get }
    /// Restore a persisted session on launch (no UI).
    func restoreConnection() async
    /// Interactive connect (may present auth UI).
    func connect() async throws
    /// Tear down: remote cleanup, then local state.
    func disconnect() async
}

/// A provider that feeds external busy time into the deterministic scheduler.
@MainActor
protocol BusyTimeIntegration: IntegrationProvider {
    /// Network refresh of the local busy cache; true if the data changed.
    func refreshBusyCache(start: CalendarDay, horizonDays: Int) async -> Bool
    /// Last-known busy windows, synchronous — scheduling must work offline.
    func cachedBusyByDay() -> [CalendarDay: [MinuteWindow]]
}

/// A provider that mirrors the schedule out to an external service.
@MainActor
protocol ExportIntegration: IntegrationProvider {
    func exportSchedule(occurrences: [TaskOccurrence]) async
}

enum IntegrationStatus: Equatable {
    case connected(accountLabel: String?)
    case notConnected
    /// Listed in the catalog but no provider shipped yet.
    case comingSoon
    /// Provider exists but the build lacks credentials (e.g. no Google client
    /// ID in Secrets.xcconfig).
    case needsSetup
}

/// Hub for all integrations: the registry the UI lists, the busy-time feed the
/// scheduler reads, and the debounced export hook the scheduler fires.
@MainActor
@Observable
final class IntegrationService {
    let descriptors = IntegrationDescriptor.catalog
    let google: GoogleCalendarIntegration

    private let providers: [IntegrationKind: any IntegrationProvider]
    private let schedule: ScheduleRepository
    private let clock: Clock
    private let horizonDays: Int
    private var exportTask: Task<Void, Never>?
    /// Reschedules triggered here would re-fire onScheduleChanged; this flag
    /// keeps refresh→reschedule→export from looping.
    private var isRefreshing = false

    init(google: GoogleCalendarIntegration,
         schedule: ScheduleRepository,
         clock: Clock,
         horizonDays: Int = 14) {
        self.google = google
        self.providers = [.googleCalendar: google]
        self.schedule = schedule
        self.clock = clock
        self.horizonDays = horizonDays
    }

    func provider(for kind: IntegrationKind) -> (any IntegrationProvider)? {
        providers[kind]
    }

    func status(for kind: IntegrationKind) -> IntegrationStatus {
        guard providers[kind] != nil else { return .comingSoon }
        switch kind {
        case .googleCalendar:
            guard Config.googleSignInAvailable else { return .needsSetup }
            return google.isConnected
                ? .connected(accountLabel: google.accountLabel)
                : .notConnected
        default:
            return .comingSoon
        }
    }

    var connectedCount: Int {
        IntegrationKind.allCases.filter {
            if case .connected = status(for: $0) { return true }
            return false
        }.count
    }

    // MARK: Import

    /// Launch path: restore sessions, refresh busy caches, and reschedule only
    /// if the external picture actually changed. `reschedule` is injected
    /// (AppContainer wires it to SchedulingCoordinator) to avoid a cycle.
    var reschedule: (() -> Void)?

    func refreshImportsAndRescheduleIfChanged() async {
        for provider in providers.values {
            await provider.restoreConnection()
        }
        await refreshBusyAndRescheduleIfChanged()
    }

    func refreshBusyAndRescheduleIfChanged() async {
        var changed = false
        for provider in providers.values {
            if let busy = provider as? BusyTimeIntegration {
                if await busy.refreshBusyCache(start: clock.today, horizonDays: horizonDays) {
                    changed = true
                }
            }
        }
        if changed {
            isRefreshing = true
            reschedule?()
            isRefreshing = false
        }
        // Whether or not placement changed, reconcile the export (cheap when
        // nothing moved: the sync planner produces zero operations).
        scheduleExport()
    }

    /// The scheduler's last-known external busy time, merged across providers.
    /// Synchronous and cache-only by design.
    func cachedBusyByDay() -> [CalendarDay: [MinuteWindow]] {
        var merged: [CalendarDay: [MinuteWindow]] = [:]
        for provider in providers.values {
            if let busy = provider as? BusyTimeIntegration {
                for (day, windows) in busy.cachedBusyByDay() {
                    merged[day, default: []] += windows
                }
            }
        }
        return merged
    }

    // MARK: Export

    /// Debounced export, fired after every reschedule. `rescheduleAll` calls
    /// this once per goal; the debounce coalesces the burst into one sync.
    func scheduleExport() {
        guard !isRefreshing else { return }
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.exportNow()
        }
    }

    func exportNow() async {
        let occurrences = schedule.occurrencesFrom(clock.today)
        for provider in providers.values {
            if let exporter = provider as? ExportIntegration {
                await exporter.exportSchedule(occurrences: occurrences)
            }
        }
    }
}
