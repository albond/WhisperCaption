import SwiftUI

/// Single registry of every Settings category shown in the sidebar plus
/// the search keywords used to filter the sidebar live. Adding a new
/// section means: add a case here, give it a descriptor, and return the
/// view from `content`. No other place needs to change.

// MARK: - Sidebar groups

/// Logical buckets used by the sidebar to group rows under header text.
/// Order here is the order they appear in the sidebar.
nonisolated enum SettingsGroupID: String, CaseIterable, Identifiable, Sendable {
    case general
    case privacy
    case audio
    case system

    var id: String { rawValue }

    /// Sidebar group header.
    var title: String {
        switch self {
        case .general:      return "General"
        case .privacy:      return "Windows & Privacy"
        case .audio:        return "Audio"
        case .system:       return "System"
        }
    }
}

// MARK: - Category descriptor

/// Everything the sidebar needs to render a row + everything search
/// needs to match a query.
struct SettingsCategoryDescriptor: Hashable, Identifiable, Sendable {
    let id: SettingsCategoryID
    let title: String
    let subtitle: String
    let systemImage: String
    /// Tint applied to the rounded icon tile.
    let tint: SettingsTint
    let group: SettingsGroupID
    /// Lowercased substrings the search filter matches against.
    let keywords: [String]
}

// MARK: - Category enum

/// Every Settings page shown in the sidebar. The case order here is
/// the visual order inside each group — sidebar reads cases top-to-bottom.
nonisolated enum SettingsCategoryID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance
    case windows
    case ccHUD
    case privacy
    case hotkeys
    case speech
    case bubbles
    case translation
    case chatHistory
    case tipJar
    case about

    var id: String { rawValue }
}

// MARK: - Descriptors

extension SettingsCategoryID {
    var descriptor: SettingsCategoryDescriptor {
        switch self {
        case .appearance:
            return .init(
                id: .appearance,
                title: "Appearance",
                subtitle: "Theme, accent, chat colors, windows, display",
                systemImage: "paintbrush.fill",
                tint: .pink,
                group: .general,
                keywords: [
                    "appearance", "theme", "dark mode", "light mode",
                    "system", "accent", "color", "colour",
                    "bubble", "bubbles", "chat colors", "chat colours",
                    "display", "monitor", "screen", "target",
                    "dock", "dock icon", "presence", "menu bar",
                    "window", "windows", "reset", "positions",
                    "layout", "general",
                ]
            )

        case .windows:
            return .init(
                id: .windows,
                title: "Windows",
                subtitle: "Per-window opacity & on-top",
                systemImage: "macwindow.on.rectangle",
                tint: .cyan,
                group: .privacy,
                keywords: [
                    "windows", "opacity",
                    "always on top",
                    "main hud",
                    "settings hud", "fullscreen", "spaces",
                    "all spaces",
                ]
            )

        case .ccHUD:
            return .init(
                id: .ccHUD,
                title: "CC HUD",
                subtitle: "Caption strip — size, opacity, colours",
                systemImage: "captions.bubble.fill",
                tint: .green,
                group: .privacy,
                keywords: [
                    "cc", "cc hud", "captions", "subtitles", "strip",
                    "opacity", "colour", "color", "background",
                    "previous", "current", "translation",
                    "size", "width", "height", "bottom",
                    "preview", "always on top", "spaces",
                ]
            )

        case .privacy:
            return .init(
                id: .privacy,
                title: "Privacy",
                subtitle: "Microphone & screen capture",
                systemImage: "lock.shield.fill",
                tint: .blue,
                group: .privacy,
                keywords: [
                    "privacy", "microphone",
                    "screen capture", "hide", "invisible",
                ]
            )

        case .hotkeys:
            return .init(
                id: .hotkeys,
                title: "Hotkeys",
                subtitle: "Global shortcuts & screenshot target",
                systemImage: "command.square.fill",
                tint: .indigo,
                group: .privacy,
                keywords: [
                    "hotkey", "hotkeys", "shortcut", "shortcuts",
                    "screenshot", "target",
                ]
            )

        case .speech:
            return .init(
                id: .speech,
                title: "Speech Recognition",
                subtitle: "Whisper, Deepgram, ElevenLabs",
                systemImage: "waveform",
                tint: .orange,
                group: .audio,
                keywords: [
                    "speech", "recognition", "whisper",
                    "deepgram", "elevenlabs", "scribe", "stt", "transcription",
                    "vocabulary", "model",
                    "api key",
                ]
            )

        case .bubbles:
            return .init(
                id: .bubbles,
                title: "Bubbles",
                subtitle: "Bubble length, silence break, cutting strategy",
                systemImage: "bubble.left.and.text.bubble.right.fill",
                tint: .purple,
                group: .audio,
                keywords: [
                    "bubble", "bubbles", "length", "split", "splitter",
                    "size", "characters", "sentence", "silence",
                    "break", "cut", "cutting",
                ]
            )

        case .translation:
            return .init(
                id: .translation,
                title: "Translation",
                subtitle: "Auto-translate system-side captions in CC HUD",
                systemImage: "character.bubble.fill",
                tint: .yellow,
                group: .audio,
                keywords: [
                    "translation", "translate",
                    "auto-translate", "subtitles", "cc",
                    "apple translation", "on-device",
                ]
            )

        case .chatHistory:
            return .init(
                id: .chatHistory,
                title: "Chat History",
                subtitle: "Browse and delete saved sessions",
                systemImage: "bubble.left.and.bubble.right.fill",
                tint: .mint,
                group: .system,
                keywords: [
                    "chat", "chats", "history",
                    "session", "sessions", "transcript",
                    "archive", "delete chat",
                ]
            )

        case .tipJar:
            return .init(
                id: .tipJar,
                title: "Tip Jar",
                subtitle: "Buy the author a coffee in crypto",
                systemImage: "cup.and.saucer.fill",
                tint: .orange,
                group: .system,
                keywords: [
                    "tip", "tip jar", "tipjar",
                    "donate", "donation", "donations",
                    "coffee", "support", "thanks",
                    "crypto", "stablecoin", "stablecoins",
                    "usdc", "usdt", "eurc",
                    "ethereum", "erc20", "erc-20",
                ]
            )

        case .about:
            return .init(
                id: .about,
                title: "About",
                subtitle: "Version, bundle, contact, links",
                systemImage: "info.circle.fill",
                tint: .gray,
                group: .system,
                keywords: [
                    "about", "version", "bundle",
                    "github", "license",
                ]
            )
        }
    }

