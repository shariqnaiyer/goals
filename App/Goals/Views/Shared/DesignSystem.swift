import SwiftUI

// Goals design system — the warm-paper, pine-teal visual language.
// "A quiet companion, not a productivity dashboard." Warm cream page,
// warm-white cards, ink (never pure black), one calm teal accent, and status
// colours that never shout — sage for done, amber for missed (never red),
// terracotta reserved for destructive erase. Mirrors the design tokens in the
// brand kit (tokens/colors.css, typography.css, spacing.css).

// MARK: - Colour primitives

extension Color {
    /// Build an sRGB colour from a 0xRRGGBB hex.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// A colour that resolves differently in light vs. dark appearance.
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

/// Semantic colour roles. Reference these in views — never raw hex.
/// Warm paper neutrals + pine-teal accent + calm status colours.
enum Palette {
    // Backgrounds
    static let bgApp        = Color(light: 0xFCFAF5, dark: 0x1A1714) // warm cream page
    static let bgGrouped    = Color(light: 0xF7F2E9, dark: 0x211D19) // grouped/inset background
    static let bgWell       = Color(light: 0xF0E9DC, dark: 0x2C2723) // input fields, tracks
    static let bgChip       = Color(light: 0xF7F2E9, dark: 0x262220)
    static let cardBackground = Color(light: 0xFFFEFB, dark: 0x262220) // warm-white card

    // Ink (warm near-black, never #000)
    static let textPrimary   = Color(light: 0x262320, dark: 0xF2ECE1)
    static let textSecondary = Color(light: 0x6F6658, dark: 0xB3A899)
    static let textTertiary  = Color(light: 0x968C7C, dark: 0x8A8073)
    static let textPlaceholder = Color(light: 0xB8AE9D, dark: 0x6F665A)

    // Lines
    static let hairline       = Color(light: 0xECE4D6, dark: 0x322D27)
    static let hairlineStrong = Color(light: 0xDDD2BF, dark: 0x3A342D)
    static let borderField    = Color(light: 0xE3D9C8, dark: 0x38322B)
    static let track          = Color(light: 0xE9E1D1, dark: 0x2E2925) // progress track, toggle off

    // Accent — pine teal (the one expressive colour)
    static let accent        = Color(light: 0x3B7A6B, dark: 0x6AA896)
    static let accentPress   = Color(light: 0x336A5D, dark: 0x7FB4A5)
    static let accentSoft    = Color(light: 0xECF3F0, dark: 0x23302B)
    static let accentSoftBorder = Color(light: 0xD2E5DD, dark: 0x2F4942)
    static let accentOnSoft  = Color(light: 0x2A574C, dark: 0xA9CDC1)
    static let onAccent      = Color(light: 0xFFFFFF, dark: 0x15201C)

    // Status — calm by design
    static let positive     = Color(light: 0x5F9A6E, dark: 0x74AD82) // "done" that doesn't shout
    static let positiveSoft = Color(light: 0xE3EFE4, dark: 0x233028)
    static let positiveText = Color(light: 0x4F8460, dark: 0x74AD82)
    static let gentle       = Color(light: 0xC98B3C, dark: 0xD6A85A) // missed / snoozed — kindness
    static let gentleSoft   = Color(light: 0xF6E9D2, dark: 0x332A1C)
    static let gentleText   = Color(light: 0xAD7430, dark: 0xD6A85A)
    static let danger       = Color(light: 0xC0563F, dark: 0xD2705A) // erase only
    static let dangerSoft   = Color(light: 0xF3DDD5, dark: 0x33211C)

    // Legacy aliases kept for older call sites.
    static var screenBackground: Color { bgApp }
}

// MARK: - Spacing, radii, motion

enum Metric {
    // 8pt rhythm with 4pt half-steps.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16   // default card padding / gutter
    static let s5: CGFloat = 20   // screen margin
    static let s6: CGFloat = 24
    static let s7: CGFloat = 32
    static let s8: CGFloat = 40

