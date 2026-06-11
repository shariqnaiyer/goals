import SwiftUI

/// The warm open (docs/PLAN.md §2.1 step 1): brand mark, one calm promise, one
/// clear action, and the local-first reassurance. No account wall.
struct WelcomeView: View {
    var onBegin: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: Metric.s5) {
                BrandMark(size: 80)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .opacity(appeared ? 1 : 0)

                Text("A quiet place\nfor what matters")
                    .font(AppFont.title1)
                    .tracking(0.2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textPrimary)

                Text("Tell me one thing you've been meaning to do. I'll turn it into a plan that bends with your week — no streaks, no shame.")
                    .font(AppFont.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: 300)
                    .lineSpacing(3)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            Spacer()

            VStack(spacing: Metric.s4) {
                Button("Let's begin", action: onBegin)
                    .buttonStyle(PrimaryButtonStyle())
                Text("No account needed. Everything stays on your phone.")
                    .font(AppFont.caption1)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Metric.s6)
            .padding(.bottom, Metric.s7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgApp.ignoresSafeArea())
        .onAppear { withAnimation(.gentle.delay(0.05)) { appeared = true } }
    }
}
