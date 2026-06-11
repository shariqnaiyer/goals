import SwiftUI
import GoalsCore

/// A goal's detail (docs/PLAN.md §2.2): milestone timeline, upcoming tasks, and
/// the auditable plan history (every revision + the coach's one-line rationale).
/// Hosts the lifecycle actions and the path to adapt.
struct GoalDetailView: View {
    @Environment(AppContainer.self) private var app
    let goalID: UUID
    @State private var model: GoalDetailViewModel?
    @State private var showAbandon = false

    var body: some View {
        ScrollView {
            if let model, let plan = model.plan {
                content(model, plan: plan)
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .navigationTitle("Goal")
        .navigationBarTitleDisplayMode(.inline)
        .background(Palette.bgApp.ignoresSafeArea())
        .onAppear {
            if model == nil { model = GoalDetailViewModel(app: app, goalID: goalID) }
            model?.load()
        }
        .confirmationDialog("Archive this goal?", isPresented: $showAbandon) {
            Button("Archive", role: .destructive) { model?.abandon(reason: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It'll move to your archive. You can always start something new.")
        }
    }

    @ViewBuilder
    private func content(_ model: GoalDetailViewModel, plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero
            VStack(alignment: .leading, spacing: Metric.s3) {
                HStack(alignment: .top) {
                    Text(plan.goal.title).font(AppFont.title2).foregroundStyle(Palette.textPrimary)
                    Spacer()
                    StatusBadge(status: plan.goal.status)
                }
                if !plan.goal.motivationStatement.isEmpty {
                    Text("“\(plan.goal.motivationStatement)”")
                        .font(AppFont.subhead).italic()
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.leading, Metric.s3)
                        .overlay(Rectangle().frame(width: 2).foregroundStyle(Palette.accentSoftBorder), alignment: .leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 15)).foregroundStyle(Palette.accent)
                    Text("This week: \(Format.percent(model.completionRate)) done")
                        .font(AppFont.subhead).foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.horizontal, Metric.s5).padding(.top, Metric.s2)

            // Milestones
            SectionLabel("Milestones")
            MilestoneTimeline(milestones: plan.sortedMilestones)
                .padding(.horizontal, Metric.s5)

            // Upcoming
            if !model.upcoming.isEmpty {
                SectionLabel("Upcoming")
                CardGroup {
                    ForEach(Array(model.upcoming.prefix(8))) { occ in
                        DetailRow(title: occ.title,
                                  trailing: "\(Format.relativeDay(occ.day, today: app.clock.today)) · \(Format.window(occ.window))")
                    }
                }
            }

            // Adjust
            SectionLabel("Adjust")
            CardGroup {
                NavigationLink {
                    GoalAdaptationView(goalID: goalID, trigger: .userRequest)
                } label: {
                    DetailRow(icon: "wand.and.stars", title: "Re-plan with the coach", chevron: true)
                }.buttonStyle(.plain)
                NavigationLink {
                    CoachView(goalID: goalID)
                } label: {
                    DetailRow(icon: "bubble.left.and.bubble.right", title: "Chat about this goal", chevron: true)
                }.buttonStyle(.plain)
            }

            // Plan history
            if !model.revisions.isEmpty {
                SectionLabel("Plan history")
                CardGroup {
                    ForEach(model.revisions) { revision in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(revision.rationale).font(AppFont.subhead).foregroundStyle(Palette.textPrimary)
                            Text("\(triggerLabel(revision.trigger)) · \(revision.timestamp.formatted(date: .abbreviated, time: .shortened))\(revision.accepted ? "" : " · dismissed")")
                                .font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metric.s4).padding(.vertical, 10)
                    }
                }
            }

            // Lifecycle
            SectionLabel("Manage")
            CardGroup {
                lifecycleRows(model, plan: plan)
            }
            .padding(.bottom, Metric.s7)
        }
    }

    @ViewBuilder
    private func lifecycleRows(_ model: GoalDetailViewModel, plan: Plan) -> some View {
        switch plan.goal.status {
        case .active:
            Button { model.pause() } label: { DetailRow(title: "Pause goal") }.buttonStyle(.plain)
            Button { model.complete() } label: { DetailRow(title: "Mark complete") }.buttonStyle(.plain)
            Button { showAbandon = true } label: { DetailRow(title: "Archive goal", tint: Palette.danger) }.buttonStyle(.plain)
        case .paused:
            Button { model.resume() } label: { DetailRow(title: "Resume goal") }.buttonStyle(.plain)
            Button { showAbandon = true } label: { DetailRow(title: "Archive goal", tint: Palette.danger) }.buttonStyle(.plain)
        case .completed, .abandoned:
            Button { model.resume() } label: { DetailRow(title: "Reactivate goal") }.buttonStyle(.plain)
        }
    }

    private func triggerLabel(_ trigger: RevisionTrigger) -> String {
        switch trigger {
        case .userRequest: "You asked"
        case .missedTasks: "After misses"
        case .weeklyReview: "Weekly review"
        case .goalEdited: "Goal edited"
        case .overcommitted: "Rebalanced"
        case .initialPlan: "Created"
        }
    }
}

// MARK: - Detail building blocks

/// A warm-white grouped container with inset hairline separators between rows.
struct CardGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .shadow(color: Color(hex: 0x362E24).opacity(0.05), radius: 12, x: 0, y: 4)
        .padding(.horizontal, Metric.s4)
    }
}