    static let screenMargin: CGFloat = 20
    static let touchMin: CGFloat = 44
}

enum Radius {
    static let sm: CGFloat = 10   // chips, small controls
    static let md: CGFloat = 14   // buttons, fields
    static let lg: CGFloat = 18   // cards, chat bubbles
    static let xl: CGFloat = 22   // sheets
    static let xxl: CGFloat = 28  // modal sheets, hero cards
}

extension Animation {
    /// Standard iOS decelerate — for most transitions.
    static let gentle = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)
    /// A soft spring — cards, the completion check. Use sparingly.
    static let springy = Animation.spring(response: 0.34, dampingFraction: 0.72)
}

// MARK: - Typography (iOS HIG ramp, SF Pro via the system font)

enum AppFont {
    static let largeTitle = Font.system(size: 34, weight: .bold)
    static let title1     = Font.system(size: 28, weight: .bold)
    static let title2     = Font.system(size: 22, weight: .bold)
    static let title3     = Font.system(size: 20, weight: .semibold)
    static let headline   = Font.system(size: 17, weight: .semibold)
    static let body       = Font.system(size: 17, weight: .regular)
    static let callout    = Font.system(size: 16, weight: .regular)
    static let subhead    = Font.system(size: 15, weight: .regular)
    static let footnote   = Font.system(size: 13, weight: .regular)
    static let caption1   = Font.system(size: 12, weight: .regular)
    static let overline   = Font.system(size: 13, weight: .semibold)
}

/// An uppercase, tracked section label (TODAY, MILESTONES) — the one place the
/// app uses uppercase, per the brand voice.
struct SectionLabel: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ text: String, trailing: AnyView? = nil) {
        self.text = text
        self.trailing = trailing
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(AppFont.overline)
                .tracking(0.6)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            trailing
        }
        .padding(.horizontal, Metric.s6)
        .padding(.top, Metric.s5)
        .padding(.bottom, Metric.s2)
    }
}

// MARK: - Surfaces

/// The signature warm-white card: 18px radius, hairline border, whisper shadow.
struct CardSurface: ViewModifier {
    var padding: CGFloat = Metric.s4
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )
            .shadow(color: Color(hex: 0x362E24).opacity(0.05), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = Metric.s4) -> some View { modifier(CardSurface(padding: padding)) }

    /// Warm-paper screen background that replaces the default grouped colour.
    func screenBackground() -> some View {
        scrollContentBackground(.hidden).background(Palette.bgApp.ignoresSafeArea())
    }
}

// MARK: - Brand mark

/// The concentric-ring "target" brand mark, drawn natively.
struct BrandMark: View {
    var size: CGFloat = 76
    var color: Color = Palette.accent
    var body: some View {
        ZStack {
            Circle().strokeBorder(color.opacity(0.28), lineWidth: size * 0.066)
                .frame(width: size, height: size)
            Circle().strokeBorder(color.opacity(0.55), lineWidth: size * 0.066)
                .frame(width: size * 0.6, height: size * 0.6)
            Circle().fill(color)
                .frame(width: size * 0.24, height: size * 0.24)
        }
        .accessibilityHidden(true)
    }
}

/// The coach's avatar — a filled teal disc carrying the brand mark.
struct CoachAvatar: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            Circle().fill(Palette.accent)
            BrandMark(size: size * 0.62, color: Palette.onAccent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Typing indicator (the only persistent animation)

struct TypingIndicator: View {
    @State private var t = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Palette.textPlaceholder)
                    .frame(width: 8, height: 8)
                    .opacity(0.3 + 0.7 * max(0, sin(t - Double(i) * 0.6)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Palette.cardBackground,
                    in: UnevenRoundedRectangle(topLeadingRadius: Radius.lg, bottomLeadingRadius: 6,
                                               bottomTrailingRadius: Radius.lg, topTrailingRadius: Radius.lg,
                                               style: .continuous))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: Radius.lg, bottomLeadingRadius: 6,
                                   bottomTrailingRadius: Radius.lg, topTrailingRadius: Radius.lg,
                                   style: .continuous)
                .stroke(Palette.hairline, lineWidth: 0.5)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { t = .pi * 2 }
        }
        .accessibilityLabel("Coach is typing")
    }
}
