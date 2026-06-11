import SwiftUI
import GoalsCore

/// Top-level flow: a warm Welcome → conversational onboarding for first run,
/// then the main tab bar (docs/PLAN.md §2.2). The weekly review is presented as
/// a sheet when due, not as a permanent tab.
struct RootView: View {
    @Environment(AppContainer.self) private var app
    @State private var phase: Phase = .welcome

    enum Phase { case welcome, onboarding, main }

    var body: some View {
        Group {
            switch phase {
            case .welcome:
                WelcomeView(onBegin: { phase = .onboarding })
            case .onboarding:
                OnboardingView(onFinished: { phase = .main })
            case .main:
                MainTabView()
            }
        }
        .tint(Palette.accent)
        .onAppear {
            AppAppearance.configure()
            if app.hasCompletedOnboarding { phase = .main }
        }
    }
}

struct MainTabView: View {
    @Environment(AppContainer.self) private var app
    @State private var reviewModel: WeeklyReviewViewModel?

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "checkmark.circle") }
            GoalsListView()
                .tabItem { Label("Goals", systemImage: "target") }
            NavigationStack { CoachView(goalID: nil) }
                .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right") }
            SettingsView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
        .task {
            // Auto-present the weekly review only when it's due and has content.
            // Setting reviewModel is what drives presentation (.sheet(item:)).
            let model = WeeklyReviewViewModel(app: app)
            if model.isDue {
                await model.load()
                if !model.reviews.isEmpty { reviewModel = model }
            }
        }
        .sheet(item: $reviewModel) { model in
            WeeklyReviewView(model: model)
        }
    }
}

/// Configures warm, native nav/tab bar chrome once at launch. Large titles sit
/// directly on the cream page; bars frost as content scrolls under them.
enum AppAppearance {
    static func configure() {
        let ink = UIColor(Palette.textPrimary)

        let opaque = UINavigationBarAppearance()
        opaque.configureWithDefaultBackground()
        opaque.titleTextAttributes = [.foregroundColor: ink]
        opaque.largeTitleTextAttributes = [.foregroundColor: ink]

        let transparent = UINavigationBarAppearance()
        transparent.configureWithTransparentBackground()
        transparent.titleTextAttributes = [.foregroundColor: ink]
        transparent.largeTitleTextAttributes = [.foregroundColor: ink]

        UINavigationBar.appearance().standardAppearance = opaque
        UINavigationBar.appearance().compactAppearance = opaque
        UINavigationBar.appearance().scrollEdgeAppearance = transparent

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}