    /// The actual view rendered in the detail pane.
    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .appearance:    AppearanceSection()
        case .windows:       WindowsSection()
        case .ccHUD:         CCHUDSection()
        case .privacy:       PrivacySection()
        case .hotkeys:       HotkeysSection()
        case .speech:        SpeechRecognitionSection()
        case .bubbles:       BubblesSection()
        case .translation:   TranslationSection()
        case .chatHistory:   ChatHistorySection()
        case .tipJar:        TipJarSection()
        case .about:         AboutSection()
        }
    }

    /// First category in the registry — used as the initial selection
    /// when the Settings window opens.
    static var defaultSelection: SettingsCategoryID { .appearance }
}

// MARK: - Tint palette

/// Curated tint set used for the rounded icon tiles in the sidebar. We
/// keep these as named cases (not raw Colors) so the same hue stays
/// consistent across light/dark mode and we can swap the palette in one
/// place if the design changes.
nonisolated enum SettingsTint: Hashable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, gray

    @MainActor
    var color: Color {
        switch self {
        case .red:      return .red
        case .orange:   return .orange
        case .yellow:   return .yellow
        case .green:    return .green
        case .mint:     return .mint
        case .teal:     return .teal
        case .cyan:     return .cyan
        case .blue:     return .blue
        case .indigo:   return .indigo
        case .purple:   return .purple
        case .pink:     return .pink
        case .gray:     return Color(nsColor: .systemGray)
        }
    }
}

// MARK: - Registry helpers

@MainActor
struct SettingsRegistry {
    static let groupedCategories: [(group: SettingsGroupID, items: [SettingsCategoryDescriptor])] = {
        SettingsGroupID.allCases.map { group in
            let items = SettingsCategoryID.allCases
                .map(\.descriptor)
                .filter { $0.group == group }
            return (group, items)
        }
        .filter { !$0.items.isEmpty }
    }()

    static let allDescriptors: [SettingsCategoryDescriptor] =
        SettingsCategoryID.allCases.map(\.descriptor)
}

// MARK: - Cross-section navigation

extension Notification.Name {
    /// Request the Settings window to switch its sidebar selection to a
    /// specific category. `object` carries the `SettingsCategoryID`. Used
    /// by deep-links from About → Tip Jar and from the menu-bar Tip Jar
    /// item. `SettingsView` observes this and updates its `selection`
    /// binding.
    static let selectSettingsCategory = Notification.Name("whispercaption.selectSettingsCategory")
}
