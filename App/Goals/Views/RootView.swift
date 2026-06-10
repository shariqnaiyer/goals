import SwiftUI
import GoalsCore

/// Top-level gate: onboarding for first run, then the main tab bar
/// (docs/PLAN.md §2.2). The weekly review is presented as a sheet when due,
/// rather than living as a permanent tab.
struct RootView: View {
    @Environment(AppContainer.self) private var app
    @State private var hasOnboarded = false
    @State private var showReview = false

    var body: some View {
        Group {
            if hasOnboarded {
                MainTabView(showReview: $showReview)
            } else {
                OnboardingView(onFinished: { hasOnboarded = true })
            }
        }
        .onAppear { hasOnboarded = app.hasCompletedOnboarding }
    }
}

struct MainTabView: View {
    @Environment(AppContainer.self) private var app
    @Binding var showReview: Bool
    @State private var reviewModel: WeeklyReviewViewModel?

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "checklist") }
            GoalsListView()
                .tabItem { Label("Goals", systemImage: "target") }
            NavigationStack { CoachView(goalID: nil) }
                .tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            // Offer the weekly review when it's due.
            let model = WeeklyReviewViewModel(app: app)
            reviewModel = model
            if model.isDue {
                await model.load()
                if !model.reviews.isEmpty { showReview = true }
            }
        }
        .sheet(isPresented: $showReview) {
            if let reviewModel {
                WeeklyReviewView(model: reviewModel)
            }
        }
    }
}
