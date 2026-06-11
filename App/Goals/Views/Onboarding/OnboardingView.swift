import SwiftUI
import GoalsCore

/// The onboarding conversation (docs/PLAN.md §2.1): warm, low-friction, ending
/// in an editable plan proposal the user confirms. A coach-avatar header frames
/// the chat; messages fade up; the proposal arrives as a native card.
struct OnboardingView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: OnboardingViewModel?
    @State private var input = ""
    var onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CoachHeader(title: "Your coach", subtitle: "Setting up your first goal", online: false)
            if let model { content(model) } else { ProgressView().frame(maxHeight: .infinity) }
        }
        .background(Palette.bgApp.ignoresSafeArea())
        .onAppear {
            if model == nil {
                let m = OnboardingViewModel(app: app)
                m.start()
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
            if model.phase == .generatingPlan {
                HStack(spacing: Metric.s2) {
                    TypingIndicator()
                    Text("Sketching a plan…").font(AppFont.subhead).foregroundStyle(Palette.textTertiary)
                }
            } else if model.isAssistantTyping {
                TypingIndicator()
            }
            if model.phase == .reviewingProposal || model.phase == .creating, let plan = model.editablePlan {
                VStack(spacing: Metric.s3) {
                    PlanProposalCard(
                        plan: plan,
                        onEditTemplate: { model.updateTemplate($0) },
                        onRemoveTemplate: { model.removeTemplate($0) },
                        onAccept: { Task { await model.accept() } },
                        isWorking: model.phase == .creating)
                    Text("Tweak anything now or later — nothing's locked in.")
                        .font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
                }
                .transition(.fadeUp)
            }
        }
        .animation(.gentle, value: model.messages.count)
        .animation(.gentle, value: model.phase)

        if model.phase == .interviewing {
            MessageComposer(text: $input, isSending: model.isAssistantTyping,
                            placeholder: "Tell me what you're hoping to do…") {
                let text = input; input = ""
                Task { await model.send(text) }
            }
        }
    }
}

/// A reusable chat header: coach avatar + title + a calm "always on your side"
/// presence line.
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
