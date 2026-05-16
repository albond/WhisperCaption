import SwiftUI

/// Curated set of accent colors offered to the user in
/// Settings → Appearance. `.system` leaves the macOS-wide accent intact;
/// every other case forces SwiftUI's `.tint(...)` to a specific hue.
nonisolated enum AccentChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
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
        case .system:   return "System"
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

    /// `nil` means "follow the macOS accent". Every other case returns a
    /// concrete SwiftUI Color suitable for `.tint(_:)`.
    @MainActor
    var color: Color? {
        switch self {
        case .system:   return nil
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

    /// Solid swatch color used in the picker grid — `.system` falls back
    /// to a neutral so the swatch is still visible.
    @MainActor
    var swatchColor: Color {
        if let c = color { return c }
        return Color.accentColor
    }
}
