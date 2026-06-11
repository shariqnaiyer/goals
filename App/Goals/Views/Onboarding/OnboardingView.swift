import SwiftUI
import GoalsCore

/// The Guided Discovery Interview (docs/PLAN.md — onboarding redesign): one
/// continuous card-based chat that learns the person, surfaces and splits their
/// goals, probes each to concreteness, confirms the week, then formalizes 1–3
/// goals. The composer stays available through every conversational stage.
struct OnboardingView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: OnboardingViewModel?
    @State private var input = ""
    var isAddingGoal: Bool = false
    var onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CoachHeader(title: "Your coach", subtitle: "Getting to know you", online: false)
            if let model {
                StageRail(phase: model.phase)
                content(model)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .background(Palette.bgApp.ignoresSafeArea())
        .onAppear {
            if model == nil {
                let m = OnboardingViewModel(app: app)
                m.start(addingGoal: isAddingGoal)
                model = m
            }
        }
        .onChange(of: model?.phase) { _, phase in
            if phase == .finished { onFinished() }
        }
    }

    @ViewBuilder
    private func content(_ model: OnboardingViewModel) -> some View {
        ChatScrollView(messageCount: model.messages.count,
                       isTyping: model.isAssistantTyping || model.phase == .generatingPlan) {
            ForEach(model.messages) { message in
                ChatBubble(message: message).transition(.fadeUp)
            }

            // Probe chips (book choices, "most days", …) — one tap always advances.
            if !model.currentChoices.isEmpty && !model.isChoosingGoals
                && (model.phase == .grounding || model.phase == .concretizing) {
                FlowChips(choices: model.currentChoices) { choice in
                    Task { await model.choose(choice) }
                }
                .transition(.fadeUp)
            }

            // Stage 2: pick 1–3 goals to start now.
            if model.isChoosingGoals {
                GoalSetCard(aspirations: model.state.aspirations,
                            selected: model.selectedAspirationIDs,
                            canStart: model.canStartSelected,
                            onToggle: { model.toggleAspiration($0) },
                            onStart: { Task { await model.startWithSelected() } })
                    .transition(.fadeUp)
            }

            if model.phase == .generatingPlan {
                HStack(spacing: Metric.s2) {
                    TypingIndicator()
                    Text("Sketching your plan…").font(AppFont.subhead).foregroundStyle(Palette.textTertiary)
                }
            } else if model.isAssistantTyping {
                TypingIndicator()
            }

            // Stage 4: confirm the week.
            if model.phase == .confirmingConstraints {
                ConstraintConfirmCard(
                    profile: Binding(get: { model.constraintDraft },
                                     set: { model.constraintDraft = $0 }),
                    weeklyLoad: model.combinedWeeklyMinutes,
                    onConfirm: { Task { await model.confirmConstraints() } })
                    .transition(.fadeUp)
            }

            // Stage 5: the editable plan(s).
            if model.phase == .reviewingProposal || model.phase == .creating {
                VStack(spacing: Metric.s4) {
                    if model.editablePlans.count > 1 {
                        Text("Here's the plan for each — tweak anything, then I'll set them up.")
                            .font(AppFont.subhead).foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.editablePlans, id: \.goal.id) { plan in
                        PlanProposalCard(
                            plan: plan,
                            onEditTemplate: { model.updateTemplate(planID: plan.goal.id, $0) },
                            onRemoveTemplate: { model.removeTemplate(planID: plan.goal.id, $0) },
                            onAccept: { Task { await model.accept() } },
                            isWorking: model.phase == .creating)
                    }
                    Text("Nothing's locked in — you can adjust any of this later.")
                        .font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
                }
                .transition(.fadeUp)
            }
        }
        .animation(.gentle, value: model.messages.count)
        .animation(.gentle, value: model.phase)
        .animation(.gentle, value: model.currentChoices)

        if model.phase == .grounding || model.phase == .surfacing || model.phase == .concretizing {
            MessageComposer(text: $input, isSending: model.isAssistantTyping,
                            placeholder: composerPlaceholder(model.phase)) {
                let text = input; input = ""
                Task { await model.send(text) }
            }
        }
    }

    private func composerPlaceholder(_ phase: OnboardingViewModel.Phase) -> String {
        switch phase {
        case .grounding:    return "Tell me about your life…"
        case .surfacing:    return "What do you want to change?"
        case .concretizing: return "Type, or tap an option above…"
        default:            return "Message"
        }
    }
}

