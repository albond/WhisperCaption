import SwiftUI

/// Per-source bubble color in the Main HUD chat. Distinct from
/// `AccentChoice` because the semantics differ:
///   - `.accent` means "follow whichever accent the user picked in
///     Appearance" — implemented as `Color.accentColor`, which SwiftUI
///     resolves to the app-wide `.tint(...)` applied at scene root.
///   - Concrete cases (`.blue`, `.purple`, …) lock the bubble to a fixed
///     hue regardless of the accent.
///
/// The two SettingsStore fields are independent — pick `.accent` for both
/// to get a single-color chat, or different concrete colors to keep the
/// mic / system sides visually distinct.
nonisolated enum BubbleColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case accent
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case graphite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accent:   return "Match accent"
        case .blue:     return "Blue"
        case .purple:   return "Purple"
        case .pink:     return "Pink"
        case .red:      return "Red"
        case .orange:   return "Orange"
        case .yellow:   return "Yellow"
        case .green:    return "Green"
        case .mint:     return "Mint"
        case .teal:     return "Teal"
        case .graphite: return "Graphite"
        }
    }

    /// Color used to tint the bubble. `.accent` returns `Color.accentColor`,
    /// which inherits the app-wide tint applied to the Main HUD scene.
    @MainActor
    var color: Color {
        switch self {
        case .accent:   return Color.accentColor
        case .blue:     return .blue
        case .purple:   return .purple
        case .pink:     return .pink
        case .red:      return .red
        case .orange:   return .orange
        case .yellow:   return .yellow
        case .green:    return .green
        case .mint:     return .mint
        case .teal:     return .teal
        case .graphite: return Color(nsColor: .systemGray)
        }
    }

    /// Solid swatch shown in the picker grid.
    @MainActor
    var swatchColor: Color { color }
}
