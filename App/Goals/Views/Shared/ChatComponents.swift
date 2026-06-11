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
                    // The coach speaks markdown (bold, bullets); the user's own
                    // words are rendered literally so a typed "*" stays a "*".
                    Group {
                        if isUser {
                            Text(message.text)
                        } else {
                            MessageMarkdown(text: message.text)
                        }
                    }
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

// MARK: - Markdown rendering

/// Renders the lightweight markdown the coach actually emits: paragraphs,
/// bullet (•/-/*) and numbered lists with hanging indents, ###-style headings,
/// and inline bold/italic/code. SwiftUI's bare `Text` markdown support is
/// inline-only and chokes on lists/multi-paragraph text, so blocks are split
/// here and inline spans handed to `AttributedString`. Anything unparseable
/// falls back to literal text — a rendering bug must never eat words.
struct MessageMarkdown: View {
    let text: String

    var body: some View {
        let blocks = Self.blocks(from: text)
        VStack(alignment: .leading, spacing: Metric.s2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let lines):
            Text(Self.inline(lines.joined(separator: "\n")))
        case .heading(let line):
            Text(Self.inline(line))
                .font(AppFont.headline)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: Metric.s1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Metric.s2) {
                        Text("•").foregroundStyle(Palette.accent)
                        Text(Self.inline(item))
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: Metric.s1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Metric.s2) {
                        Text("\(item.number).")
                            .foregroundStyle(Palette.accent)
                            .monospacedDigit()
                        Text(Self.inline(item.text))
                    }
                }
            }
        }
    }

    // MARK: Parsing

    enum Block: Equatable {
        case paragraph([String])
        case heading(String)
        case bullets([String])
        case numbered([(number: Int, text: String)])

        static func == (lhs: Block, rhs: Block) -> Bool {
            switch (lhs, rhs) {
            case let (.paragraph(a), .paragraph(b)): return a == b
            case let (.heading(a), .heading(b)): return a == b
            case let (.bullets(a), .bullets(b)): return a == b
            case let (.numbered(a), .numbered(b)):
                return a.map(\.number) == b.map(\.number) && a.map(\.text) == b.map(\.text)
            default: return false
            }
        }
    }

    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [(number: Int, text: String)] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)); paragraph = [] }
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph(); flushLists()
            } else if let item = bulletItem(line) {
                flushParagraph()
                if !numbered.isEmpty { flushLists() }
                bullets.append(item)
            } else if let item = numberedItem(line) {
                flushParagraph()
                if !bullets.isEmpty { flushLists() }
                numbered.append(item)
            } else if let title = headingItem(line) {
                flushParagraph(); flushLists()
                blocks.append(.heading(title))
            } else {
                flushLists()
                paragraph.append(line)
            }
        }
        flushParagraph(); flushLists()
        return blocks
    }

    /// "• item", "- item", "* item" (but not "**bold…" emphasis openers).
    private static func bulletItem(_ line: String) -> String? {
        for marker in ["• ", "- ", "* "] where line.hasPrefix(marker) {
            if marker == "* " && line.hasPrefix("**") { continue }
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// "1. item" / "2) item".
    private static func numberedItem(_ line: String) -> (number: Int, text: String)? {
        guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }),
              let number = Int(line[line.startIndex..<separator]),
              line.index(after: separator) < line.endIndex else { return nil }
        let rest = line[line.index(after: separator)...]
        guard rest.hasPrefix(" ") else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }

    /// "# Title" … "#### Title" — rendered as a bold line, never huge type.
    private static func headingItem(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let stripped = line.drop(while: { $0 == "#" })
        guard stripped.hasPrefix(" ") else { return nil }
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    /// Inline spans (bold/italic/code) via Foundation's markdown parser,
    /// preserving in-paragraph newlines. Falls back to the literal string.
    static func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }
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
