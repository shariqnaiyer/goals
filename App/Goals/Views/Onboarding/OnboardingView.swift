import SwiftUI
import GoalsCore

/// The onboarding conversation (docs/PLAN.md §2.1): warm, low-friction, no
/// account, ending in an editable plan proposal the user confirms.
struct OnboardingView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: OnboardingViewModel?
    @State private var input = ""
    var onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .background(Palette.screenBackground)
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
        ChatScrollView(messageCount: model.messages.count, isTyping: model.isAssistantTyping) {
            ForEach(model.messages) { message in
                ChatBubble(message: message)
            }
            if model.phase == .generatingPlan {
                Text("Sketching a plan…").font(.subheadline).foregroundStyle(.secondary)
            }
            if model.phase == .reviewingProposal, let plan = model.editablePlan {
                PlanProposalCard(
                    plan: plan,
                    onEditTemplate: { model.updateTemplate($0) },
                    onRemoveTemplate: { model.removeTemplate($0) },
                    onAccept: { Task { await model.accept() } },
                    isWorking: model.phase == .creating)
            }
            if model.isAssistantTyping { TypingIndicator() }
        }

        if model.phase == .interviewing {
            MessageComposer(text: $input, isSending: model.isAssistantTyping,
                            placeholder: "Tell me what you're hoping to do…") {
                let text = input; input = ""
                Task { await model.send(text) }
            }
        }
    }
}
