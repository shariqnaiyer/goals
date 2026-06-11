import SwiftUI
import GoalsCore

// Reusable controls in the Goals visual language. Press = a tactile scale to
// 0.97; one clear primary action per screen carries a soft teal glow.

enum GButtonSize {
    case small, medium, large
    var height: CGFloat { switch self { case .small: 34; case .medium: 44; case .large: 52 } }
    var font: Font { self == .small ? AppFont.subhead.weight(.semibold) : AppFont.headline }
    var radius: CGFloat { switch self { case .small: Radius.sm; case .medium: Radius.md; case .large: Radius.lg } }
    var hPad: CGFloat { switch self { case .small: 14; case .medium: 20; case .large: 24 } }
}

/// Primary call-to-action: teal fill, white ink, soft accent glow.
struct PrimaryButtonStyle: ButtonStyle {
    var size: GButtonSize = .large
    var block: Bool = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: block ? .infinity : nil)
            .frame(height: size.height)
            .padding(.horizontal, size.hPad)
            .background(configuration.isPressed ? Palette.accentPress : Palette.accent,
                        in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .shadow(color: Palette.accent.opacity(enabled ? 0.22 : 0), radius: 12, x: 0, y: 4)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.gentle, value: configuration.isPressed)
    }
}

/// Soft secondary action: tinted teal fill, no glow.
struct SecondaryButtonStyle: ButtonStyle {
    var size: GButtonSize = .medium
    var block: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Palette.accentOnSoft)
            .frame(maxWidth: block ? .infinity : nil)
            .frame(height: size.height)
            .padding(.horizontal, size.hPad)
            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.gentle, value: configuration.isPressed)
    }
}

/// Quiet neutral action (e.g. "Not now").
struct PlainFillButtonStyle: ButtonStyle {
    var size: GButtonSize = .medium
    var block: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: block ? .infinity : nil)
            .frame(height: size.height)
            .padding(.horizontal, size.hPad)
            .background(Palette.bgWell, in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.gentle, value: configuration.isPressed)
    }
}

/// Generic press-to-scale for tappable cards and rows.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.gentle, value: configuration.isPressed)
    }
}

/// The circular completion control — a ring that fills sage with a spring on tap.
/// Completing a task should feel like a small, earned moment.
struct TaskCheck: View {
    let isDone: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isDone ? Palette.positive : Palette.textPlaceholder, lineWidth: 2)
                    .frame(width: 24, height: 24)
                if isDone {
                    Circle().fill(Palette.positive).frame(width: 24, height: 24)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.springy, value: isDone)
        .accessibilityLabel(isDone ? "Completed" : "Mark complete")
    }
}

/// A calm capsule progress bar. Tone reflects meaning, never alarm.
struct GProgressBar: View {
    enum Tone { case accent, success, gentle
        var color: Color {
            switch self { case .accent: Palette.accent; case .success: Palette.positive; case .gentle: Palette.gentle }
        }
    }
    var value: Double
    var tone: Tone = .accent
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(tone.color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.gentle, value: value)
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Goal status pill — sage active, amber paused, teal done, muted archived.
struct StatusBadge: View {
    let status: GoalStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(fg).frame(width: 6, height: 6)
            Text(label).font(AppFont.caption1.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(bg, in: Capsule())
        .foregroundStyle(fg)
    }
    private var label: String {
        switch status { case .active: "Active"; case .paused: "Paused"; case .completed: "Done"; case .abandoned: "Archived" }
    }
    private var fg: Color {
        switch status {
        case .active: Palette.positiveText
        case .paused: Palette.gentleText
        case .completed: Palette.accentOnSoft
        case .abandoned: Palette.textSecondary
        }
    }
    private var bg: Color {
        switch status {
        case .active: Palette.positiveSoft
        case .paused: Palette.gentleSoft
        case .completed: Palette.accentSoft
        case .abandoned: Palette.bgWell
        }
    }
}

/// A circular icon button used in nav bars (calm, 44pt target).
struct CircleIconButton: View {
    let systemName: String
    var tint: Color = Palette.textSecondary
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Palette.bgWell.opacity(0.0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
