import Foundation
import Observation
import SwiftData
import GoalsCore

/// Composition root / dependency injection (docs/PLAN.md §3.1 "MVVM-lite + a
/// domain layer"). Constructs the repositories and services once and hands them
/// to view models. Held as a single `@Observable` environment object.
@MainActor
@Observable
final class AppContainer {
    let clock: Clock
    let llm: LLMService

    let store: SwiftDataStore
    let performance: PerformanceService
    let notifications: NotificationService
    let scheduling: SchedulingCoordinator
    let planEngine: PlanEngine
    let taskActions: TaskActionService
    let coach: CoachService
    let integrations: IntegrationService

    /// True when talking to the real proxy; false when using the offline mock.
    let usingLiveBackend: Bool

    init(context: ModelContext, clock: Clock = .live) {
        self.clock = clock

        // Select the LLM service: real proxy if configured, else the offline mock.
        if let base = Config.llmProxyBaseURL {
            self.llm = LLMClient(baseURL: base, tokenProvider: { await DeviceAttestation.token() })
            self.usingLiveBackend = true
        } else {
            self.llm = MockLLMService(calendar: clock.calendar)
            self.usingLiveBackend = false
        }

        let store = SwiftDataStore(context: context)
        self.store = store

        let notifications = NotificationService()
        self.notifications = notifications

        let performance = PerformanceService(schedule: store, clock: clock)
        self.performance = performance

        let scheduling = SchedulingCoordinator(goals: store, schedule: store,
                                               constraints: store, performance: performance,
                                               notifications: notifications, clock: clock)
        self.scheduling = scheduling

        self.planEngine = PlanEngine(goals: store, revisions: store, constraints: store,
                                     performance: performance, scheduling: scheduling,
                                     llm: llm, clock: clock)

        self.taskActions = TaskActionService(schedule: store, goals: store,
                                             performance: performance, scheduling: scheduling,
                                             clock: clock)

        self.coach = CoachService(chat: store, goals: store, performance: performance,
                                  llm: llm, clock: clock)

        // Integrations: Google Calendar provider + the registry hub. Wired to
        // the scheduler via closures so the dependency direction stays
        // scheduler ← container → integrations (no cycle).
        let googleAuth = GoogleAuthService()
        let google = GoogleCalendarIntegration(
            auth: googleAuth,
            client: GoogleCalendarClient(tokenProvider: { try await googleAuth.freshAccessToken() }),
            repo: store,
            clock: clock)
        let integrations = IntegrationService(google: google, schedule: store, clock: clock)
        self.integrations = integrations
        integrations.reschedule = { [weak scheduling] in scheduling?.rescheduleAll() }
        scheduling.externalBusy = { [weak integrations] in integrations?.cachedBusyByDay() ?? [:] }
        scheduling.onScheduleChanged = { [weak integrations] in integrations?.scheduleExport() }
    }

    /// Run on launch: ensure a constraint profile exists, register notification
    /// categories, and refresh schedules + notifications for the rolling horizon.
    func bootstrap() {
        if store.profile().workHours.isEmpty && store.profile().wakeMinute.isEmpty {
            store.save(.makeDefault())
        }
        notifications.registerCategories()
        scheduling.rescheduleAll()
    }

    var hasCompletedOnboarding: Bool { store.hasCompletedOnboarding() }
}

/// Stub for App Attest device attestation (docs/PLAN.md §3.2). In production this
/// produces an attested token the proxy verifies; in development it returns nil
/// (the mock path needs no auth).
enum DeviceAttestation {
    static func token() async -> String? { nil }
}
