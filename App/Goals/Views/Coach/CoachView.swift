import SwiftUI
import GoalsCore

/// The Coach chat (docs/PLAN.md §2.2 tab 3). Works as the general thread (tab)
/// or scoped to a goal (pushed from goal detail). Coach-proposed diffs render as
/// interactive cards inline.
struct CoachView: View {
    @Environment(AppContainer.self) private var app
    let goalID: UUID?
    @State private var model: CoachViewModel?
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                ChatScrollView(messageCount: model.messages.count, isTyping: model.isAssistantTyping) {
                    ForEach(model.messages) { message in
                        messageView(model, message: message)
                    }
                    if model.isAssistantTyping { TypingIndicator() }
                }
                MessageComposer(text: $input, isSending: model.isAssistantTyping,
                                placeholder: "Tell the coach anything…") {
                    let text = input; input = ""
                    Task { await model.send(text) }
                }
            } else { ProgressView() }
        }
        .navigationTitle(goalID == nil ? "Coach" : "Coach")
        .navigationBarTitleDisplayMode(.inline)
        .background(Palette.screenBackground)
        .onAppear {
            if model == nil { model = CoachViewModel(app: app, goalID: goalID) }
            model?.load()
        }
    }

    @ViewBuilder
    private func messageView(_ model: CoachViewModel, message: ChatMessage) -> some View {
        ChatBubble(message: message) {
            if case let .planDiff(diff) = message.artifact {
                PlanDiffCard(
                    diff: diff,
                    onAccept: diff.isQuestionOnly ? nil : { model.applyDiff(diff) },
                    onDismiss: diff.isQuestionOnly ? nil : { model.dismissDiff(diff) },
                    onChoose: diff.isQuestionOnly ? { Task { await model.send($0) } } : nil)
            }
        }
    }
}