private struct DetailRow: View {
    var icon: String? = nil
    let title: String
    var trailing: String? = nil
    var chevron: Bool = false
    var tint: Color = Palette.textPrimary

    var body: some View {
        HStack(spacing: Metric.s3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 24)
            }
            Text(title).font(AppFont.body).foregroundStyle(tint)
            Spacer()
            if let trailing {
                Text(trailing).font(AppFont.footnote).foregroundStyle(Palette.textTertiary)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textPlaceholder)
            }
        }
        .padding(.horizontal, Metric.s4).padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Palette.hairline).padding(.leading, Metric.s4), alignment: .bottom)
    }
}

/// A vertical milestone timeline: a rail of dots connected by a line, sage when
/// completed.
struct MilestoneTimeline: View {
    let milestones: [Milestone]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, m in
                HStack(alignment: .top, spacing: Metric.s3) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .strokeBorder(m.status == .completed ? Palette.positive : Palette.hairlineStrong, lineWidth: 2)
                                .background(Circle().fill(m.status == .completed ? Palette.positive : Palette.bgApp))
                                .frame(width: 22, height: 22)
                            if m.status == .completed {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                            }
                        }
                        if index < milestones.count - 1 {
                            Rectangle().fill(Palette.hairlineStrong).frame(width: 2).frame(minHeight: 24)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(AppFont.callout.weight(.medium)).foregroundStyle(Palette.textPrimary)
                        if let date = m.targetDate {
                            Text("Target \(Format.date(date))").font(AppFont.footnote).foregroundStyle(Palette.textTertiary)
                        }
                        if !m.completionCriteria.isEmpty {
                            Text(m.completionCriteria).font(AppFont.footnote).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(.bottom, Metric.s4)
                    Spacer()
                }
            }
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
            VStack(spacing: Metric.s5) {
                if let model {
                    if model.isProposing {
                        VStack(spacing: Metric.s3) {
                            TypingIndicator()
                            Text("Thinking through a kinder plan…")
                                .font(AppFont.subhead).foregroundStyle(Palette.textTertiary)
                        }
                        .padding(.top, 60)
                    } else if let result = model.proposedResult {
                        PlanDiffCard(
                            diff: result.diff,
                            onAccept: result.diff.isQuestionOnly ? nil : { model.acceptProposal(); dismiss() },
                            onDismiss: { model.rejectProposal(); dismiss() },
                            onChoose: result.diff.isQuestionOnly ? { choice in
                                Task { await model.proposeRevision(userMessage: choice, trigger: trigger) }
                            } : nil)
                    } else if let error = model.proposalError {
                        ContentUnavailableView("Couldn't adjust", systemImage: "exclamationmark.bubble",
                                               description: Text(error))
                    }
                }
            }
            .padding(Metric.s4)
        }
        .navigationTitle("Adjust plan")
        .navigationBarTitleDisplayMode(.inline)
        .background(Palette.bgApp.ignoresSafeArea())
        .task {
            if model == nil {
                let m = GoalDetailViewModel(app: app, goalID: goalID)
                model = m
                await m.proposeRevision(trigger: trigger)
            }
        }
    }
}
