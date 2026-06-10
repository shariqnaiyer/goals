import SwiftUI
import GoalsCore

/// A goal's detail (docs/PLAN.md §2.2): milestone timeline, upcoming tasks, and
/// the auditable plan history (every revision + the LLM's rationale). Hosts the
/// lifecycle actions (pause/resume/complete/abandon) and a path to adapt.
struct GoalDetailView: View {
    @Environment(AppContainer.self) private var app
    let goalID: UUID
    @State private var model: GoalDetailViewModel?
    @State private var showAbandon = false

    var body: some View {
        Group {
            if let model, let plan = model.plan {
                content(model, plan: plan)
            } else { ProgressView() }
        }
        .navigationTitle("Goal")
        .navigationBarTitleDisplayMode(.inline)
        .background(Palette.screenBackground)
        .onAppear {
            if model == nil { model = GoalDetailViewModel(app: app, goalID: goalID) }
            model?.load()
        }
    }

    @ViewBuilder
    private func content(_ model: GoalDetailViewModel, plan: Plan) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(plan.goal.title).font(.title3.bold())
                        Spacer()
                        StatusBadge(status: plan.goal.status)
                    }
                    if !plan.goal.motivationStatement.isEmpty {
                        Text("“\(plan.goal.motivationStatement)”")
                            .font(.subheadline).italic().foregroundStyle(.secondary)
                    }
                    Label("This week: \(Format.percent(model.completionRate)) done",
                          systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Milestones") {
                ForEach(plan.sortedMilestones) { milestone in
                    HStack {
                        Image(systemName: milestone.status == .completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(milestone.status == .completed ? Palette.positive : .secondary)
                        VStack(alignment: .leading) {
                            Text(milestone.title)
                            if let date = milestone.targetDate {
                                Text(Format.date(date)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !model.upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(model.upcoming.prefix(8)) { occ in
                        HStack {
                            Text(occ.title)
                            Spacer()
                            Text("\(Format.relativeDay(occ.day, today: app.clock.today)) · \(Format.window(occ.window))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Adjust") {
                NavigationLink {
                    GoalAdaptationView(goalID: goalID, trigger: .userRequest)
                } label: {
                    Label("Re-plan with the coach", systemImage: "wand.and.stars")
                }
                NavigationLink {
                    CoachView(goalID: goalID)
                } label: {
                    Label("Chat about this goal", systemImage: "bubble.left.and.bubble.right")
                }
            }

            if !model.revisions.isEmpty {
                Section("Plan history") {
                    ForEach(model.revisions) { revision in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(revision.rationale).font(.subheadline)
                                Spacer()
                                if !revision.accepted {
                                    Text("dismissed").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text("\(triggerLabel(revision.trigger)) · \(revision.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                lifecycleButtons(model, plan: plan)
            }
        }
        .confirmationDialog("Archive this goal?", isPresented: $showAbandon) {
            Button("Archive", role: .destructive) { model.abandon(reason: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It'll move to your archive. You can always start something new.")
        }
    }

    @ViewBuilder
    private func lifecycleButtons(_ model: GoalDetailViewModel, plan: Plan) -> some View {
        switch plan.goal.status {
        case .active:
            Button("Pause goal") { model.pause() }
            Button("Mark complete") { model.complete() }
            Button("Archive goal", role: .destructive) { showAbandon = true }
        case .paused:
            Button("Resume goal") { model.resume() }
            Button("Archive goal", role: .destructive) { showAbandon = true }
        case .completed, .abandoned:
            Button("Reactivate goal") { model.resume() }
        }
    }

    private func triggerLabel(_ trigger: RevisionTrigger) -> String {
        switch trigger {
        case .userRequest: return "You asked"
        case .missedTasks: return "After misses"
        case .weeklyReview: return "Weekly review"
        case .goalEdited: return "Goal edited"
        case .overcommitted: return "Overcommitted"
        case .initialPlan: return "Created"
        }
    }
}

/// Generates and previews an adaptation proposal for a goal, then applies or
/// dismisses it (docs/PLAN.md §3.3, §5).
struct GoalAdaptationView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let goalID: UUID
    let trigger: RevisionTrigger
    @State private var model: GoalDetailViewModel?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let model {
                    if model.isProposing {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Thinking through a kinder plan…").foregroundStyle(.secondary)
                        }
                        .padding(.top, 40)
                    } else if let result = model.proposedResult {
                        PlanDiffCard(
                            diff: result.diff,
                            onAccept: result.diff.isQuestionOnly ? nil : {
                                model.acceptProposal(); dismiss()
                            },
                            onDismiss: { model.rejectProposal(); dismiss() },
                            onChoose: result.diff.isQuestionOnly ? { choice in
                                Task { await model.proposeRevision(userMessage: choice, trigger: trigger) }
                            } : nil)
                    } else if let error = model.proposalError {
                        ContentUnavailableView("Couldn't adjust", systemImage: "exclamationmark.triangle",
                                               description: Text(error))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Adjust plan")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let m = GoalDetailViewModel(app: app, goalID: goalID)
                model = m
                await m.proposeRevision(trigger: trigger)
            }
        }
    }
}
