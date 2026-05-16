import SwiftUI

/// User-selectable appearance for the app's UI. `.system` follows the
/// macOS Light/Dark setting; `.light` and `.dark` force a single scheme
/// regardless of system state. Wired into the Settings scene root (and
/// the main WindowGroup) via `.preferredColorScheme(...)`.
nonisolated enum AppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Match system"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    /// Returned to SwiftUI's `.preferredColorScheme(...)`. `nil` means
    /// "don't override — follow the system". `.light` / `.dark` lock the
    /// scene regardless of the macOS Appearance setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