// MARK: - Progress rail

/// A thin, calm progress rail — pips, never a percentage, never red.
private struct StageRail: View {
    let phase: OnboardingViewModel.Phase

    private var index: Int {
        switch phase {
        case .grounding: return 0
        case .surfacing: return 1
        case .concretizing: return 2
        case .confirmingConstraints, .generatingPlan: return 3
        case .reviewingProposal, .creating, .finished: return 4
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? Palette.accent : Palette.hairline)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, Metric.s5)
        .padding(.bottom, Metric.s2)
        .animation(.gentle, value: index)
    }
}

// MARK: - GoalSet selection card

/// Stage 2: candidate goals tagged long/short-term; tap 1–3 to start now.
private struct GoalSetCard: View {
    let aspirations: [AspirationDraft]
    let selected: Set<String>
    let canStart: Bool
    var onToggle: (String) -> Void
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s3) {
            SectionLabel("Pick 1–3 to start now")
            VStack(spacing: Metric.s2) {
                ForEach(aspirations) { aspiration in
                    row(aspiration)
                }
            }
            Button(action: onStart) {
                Text(canStart ? "Start with these (\(selected.count))" : "Pick at least one")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canStart)
        }
        .padding(Metric.s4)
        .card()
    }

    @ViewBuilder
    private func row(_ aspiration: AspirationDraft) -> some View {
        let isOn = selected.contains(aspiration.id)
        Button { onToggle(aspiration.id) } label: {
            HStack(spacing: Metric.s3) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Palette.accent : Palette.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(aspiration.title.isEmpty ? aspiration.rawWish : aspiration.title)
                        .font(AppFont.body).foregroundStyle(Palette.textPrimary)
                    Text(aspiration.horizon == .longTerm ? "Long-term" : "Starting now")
                        .font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Constraint confirmation card

/// Stage 4: the week, surfaced for confirmation (so we never silently save
/// defaults). Minimal in v1 — full editing lives in Settings.
private struct ConstraintConfirmCard: View {
    @Binding var profile: ConstraintProfile
    let weeklyLoad: Int
    var onConfirm: () -> Void

    private var dailyMinutes: Binding<Double> {
        Binding(get: { Double(profile.maxDailyTaskMinutes) },
                set: { profile.maxDailyTaskMinutes = Int($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s3) {
            SectionLabel("Your week")
            Text("I'll schedule around your work and sleep, and keep each day light.")
                .font(AppFont.subhead).foregroundStyle(Palette.textSecondary)

            HStack {
                Text("Most you'd want in a day").font(AppFont.body).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(Format.duration(profile.maxDailyTaskMinutes))
                    .font(AppFont.body.monospacedDigit()).foregroundStyle(Palette.accent)
            }
            Slider(value: dailyMinutes, in: 30...180, step: 15).tint(Palette.accent)

            Text("Your goals add up to about \(Format.duration(weeklyLoad)) a week.")
                .font(AppFont.caption1).foregroundStyle(Palette.textTertiary)

            Button(action: onConfirm) { Text("Looks right — build my plan") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Metric.s4)
        .card()
    }
}

/// A reusable chat header: coach avatar + title + a calm presence line.
struct CoachHeader: View {
    let title: String
    let subtitle: String
    var online: Bool = true
    var body: some View {
        HStack(spacing: Metric.s3) {
            CoachAvatar(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AppFont.headline).foregroundStyle(Palette.textPrimary)
                if online {
                    HStack(spacing: 5) {
                        Circle().fill(Palette.positive).frame(width: 6, height: 6)
                        Text("Always on your side").font(AppFont.caption1).foregroundStyle(Palette.positiveText)
                    }
                } else {
                    Text(subtitle).font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Metric.s5)
        .padding(.vertical, Metric.s2)
    }
}

extension AnyTransition {
    /// The signature message entrance: fade + a small slide up.
    static var fadeUp: AnyTransition {
        .opacity.combined(with: .offset(y: 8))
    }
}
