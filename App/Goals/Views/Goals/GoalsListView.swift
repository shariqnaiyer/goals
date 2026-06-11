import SwiftUI
import GoalsCore

/// The Goals tab (docs/PLAN.md §2.2 tab 2): a card per goal with milestone
/// progress and a calm filter, linking to detail. "+" starts a new goal through
/// the same conversational flow.
struct GoalsListView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: GoalsListViewModel?
    @State private var filter: Filter = .active
    @State private var showNewGoal = false

    enum Filter: String, CaseIterable { case active = "Active", paused = "Paused", done = "Done" }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Metric.s5)
                    .padding(.bottom, Metric.s2)

                    let rows = filtered(model.rows)
                    if rows.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: Metric.s4) {
                            ForEach(rows) { row in
                                NavigationLink {
                                    GoalDetailView(goalID: row.goal.id)
                                } label: {
                                    GoalCard(row: row)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, Metric.s4)
                        .padding(.top, Metric.s1)
                    }
                } else { ProgressView().padding(.top, 80) }
            }
            .navigationTitle("Goals")
            .background(Palette.bgApp.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewGoal = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New goal")
                }
            }
            .sheet(isPresented: $showNewGoal) {
                NavigationStack {
                    OnboardingView(onFinished: { showNewGoal = false; model?.load() })
                        .navigationTitle("New goal")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .onAppear {
            if model == nil { model = GoalsListViewModel(app: app) }
            model?.load()
        }
    }

    private func filtered(_ rows: [GoalsListViewModel.Row]) -> [GoalsListViewModel.Row] {
        rows.filter { row in
            switch filter {
            case .active: row.goal.status == .active
            case .paused: row.goal.status == .paused
            case .done: row.goal.status == .completed || row.goal.status == .abandoned
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Metric.s3) {
            BrandMark(size: 52, color: Palette.textPlaceholder)
            Text(filter == .active ? "No goals yet" : "Nothing here")
                .font(AppFont.headline).foregroundStyle(Palette.textSecondary)
            Text(filter == .active ? "Tap + to shape your first one." : "Goals you pause or finish show up here.")
                .font(AppFont.subhead).foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72).padding(.horizontal, Metric.s7)
    }
}

private struct GoalCard: View {
    let row: GoalsListViewModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.goal.title).font(AppFont.headline).foregroundStyle(Palette.textPrimary)
                Spacer()
                StatusBadge(status: row.goal.status)
            }
            if row.totalMilestones > 0 {
                GProgressBar(value: row.milestoneProgress, tone: row.goal.status == .paused ? .gentle : .accent)
                Text("\(row.completedMilestones)/\(row.totalMilestones) milestones · target \(Format.date(row.goal.targetDate))")
                    .font(AppFont.footnote).foregroundStyle(Palette.textTertiary)
            } else {
                Text("Target \(Format.date(row.goal.targetDate))")
                    .font(AppFont.footnote).foregroundStyle(Palette.textTertiary)
            }
        }
        .card()
    }
}
