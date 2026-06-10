import SwiftUI
import GoalsCore

/// The Goals tab (docs/PLAN.md §2.2 tab 2): a card per goal with milestone
/// progress, linking to detail. A "+" starts a new goal via the coach-style flow.
struct GoalsListView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: GoalsListViewModel?
    @State private var showNewGoal = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    if model.rows.isEmpty {
                        ContentUnavailableView("No goals yet", systemImage: "target",
                                               description: Text("Tap + to shape your first one."))
                    } else {
                        List(model.rows) { row in
                            NavigationLink {
                                GoalDetailView(goalID: row.goal.id)
                            } label: {
                                GoalCard(row: row)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                    }
                } else { ProgressView() }
            }
            .navigationTitle("Goals")
            .background(Palette.screenBackground)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewGoal = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNewGoal) {
                NewGoalView(onFinished: { showNewGoal = false; model?.load() })
            }
        }
        .onAppear {
            if model == nil { model = GoalsListViewModel(app: app) }
            model?.load()
        }
    }
}

private struct GoalCard: View {
    let row: GoalsListViewModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(row.goal.title).font(.headline)
                Spacer()
                StatusBadge(status: row.goal.status)
            }
            if row.totalMilestones > 0 {
                ProgressView(value: row.milestoneProgress)
                    .tint(Palette.accent)
                Text("\(row.completedMilestones)/\(row.totalMilestones) milestones · target \(Format.date(row.goal.targetDate))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

struct StatusBadge: View {
    let status: GoalStatus
    var body: some View {
        Text(label).font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var label: String {
        switch status {
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .abandoned: return "Archived"
        }
    }
    private var color: Color {
        switch status {
        case .active: return Palette.positive
        case .paused: return Palette.gentle
        case .completed: return Palette.accent
        case .abandoned: return .secondary
        }
    }
}

/// A lightweight new-goal flow that reuses the onboarding conversation for an
/// additional goal (the engine supports multiple goals; v1 UX keeps it simple).
struct NewGoalView: View {
    @Environment(AppContainer.self) private var app
    var onFinished: () -> Void

    var body: some View {
        OnboardingView(onFinished: onFinished)
            .environment(app)
    }
}
