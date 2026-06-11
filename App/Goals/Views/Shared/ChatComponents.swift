import SwiftUI
import GoalsCore

/// A single chat bubble. Assistant bubbles are warm-white with a hairline and a
/// small bottom-left "tail" corner; user bubbles are teal with a bottom-right
/// tail. Assistant messages may host a native artifact card below the text —
/// the plan's "hybrid chat" (docs/PLAN.md §2.1).
struct ChatBubble<Artifact: View>: View {
    let message: ChatMessage
    @ViewBuilder var artifact: () -> Artifact

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 44) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: Metric.s2) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(AppFont.body)
                        .foregroundStyle(isUser ? Palette.onAccent : Palette.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isUser ? Palette.accent : Palette.cardBackground, in: bubbleShape)
                        .overlay { if !isUser { bubbleShape.stroke(Palette.hairline, lineWidth: 0.5) } }
                }
                artifact()
            }
            if !isUser { Spacer(minLength: 44) }
        }
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: Radius.lg,
            bottomLeadingRadius: isUser ? Radius.lg : 6,
            bottomTrailingRadius: isUser ? 6 : Radius.lg,
            topTrailingRadius: Radius.lg,
            style: .continuous)
    }
}

extension ChatBubble where Artifact == EmptyView {
    init(message: ChatMessage) { self.init(message: message) { EmptyView() } }
}

/// The chat input row — a frosted glass bar with a pill field and a teal send
/// button that lifts to full colour only when there's something to send.
struct MessageComposer: View {
    @Binding var text: String
    var isSending: Bool
    var placeholder: String = "Message"
    var onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(AppFont.body)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Palette.bgWell, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.borderField, lineWidth: 1))

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Palette.accent : Palette.textPlaceholder, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.gentle, value: canSend)
        }
        .padding(.horizontal, Metric.s3)
        .padding(.vertical, Metric.s2)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Palette.hairline), alignment: .top)
    }
}

/// Auto-scrolls a chat list to the latest message / typing indicator.
struct ChatScrollView<Content: View>: View {
    let messageCount: Int
    let isTyping: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.s4) {
                    content()
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Metric.s4)
                .padding(.vertical, Metric.s4)
            }
            .onChange(of: messageCount) { _, _ in scroll(proxy) }
            .onChange(of: isTyping) { _, _ in scroll(proxy) }
            .onAppear { scroll(proxy, animated: false) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.gentle) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}
