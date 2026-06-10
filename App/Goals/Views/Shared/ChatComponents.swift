import SwiftUI
import GoalsCore

/// A single chat bubble. Assistant messages may host a native artifact card
/// (the plan's "hybrid chat", docs/PLAN.md §2.1) rendered below the text.
struct ChatBubble<Artifact: View>: View {
    let message: ChatMessage
    @ViewBuilder var artifact: () -> Artifact

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(message.role == .user ? .white : .primary)
                }
                artifact()
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        message.role == .user ? Palette.accent : Palette.cardBackground
    }
}

extension ChatBubble where Artifact == EmptyView {
    init(message: ChatMessage) {
        self.init(message: message) { EmptyView() }
    }
}

/// The text input + send button used across onboarding and coach.
struct MessageComposer: View {
    @Binding var text: String
    var isSending: Bool
    var placeholder: String = "Message"
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.cardBackground, in: Capsule())
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Auto-scrolls a chat list to the latest message.
struct ChatScrollView<Content: View>: View {
    let messageCount: Int
    let isTyping: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: messageCount) { _, _ in scroll(proxy) }
            .onChange(of: isTyping) { _, _ in scroll(proxy) }
            .onAppear { scroll(proxy, animated: false) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}
