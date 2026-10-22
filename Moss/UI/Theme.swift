import SwiftUI

/// Dark, high-contrast studio look: near-black canvas, glass panels with hairline borders, one bright
/// moss-lime accent for the primary action and live progress.
enum Theme {
    static let canvas = Color(red: 0.035, green: 0.043, blue: 0.039)
    static let panel = Color(red: 0.085, green: 0.098, blue: 0.090)
    static let raised = Color(red: 0.125, green: 0.141, blue: 0.131)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(red: 0.79, green: 0.95, blue: 0.36)        // moss lime
    static let accentDeep = Color(red: 0.36, green: 0.52, blue: 0.27)    // moss green
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textMuted = Color.white.opacity(0.36)
}

let mossAccent = Theme.accent

/// Glass panel used for every grouped surface.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 26
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
extension View {
    func glassPanel(radius: CGFloat = 26) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// Compact control chip: icon + short value, used for aspect, quality and settings.
struct ChipLabel: View {
    let icon: String
    let text: String
    var active = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(active ? Color.black : Theme.textPrimary)
        .padding(.horizontal, 12).frame(height: 36)
        .background(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.raised), in: Capsule())
        .overlay(Capsule().strokeBorder(active ? Color.clear : Theme.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// Primary action: lime capsule with a soft glow; becomes a dark stop button while running.
struct GlowButtonStyle: ButtonStyle {
    var running = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(running ? Theme.textPrimary : Color.black)
            .padding(.horizontal, 20).frame(height: 48)
            .background(running ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(Theme.accent), in: Capsule())
            .overlay(Capsule().strokeBorder(running ? Theme.hairline : Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: running ? .clear : Theme.accent.opacity(configuration.isPressed ? 0.25 : 0.45), radius: configuration.isPressed ? 8 : 18)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
