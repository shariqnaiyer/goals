import SwiftUI
import SwiftData
import GoalsCore
import GoogleSignIn
#if canImport(UserNotifications)
import UserNotifications
#endif

@main
struct GoalsApp: App {
    let container: ModelContainer
    @State private var app: AppContainer
    @State private var didBootstrap = false

    init() {
        // Build the SwiftData container from the app schema.
        let schema = Schema(AppSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A corrupt store on a local-first app shouldn't brick launch; fall
            // back to an in-memory store so the user can at least start over.
            container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        }
        self.container = container
        _app = State(initialValue: AppContainer(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task {
                    guard !didBootstrap else { return }
                    didBootstrap = true
                    NotificationCoordinator.shared.configure(app: app)
                    app.bootstrap()
                    // Async: restore Google sign-in, refresh the busy-time
                    // cache, and reschedule only if the calendar changed.
                    // bootstrap() above already scheduled from the local cache,
                    // so launch stays fully offline-capable.
                    await app.integrations.refreshImportsAndRescheduleIfChanged()
                }
        }
        .modelContainer(container)
    }
}

/// Routes notification action responses (Done / Snooze) back into the domain.
@MainActor
final class NotificationCoordinator: NSObject, ObservableObject {
    static let shared = NotificationCoordinator()
    private weak var app: AppContainer?

    func configure(app: AppContainer) {
        self.app = app
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().delegate = self
        #endif
    }
}

#if canImport(UserNotifications)
extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let app,
              let idString = response.notification.request.content.userInfo["occurrenceID"] as? String,
              let id = UUID(uuidString: idString) else { return }

        // Locate the occurrence and apply the chosen action.
        let all = app.store.occurrencesFrom(app.clock.day(offset: -1))
        guard let occ = all.first(where: { $0.id == id }) else { return }

        switch response.actionIdentifier {
        case NotificationService.doneActionID:
            app.taskActions.complete(occ)
        case NotificationService.snoozeActionID:
            app.taskActions.snooze(occ)
            app.scheduling.reschedule(goalID: occ.goalID)
        default:
            break
        }
    }
}
#endif
