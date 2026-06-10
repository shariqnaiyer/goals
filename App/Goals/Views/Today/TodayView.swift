import SwiftUI
import GoalsCore

/// The home screen (docs/PLAN.md §2.2 tab 1): today's tasks with one-tap
/// complete / snooze / skip, a forgiving daily-progress header, and tomorrow's
/// preview. Repeated misses surface a gentle replan offer — never a red badge.
struct TodayView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: TodayViewModel?
    @State private var skipTarget: TodayViewModel.Item?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    list(model)
                } else { ProgressView() }
            }
            .navigationTitle("Today")
            .background(Palette.screenBackground)
        }
        .onAppear {
            if model == nil { model = TodayViewModel(app: app) }
            model?.load()
        }
    }

    @ViewBuilder
    private func list(_ model: TodayViewModel) -> some View {
        if model.todayItems.isEmpty && model.tomorrowItems.isEmpty {
            ContentUnavailableView(
                "Nothing scheduled",
                systemImage: "sparkles",
                description: Text("Add a goal and I'll fill in your days."))
        } else {
            List {
                Section {
                    ProgressHeader(done: model.completedToday, total: model.totalToday,
                                   allDone: model.allDoneToday)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if !model.todayItems.isEmpty {
                    Section("Today") {
                        ForEach(model.todayItems) { item in
                            TaskRow(item: item,
                                    onComplete: { model.complete(item) },
                                    onSnooze: { model.snooze(item, toTomorrow: false) },
                                    onSkip: { skipTarget = item })
                        }
                    }
                }
                if !model.tomorrowItems.isEmpty {
                    Section("Tomorrow") {
                        ForEach(model.tomorrowItems) { item in
                            TaskRow(item: item, dimmed: true, onComplete: {}, onSnooze: {}, onSkip: {})
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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

private struct ProgressHeader: View {
    let done: Int
    let total: Int
    let allDone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if total == 0 {
                Text("A clear day. Rest is part of the plan. 🌱").font(.headline)
            } else if allDone {
                Text("That's everything for today — nice work! 🎉").font(.headline)
            } else {
                Text("\(done) of \(total) done").font(.headline)
                ProgressView(value: Double(done), total: Double(total))
                    .tint(Palette.positive)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TaskRow: View {
    let item: TodayViewModel.Item
    var dimmed: Bool = false
    var onComplete: () -> Void
    var onSnooze: () -> Void
    var onSkip: () -> Void

    private var occ: TaskOccurrence { item.occurrence }
    private var isDone: Bool { occ.status == .done }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isDone ? Palette.positive : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(dimmed)

            VStack(alignment: .leading, spacing: 2) {
                Text(occ.title)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? .secondary : .primary)
                Text("\(item.goalTitle) · \(Format.window(occ.window)) · \(Format.duration(occ.effortMinutes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(dimmed ? 0.55 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !dimmed && !isDone {
                Button("Skip", role: .destructive, action: onSkip)
                Button("Snooze", action: onSnooze).tint(Palette.gentle)
            }
        }
    }
}

/// Offered after repeated misses: a one-tap path into the coach to ease the plan.
private struct AdaptationPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: TodayViewModel.AdaptationPrompt

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 44)).foregroundStyle(Palette.accent)
                Text("Life's been busy with “\(prompt.goalTitle)”")
                    .font(.title3.bold()).multilineTextAlignment(.center)
                Text("You've missed a few in a row. Want me to make this lighter so it fits your week better?")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                NavigationLink {
                    GoalAdaptationView(goalID: prompt.goalID, trigger: prompt.trigger)
                } label: {
                    Text("Yes, let's adjust").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("I'm okay for now") { dismiss() }
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancelAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
