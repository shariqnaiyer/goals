import SwiftUI

/// Lightweight design tokens for a calm, friendly, "forgiveness-first" feel
/// (docs/PLAN.md §1). Intentionally minimal — semantic colors and a couple of
/// reusable modifiers rather than a heavy theming framework.
enum Palette {
    static let accent = Color.accentColor
    static let positive = Color.green
    static let gentle = Color.orange          // used for "missed", never red/shaming
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let screenBackground = Color(.systemGroupedBackground)
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// An animated "assistant is typing" indicator for chat surfaces.
struct TypingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 7, height: 7)
                    .opacity(0.4 + 0.6 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .foregroundStyle(.secondary)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
        .accessibilityLabel("Coach is typing")
    }
}
