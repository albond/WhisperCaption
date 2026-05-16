import SwiftUI

/// Visual styling for `TipJarToken` — accent gradient and glyph used in
/// the token cards, amount input, and address pill.
///
/// The colours are hand-picked to feel close to each stablecoin's familiar
/// hue (blue for the dollar coins, indigo for the euro coin) without
/// pretending to be official brand assets — we don't ship issuer logos
/// or trademarked palettes.
extension TipJarToken {

    /// Primary accent — the "filled" tone in gradients and selection
    /// state. Calibrated for the macOS material system: visible on both
    /// light and dark cards without going neon.
    var primaryColor: Color {
        switch self {
        case .usdc: return Color(red: 0.16, green: 0.46, blue: 0.86)
        case .usdt: return Color(red: 0.16, green: 0.62, blue: 0.50)
        case .eurc: return Color(red: 0.34, green: 0.36, blue: 0.80)
        }
    }

    /// Lighter sibling used for the highlight stop in token-card gradients.
    var secondaryColor: Color {
        switch self {
        case .usdc: return Color(red: 0.32, green: 0.66, blue: 0.96)
        case .usdt: return Color(red: 0.28, green: 0.78, blue: 0.62)
        case .eurc: return Color(red: 0.52, green: 0.54, blue: 0.92)
        }
    }

    /// Gradient used for the token card's selected fill and the round
    /// glyph chip. Top-leading → bottom-trailing keeps it consistent
    /// across components.
    var gradient: LinearGradient {
        LinearGradient(
            colors: [secondaryColor, primaryColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
