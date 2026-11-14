import SwiftUI

/// Colours and the glass look shared by every screen: a soft coloured backdrop, translucent cards that let it
/// through, and Liquid Glass (iOS 26 and later) on the main cards and buttons.
enum Theme {
    /// Bright mint on dark, deeper teal on light so text in the accent colour stays readable.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.27, green: 0.90, blue: 0.78, alpha: 1)
            : UIColor(red: 0.00, green: 0.50, blue: 0.48, alpha: 1)
    })
    /// Inset areas inside a card (text fields, exercise figures).
    static let background = Color.primary.opacity(0.07)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

/// The backdrop behind every screen: glass needs colour behind it to show.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            dark ? Color(red: 0.03, green: 0.05, blue: 0.09) : Color(red: 0.93, green: 0.96, blue: 0.98)
            RadialGradient(colors: [Theme.accent.opacity(dark ? 0.34 : 0.26), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.indigo.opacity(dark ? 0.42 : 0.20), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color.cyan.opacity(dark ? 0.20 : 0.14), .clear], center: .trailing, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// A translucent card with a light edge. `hero` cards (one or two per screen) use real Liquid Glass where
    /// the system has it; the others use a material, which stays light to draw in long lists.
    @ViewBuilder func glassCard(_ radius: CGFloat = 18, hero: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *), hero {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        }
    }

    /// The main action of a card.
    @ViewBuilder func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.borderedProminent) }
    }

    /// A secondary action.
    @ViewBuilder func glassButton() -> some View {
        if #available(iOS 26.0, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
    }
}
