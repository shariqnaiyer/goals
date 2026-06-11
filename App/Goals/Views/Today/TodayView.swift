import SwiftUI
import GoalsCore

/// The home screen (docs/PLAN.md §2.2 tab 1): today's tasks with one-tap
/// complete, forgiving daily progress, and tomorrow's preview. Repeated misses
/// surface a gentle replan offer — never a red badge.
struct TodayView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: TodayViewModel?
    @State private var skipTarget: TodayViewModel.Item?
    @State private var reviewModel: WeeklyReviewViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { list(model) } else { ProgressView() }
            }
            .navigationTitle("Today")
            .background(Palette.bgApp.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reviewModel = WeeklyReviewViewModel(app: app)
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Your week")
                }
            }
            .sheet(item: $reviewModel) { model in
                WeeklyReviewView(model: model)
            }
        }
        .onAppear {
            if model == nil { model = TodayViewModel(app: app) }
            model?.load()
        }
    }

    @ViewBuilder
    private func list(_ model: TodayViewModel) -> some View {
        if model.todayItems.isEmpty && model.tomorrowItems.isEmpty {
            ContentUnavailableView {
                Label("A clear day", systemImage: "leaf")
            } description: {
                Text("Rest is part of the plan. Add a goal and I'll fill in your days.")
            }
        } else {
            List {
                Section {
                    ProgressHeader(done: model.completedToday, total: model.totalToday, allDone: model.allDoneToday)
                        .listRowInsets(EdgeInsets(top: Metric.s2, leading: Metric.s5, bottom: Metric.s4, trailing: Metric.s5))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if !model.todayItems.isEmpty {
                    Section {
                        ForEach(model.todayItems) { item in
                            TaskRow(item: item,
                                    onComplete: { withAnimation(.springy) { model.complete(item) } },
                                    onSnooze: { model.snooze(item, toTomorrow: false) },
                                    onSkip: { skipTarget = item })
                                .listRowBackground(Palette.cardBackground)
                                .listRowSeparatorTint(Palette.hairline)
                        }
                    } header: { OverlineHeader("Today") }
                }

                if !model.tomorrowItems.isEmpty {
                    Section {
                        ForEach(model.tomorrowItems) { item in
                            TaskRow(item: item, dimmed: true, onComplete: {}, onSnooze: {}, onSkip: {})
                                .listRowBackground(Palette.cardBackground)
                                .listRowSeparatorTint(Palette.hairline)
                        }
                    } header: { OverlineHeader("Tomorrow") }
                }

                Section {
                    Text("Skip anything that doesn't fit — I'll adjust.")
                        .font(AppFont.footnote).foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.bgApp.ignoresSafeArea())
            .confirmationDialog("Skip this one?", isPresented: skipBinding, presenting: skipTarget) { item in
                Button("Not feeling it today") { model.skip(item, reason: "not feeling it") }
                Button("No time today") { model.skip(item, reason: "no time") }
                Button("Already did it elsewhere") { model.skip(item, reason: "done elsewhere") }
                Button("Just skip", role: .destructive) { model.skip(item, reason: nil) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Skipping is fine — I'll learn from it and adjust if this keeps happening.")
            }
            .sheet(item: adaptationBinding(model)) { prompt in
                AdaptationPromptSheet(prompt: prompt)
            }
        }
    }

    private var skipBinding: Binding<Bool> {
        Binding(get: { skipTarget != nil }, set: { if !$0 { skipTarget = nil } })
    }
    private func adaptationBinding(_ model: TodayViewModel) -> Binding<TodayViewModel.AdaptationPrompt?> {
        Binding(get: { model.adaptationPrompt }, set: { if $0 == nil { model.dismissAdaptationPrompt() } })
    }
}

/// Uppercase, tracked list section header in the brand voice.
private struct OverlineHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(AppFont.overline).tracking(0.6)
            .foregroundStyle(Palette.textTertiary)
            .textCase(nil)
    }
}

/// Forgiving daily progress — frames the daily minimum as a win, never a partial
/// failure. Celebrates a finished or genuinely clear day.
private struct ProgressHeader: View {
    let done: Int
    let total: Int
    let allDone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s3) {
            if allDone {
                (Text("That's everything for today — ")
                    + Text("nice work.").foregroundColor(Palette.accent))
                    .font(AppFont.title2).foregroundStyle(Palette.textPrimary)
            } else {
                (Text("\(done) of \(total) done")
                    + Text("  ·  daily minimum met").foregroundColor(Palette.textTertiary))
                    .font(AppFont.title2).foregroundStyle(Palette.textPrimary)
                GProgressBar(value: total > 0 ? Double(done) / Double(total) : 0, tone: .success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One task row: a spring completion check, title + meta, and a gentle
/// "minimum viable" hint in amber. Swipe for skip/snooze.
private struct TaskRow: View {
    let item: TodayViewModel.Item
    var dimmed: Bool = false
    var onComplete: () -> Void
    var onSnooze: () -> Void
    var onSkip: () -> Void

    private var occ: TaskOccurrence { item.occurrence }
    private var isDone: Bool { occ.status == .done }

    var body: some View {
        HStack(spacing: Metric.s3) {
            TaskCheck(isDone: isDone, action: onComplete)
                .disabled(dimmed)
                .opacity(dimmed ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(occ.title)
                    .font(AppFont.body)
                    .strikethrough(isDone, color: Palette.textTertiary)
                    .foregroundStyle(isDone ? Palette.textTertiary : Palette.textPrimary)
                if let slice = occ.slice {
                    // The concrete content of this session ("Chapter 4").
                    Text(slice.label)
                        .font(AppFont.subhead)
                        .foregroundStyle(isDone ? Palette.textTertiary : Palette.accent)
                }
                Text("\(item.goalTitle) · \(Format.window(occ.window)) · \(Format.duration(occ.effortMinutes))")
                    .font(AppFont.footnote).foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            if let mvv = minimumHint, !isDone, !dimmed {
                Text("min: \(mvv)").font(AppFont.caption1).foregroundStyle(Palette.gentle)
            }
        }
        .padding(.vertical, 4)
        .opacity(dimmed ? 0.6 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !dimmed && !isDone {
                Button("Skip", role: .destructive, action: onSkip)
                Button("Snooze", action: onSnooze).tint(Palette.gentle)
            }
        }
    }

    /// The template's minimum-viable variant, if any (kept lightweight here).
    private var minimumHint: String? { nil }
}

/// Offered after repeated misses: a one-tap path into a gentler plan. Framed as
/// care, never as a scolding (docs/PLAN.md §2.3, §5).
private struct AdaptationPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: TodayViewModel.AdaptationPrompt

    var body: some View {
        NavigationStack {
            VStack(spacing: Metric.s5) {
                Spacer()
                Image(systemName: "heart.text.square")
                    .font(.system(size: 46)).foregroundStyle(Palette.accent)
                Text("Life's been busy with “\(prompt.goalTitle)”")
                    .font(AppFont.title3).multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textPrimary)
                Text("You've missed a few in a row. Want me to make this lighter so it fits your week better?")
                    .font(AppFont.body).multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: 300)
                Spacer()
                NavigationLink {
                    GoalAdaptationView(goalID: prompt.goalID, trigger: prompt.trigger)
                } label: {
                    Text("Yes, let's adjust")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("I'm okay for now") { dismiss() }
                    .font(AppFont.headline)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, Metric.s6)
            .padding(.bottom, Metric.s6)
            .background(Palette.bgApp.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
