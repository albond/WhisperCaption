import AppKit
import Foundation
import Observation
import SwiftUI

/// Persists user preferences. Three storage backends are used:
///   - UserDefaults for boolean flags + non-secret strings
///   - Keychain    for API-key secrets (Deepgram, ElevenLabs)
///   - This store is `@Observable`, so SwiftUI views and our defenders
///     (WindowSharingDefender, DisplayPinningController) react to changes.

/// Which speech-to-text backend the user picked. Stored as a raw string
/// in UserDefaults so we can add new backends later without breaking
/// existing installs (an unknown value falls back to `.whisper`).
nonisolated enum TranscriptionEngineKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case whisper
    case deepgram
    case elevenlabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:    return "Local — WhisperKit"
        case .deepgram:   return "Cloud — Deepgram Nova-3"
        case .elevenlabs: return "Cloud — ElevenLabs Scribe v2"
        }
    }
}

/// Where the app surfaces in the system. The menu-bar status item is
/// non-negotiable — it's always mounted so the user can always reach
/// the app even when no windows are visible. The Dock icon is the only
/// variable: `.menuBar` hides it, `.both` shows it.
nonisolated enum AppPresenceMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Menu-bar icon only — no Dock icon, no Cmd-Tab entry. Default.
    case menuBar = "menu_bar"
    /// Both — Dock icon AND menu-bar entry.
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .menuBar: return "Menu Bar only"
        case .both:    return "Dock and Menu Bar"
        }
    }

    /// Activation policy that matches the chosen presence: `.accessory`
    /// hides the Dock icon (and Cmd-Tab entry); `.regular` keeps it.
    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .menuBar: return .accessory
        case .both:    return .regular
        }
    }

    /// Menu-bar item is always shown — kept for call-site clarity even
    /// though it's now a constant.
    var showsMenuBarItem: Bool { true }
}

@Observable
@MainActor
final class SettingsStore {

    // MARK: - Privacy

    /// When true (default), every app NSWindow has its `sharingType`
    /// set to `.none`, which makes the window completely invisible to ANY
    /// screen-capture tool: Zoom / Teams / Webex screen share, OBS,
    /// `screencapture` CLI, ScreenCaptureKit. The window doesn't render
    /// even as a black rectangle — it's filtered at the compositor level.
    var windowsHiddenFromCapture: Bool {
        didSet {
            UserDefaults.standard.set(windowsHiddenFromCapture, forKey: Keys.windowsHiddenFromCapture)
        }
    }

    // MARK: - Per-HUD window settings

    /// Per-HUD opacity, keyed by `HUDDescriptor.id`. Mutate via
    /// `setOpacity(_:for:)` so the new value clamps to the HUD's range
    /// AND persists to UserDefaults.
    private(set) var hudOpacity: [String: Double] = [:]

    /// Per-HUD "Always on top" toggle, keyed by `HUDDescriptor.id`.
    private(set) var hudAlwaysOnTop: [String: Bool] = [:]

    /// Per-HUD "Show on all Spaces" toggle, keyed by `HUDDescriptor.id`.
    /// Only meaningful for descriptors with `supportsShowOnAllSpaces == true`.
    private(set) var hudShowOnAllSpaces: [String: Bool] = [:]

    /// Opacity for the given HUD, with the descriptor's `defaultOpacity`
    /// as the fallback when no value has been persisted yet.
    func opacity(for hud: HUDDescriptor) -> Double {
        hudOpacity[hud.id] ?? hud.defaultOpacity
    }

    /// Clamped + persisted setter.
    func setOpacity(_ value: Double, for hud: HUDDescriptor) {
        let clamped = min(max(value, hud.opacityRange.lowerBound),
                          hud.opacityRange.upperBound)
        hudOpacity[hud.id] = clamped
        UserDefaults.standard.set(clamped, forKey: hud.opacityKey)
    }

    func alwaysOnTop(for hud: HUDDescriptor) -> Bool {
        hudAlwaysOnTop[hud.id] ?? hud.defaultAlwaysOnTop
    }

    func setAlwaysOnTop(_ value: Bool, for hud: HUDDescriptor) {
        hudAlwaysOnTop[hud.id] = value
        UserDefaults.standard.set(value, forKey: hud.alwaysOnTopKey)
    }

    func showOnAllSpaces(for hud: HUDDescriptor) -> Bool {
        guard hud.supportsShowOnAllSpaces else { return false }
        return hudShowOnAllSpaces[hud.id] ?? hud.defaultShowOnAllSpaces
    }

    func setShowOnAllSpaces(_ value: Bool, for hud: HUDDescriptor) {
        guard hud.supportsShowOnAllSpaces else { return }
        hudShowOnAllSpaces[hud.id] = value
        UserDefaults.standard.set(value, forKey: hud.showOnAllSpacesKey)
    }

    func opacityBinding(for hud: HUDDescriptor) -> Binding<Double> {
        Binding(
            get: { self.opacity(for: hud) },
            set: { self.setOpacity($0, for: hud) }
        )
    }

    func alwaysOnTopBinding(for hud: HUDDescriptor) -> Binding<Bool> {
        Binding(
            get: { self.alwaysOnTop(for: hud) },
            set: { self.setAlwaysOnTop($0, for: hud) }
        )
    }

    func showOnAllSpacesBinding(for hud: HUDDescriptor) -> Binding<Bool> {
        Binding(
            get: { self.showOnAllSpaces(for: hud) },
            set: { self.setShowOnAllSpaces($0, for: hud) }
        )
    }

    // MARK: - Appearance

    var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
        }
    }

    var accentColor: AccentChoice {
        didSet {
            UserDefaults.standard.set(accentColor.rawValue, forKey: Keys.accentColor)
        }
    }

    /// Tint for the user's (microphone) side of the Main HUD chat. Defaults
    /// to `.accent` so the column follows whichever accent the user picks
    /// in Appearance.
    var micBubbleColor: BubbleColor {
        didSet {
            UserDefaults.standard.set(micBubbleColor.rawValue, forKey: Keys.micBubbleColor)
        }
    }

    /// Tint for the system-audio side of the Main HUD chat. Defaults to
    /// purple so the two columns stay visually distinct without any setup —
    /// users who want a single-color chat can flip this to `.accent` too.
    var systemBubbleColor: BubbleColor {
        didSet {
            UserDefaults.standard.set(systemBubbleColor.rawValue, forKey: Keys.systemBubbleColor)
        }
    }

    /// When false, the app never starts the microphone pipeline: no
    /// MicCapture, no second TranscriptionEngine, no mic column in the UI.
    /// Useful when only the other side of a call should be transcribed.
    var captureMicrophone: Bool {
        didSet {
            UserDefaults.standard.set(captureMicrophone, forKey: Keys.captureMicrophone)
        }
    }

    /// Whether the Main HUD's chat list auto-scrolls to the latest caption
    /// while a stream is running. Off lets the user freely scroll history
    /// without the next partial yanking the viewport back down.
    var autoScrollMainHUD: Bool {
        didSet {
            UserDefaults.standard.set(autoScrollMainHUD, forKey: Keys.autoScrollMainHUD)
        }
    }

    // MARK: - HUD visibility (restored on launch)
    //
    // Tracked live as the user shows/hides each HUD so the next launch
    // mirrors the previous session's layout. Defaults are conservative
    // (everything hidden) so a fresh install opens just the menu bar.

    /// Whether the Main HUD was visible when the user last toggled it.
    /// Updated on every show/dismiss; consulted at launch.
    var mainHUDVisible: Bool {
        didSet { UserDefaults.standard.set(mainHUDVisible, forKey: Keys.mainHUDVisible) }
    }

    /// Whether the CC HUD was visible when the user last toggled it.
    /// Updated on every show/dismiss; consulted at launch.
    var ccHUDVisible: Bool {
        didSet { UserDefaults.standard.set(ccHUDVisible, forKey: Keys.ccHUDVisible) }
    }

    // MARK: - Bubble formatting
    //
    // Post-process layer on the engine output: each engine emits captions
    // at its own pace (Whisper short, ElevenLabs huge), we normalise to a
    // single user-controlled shape.

    /// Maximum characters in one bubble. When an in-flight bubble grows past
    /// this, the splitter cuts it at the nearest sentence boundary (or word
    /// boundary if `bubbleSentenceAware` is off) and the tail continues in a
    /// fresh bubble.
    var bubbleMaxChars: Int {
        didSet { UserDefaults.standard.set(bubbleMaxChars, forKey: Keys.bubbleMaxChars) }
    }

    /// Seconds of inactivity before an in-flight bubble is forcibly finalised
    /// and the next caption starts a new bubble. Acts as a fallback when an
    /// engine doesn't emit a final fast enough (Whisper waiting on its
    /// internal silence detect, etc.).
    var bubbleSilenceBreakSec: Double {
        didSet { UserDefaults.standard.set(bubbleSilenceBreakSec, forKey: Keys.bubbleSilenceBreakSec) }
    }

    /// When true, the splitter prefers cutting at a sentence terminator
    /// (`.`, `?`, `!`, `…`) within the last ~30 chars of the max length.
    /// When false, it cuts at the last whitespace, falling back to a hard
    /// max-length cut.
    var bubbleSentenceAware: Bool {
        didSet { UserDefaults.standard.set(bubbleSentenceAware, forKey: Keys.bubbleSentenceAware) }
    }

    /// Font size (points) of the bubble's main caption text in the Main HUD.
    /// Translation row tracks 1pt below so the original/translation
    /// hierarchy stays preserved at any size.
    var bubbleFontSize: Double {
        didSet { UserDefaults.standard.set(bubbleFontSize, forKey: Keys.bubbleFontSize) }
    }

    static let defaultBubbleMaxChars: Int = 200
    static let defaultBubbleSilenceBreakSec: Double = 2.0
    static let defaultBubbleSentenceAware: Bool = true
    /// 13 pt — equivalent to SwiftUI's `.body` on macOS, the previous
    /// hard-coded value before this knob existed.
    static let defaultBubbleFontSize: Double = 13

    static let bubbleMaxCharsRange: ClosedRange<Int> = 60 ... 600
    static let bubbleSilenceBreakRange: ClosedRange<Double> = 0.5 ... 8.0
    static let bubbleFontSizeRange: ClosedRange<Double> = 10 ... 22

    // MARK: - Display

    /// Stable UUID of the display where windows should appear. nil = use
    /// the display the user happens to be on (system default).
    var targetDisplayUUID: String? {
        didSet {
            if let value = targetDisplayUUID, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: Keys.targetDisplayUUID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.targetDisplayUUID)
            }
        }
    }

    // MARK: - Speech recognition

    /// Which Whisper checkpoint to load on the next session start.
    var whisperModel: WhisperModel {
        didSet {
            UserDefaults.standard.set(whisperModel.rawValue, forKey: Keys.whisperModel)
        }
    }

    /// Which speech-to-text backend to use for the next session.
    var transcriptionEngine: TranscriptionEngineKind {
        didSet {
            UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine)
        }
    }

    /// Path the user picked for the local WhisperKit model. Required for
    /// the WhisperKit engine — no auto-download. `nil` means "not set".
    var whisperModelFolderPath: String? {
        didSet {
            if let value = whisperModelFolderPath, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: Keys.whisperModelFolderPath)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.whisperModelFolderPath)
            }
        }
    }

    /// Path the user picked for the Whisper tokenizer folder. Same repo
    /// shape as `openai/whisper-small` on Hugging Face.
    var whisperTokenizerFolderPath: String? {
        didSet {
            if let value = whisperTokenizerFolderPath, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: Keys.whisperTokenizerFolderPath)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.whisperTokenizerFolderPath)
            }
        }
    }

    /// Convenience: resolved URL for the model folder, or `nil` when unset.
    var whisperModelFolderURL: URL? {
        guard let path = whisperModelFolderPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Convenience: resolved URL for the tokenizer folder, or `nil` when unset.
    var whisperTokenizerFolderURL: URL? {
        guard let path = whisperTokenizerFolderPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Deepgram API key. Stored in the Keychain, NOT in UserDefaults.
    var deepgramAPIKey: String {
        didSet {
            KeychainStore.write(deepgramAPIKey, account: Keys.deepgramAPIKey)
        }
    }

    /// ElevenLabs API key (`xi-api-key`). Stored in the Keychain.
    var elevenLabsAPIKey: String {
        didSet {
            KeychainStore.write(elevenLabsAPIKey, account: Keys.elevenLabsAPIKey)
        }
    }

    // MARK: - Hotkeys

    /// Global shortcut for taking a screenshot. Unbound by default.
    var screenshotHotkey: HotkeyDescriptor {
        didSet { Self.persist(screenshotHotkey, key: Keys.screenshotHotkey) }
    }

    /// Global shortcut for toggling the Main HUD window. Unbound by default.
    var mainHUDToggleHotkey: HotkeyDescriptor {
        didSet { Self.persist(mainHUDToggleHotkey, key: Keys.mainHUDToggleHotkey) }
    }

    /// Global shortcut for toggling the CC HUD. Unbound by default.
    var ccHUDToggleHotkey: HotkeyDescriptor {
        didSet { Self.persist(ccHUDToggleHotkey, key: Keys.ccHUDToggleHotkey) }
    }

    /// What the screenshot hot key actually grabs: a display, a specific
    /// app's frontmost window, or the system default.
    var screenshotTarget: ScreenshotTarget {
        didSet { Self.persist(screenshotTarget, key: Keys.screenshotTarget) }
    }

    // MARK: - Chat history

    /// Id of the chat session that should be re-opened on next launch.
    var activeChatID: String? {
        didSet {
            if let value = activeChatID, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: Keys.activeChatID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.activeChatID)
            }
        }
    }

    // MARK: - Whisper vocabulary hint

    /// "Vocabulary hint" prompt fed to the active engine as a key-terms
    /// list (Whisper `promptTokens`, Deepgram `keyterm`, ElevenLabs
    /// `keyterms`). Comma-separated; edit once, all three engines benefit.
    var whisperVocabularyHint: String {
        didSet {
            UserDefaults.standard.set(whisperVocabularyHint, forKey: Keys.whisperVocabularyHint)
        }
    }

    // MARK: - CC HUD geometry (per display)

    /// Width fraction (0…1) of the host display, per display UUID.
    var ccHUDWidthFractionByDisplay: [String: Double] {
        didSet { Self.persist(ccHUDWidthFractionByDisplay, key: Keys.ccHUDWidthFractionByDisplay) }
    }

    /// Fixed pixel height of the CC strip, per display UUID.
    var ccHUDHeightByDisplay: [String: Double] {
        didSet { Self.persist(ccHUDHeightByDisplay, key: Keys.ccHUDHeightByDisplay) }
    }

    /// Gap, in points, between the bottom of the display and the bottom
    /// of the CC strip.
    var ccHUDBottomOffsetByDisplay: [String: Double] {
        didSet { Self.persist(ccHUDBottomOffsetByDisplay, key: Keys.ccHUDBottomOffsetByDisplay) }
    }

    /// Default CC width fraction. 0.7 of the host display.
    static let defaultCCHUDWidthFraction: Double = 0.7

    /// Default CC height — fits one large current line + a smaller
    /// previous line at the default font size.
    static let defaultCCHUDHeight: Double = 110

    /// Default vertical offset from the bottom of the screen. 80pt keeps
    /// the strip above a default-size Dock.
    static let defaultCCHUDBottomOffset: Double = 80

    static let ccHUDWidthFractionRange: ClosedRange<Double> = 0.30 ... 0.95
    static let ccHUDHeightRange: ClosedRange<Double> = 60 ... 240
    static let ccHUDBottomOffsetRange: ClosedRange<Double> = 20 ... 400

    func ccHUDWidthFraction(forDisplayUUID uuid: String?) -> Double {
        guard let uuid, let stored = ccHUDWidthFractionByDisplay[uuid] else {
            return Self.defaultCCHUDWidthFraction
        }
        return min(max(stored, Self.ccHUDWidthFractionRange.lowerBound), Self.ccHUDWidthFractionRange.upperBound)
    }

    func ccHUDHeight(forDisplayUUID uuid: String?) -> Double {
        guard let uuid, let stored = ccHUDHeightByDisplay[uuid] else {
            return Self.defaultCCHUDHeight
        }
        return min(max(stored, Self.ccHUDHeightRange.lowerBound), Self.ccHUDHeightRange.upperBound)
    }

    func ccHUDBottomOffset(forDisplayUUID uuid: String?) -> Double {
        guard let uuid, let stored = ccHUDBottomOffsetByDisplay[uuid] else {
            return Self.defaultCCHUDBottomOffset
        }
        return min(max(stored, Self.ccHUDBottomOffsetRange.lowerBound), Self.ccHUDBottomOffsetRange.upperBound)
    }

    func setCCHUDWidthFraction(_ value: Double, forDisplayUUID uuid: String) {
        var dict = ccHUDWidthFractionByDisplay
        dict[uuid] = min(max(value, Self.ccHUDWidthFractionRange.lowerBound), Self.ccHUDWidthFractionRange.upperBound)
        ccHUDWidthFractionByDisplay = dict
    }

    func setCCHUDHeight(_ value: Double, forDisplayUUID uuid: String) {
        var dict = ccHUDHeightByDisplay
        dict[uuid] = min(max(value, Self.ccHUDHeightRange.lowerBound), Self.ccHUDHeightRange.upperBound)
        ccHUDHeightByDisplay = dict
    }

    func setCCHUDBottomOffset(_ value: Double, forDisplayUUID uuid: String) {
        var dict = ccHUDBottomOffsetByDisplay
        dict[uuid] = min(max(value, Self.ccHUDBottomOffsetRange.lowerBound), Self.ccHUDBottomOffsetRange.upperBound)
        ccHUDBottomOffsetByDisplay = dict
    }

    // MARK: - CC HUD colors
    //
    // Stored as `#RRGGBBAA` hex strings — UserDefaults round-trip is plain
    // string. `CCHUDView` reads via the `cc*Color` SwiftUI Color helpers
    // below; the ColorPicker in Settings writes through the same helpers.

    /// Background plate colour. The window's opacity slider still scales
    /// this; storing alpha here lets a user pick e.g. dark blue translucent
    /// without flipping the global slider.
    var ccBackgroundColorHex: String {
        didSet { UserDefaults.standard.set(ccBackgroundColorHex, forKey: Keys.ccBackgroundColorHex) }
    }

    /// Colour of the previous (older) caption row text. Default is white;
    /// the view dims it via `.opacity(0.55)` so the current row stands out.
    var ccPreviousLineColorHex: String {
        didSet { UserDefaults.standard.set(ccPreviousLineColorHex, forKey: Keys.ccPreviousLineColorHex) }
    }

    /// Colour of the current (latest) caption row text. Default white.
    var ccCurrentLineColorHex: String {
        didSet { UserDefaults.standard.set(ccCurrentLineColorHex, forKey: Keys.ccCurrentLineColorHex) }
    }

    /// Colour of the translation text under each caption. Default is the
    /// warm yellow movie-subtitle convention.
    var ccTranslationColorHex: String {
        didSet { UserDefaults.standard.set(ccTranslationColorHex, forKey: Keys.ccTranslationColorHex) }
    }

    static let defaultCCBackgroundColorHex     = "#000000FF"
    static let defaultCCPreviousLineColorHex   = "#FFFFFFFF"
    static let defaultCCCurrentLineColorHex    = "#FFFFFFFF"
    static let defaultCCTranslationColorHex    = "#FFD966FF"

    /// SwiftUI Color reader/writer for the background hex — falls back to
    /// the hard default if the stored string is somehow malformed (manual
    /// edit of UserDefaults).
    var ccBackgroundColor: Color {
        get { Color(hex: ccBackgroundColorHex) ?? .black }
        set { ccBackgroundColorHex = newValue.toHexRGBA() ?? Self.defaultCCBackgroundColorHex }
    }

    var ccPreviousLineColor: Color {
        get { Color(hex: ccPreviousLineColorHex) ?? .white }
        set { ccPreviousLineColorHex = newValue.toHexRGBA() ?? Self.defaultCCPreviousLineColorHex }
    }

    var ccCurrentLineColor: Color {
        get { Color(hex: ccCurrentLineColorHex) ?? .white }
        set { ccCurrentLineColorHex = newValue.toHexRGBA() ?? Self.defaultCCCurrentLineColorHex }
    }

    var ccTranslationColor: Color {
        get { Color(hex: ccTranslationColorHex) ?? Color(red: 1.00, green: 0.85, blue: 0.40) }
        set { ccTranslationColorHex = newValue.toHexRGBA() ?? Self.defaultCCTranslationColorHex }
    }

    // MARK: - Translation

    /// Master switch for the auto-translate feature. Off by default.
    var translationEnabled: Bool {
        didSet { UserDefaults.standard.set(translationEnabled, forKey: Keys.translationEnabled) }
    }

    /// Target language for translation. Defaults to English. The UI exposes
    /// whatever the on-device Translation framework supports.
    var translationTargetLanguage: Language {
        didSet { UserDefaults.standard.set(translationTargetLanguage.rawValue, forKey: Keys.translationTargetLanguage) }
    }

    // MARK: - App presence

    var appPresenceMode: AppPresenceMode {
        didSet { UserDefaults.standard.set(appPresenceMode.rawValue, forKey: Keys.appPresenceMode) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: Keys.windowsHiddenFromCapture) == nil {
            self.windowsHiddenFromCapture = true
        } else {
            self.windowsHiddenFromCapture = defaults.bool(forKey: Keys.windowsHiddenFromCapture)
        }

        // Per-HUD settings — populated from the HUDDescriptor registry.
        let (op, top, spaces) = Self.loadHUDSettings(defaults: defaults)
        self.hudOpacity = op
        self.hudAlwaysOnTop = top
        self.hudShowOnAllSpaces = spaces

        let storedAppearance = defaults.string(forKey: Keys.appearance) ?? ""
        self.appearance = AppearanceMode(rawValue: storedAppearance) ?? .system

        let storedAccent = defaults.string(forKey: Keys.accentColor) ?? ""
        self.accentColor = AccentChoice(rawValue: storedAccent) ?? .system

        let storedMicBubble = defaults.string(forKey: Keys.micBubbleColor) ?? ""
        self.micBubbleColor = BubbleColor(rawValue: storedMicBubble) ?? .accent

        let storedSystemBubble = defaults.string(forKey: Keys.systemBubbleColor) ?? ""
        self.systemBubbleColor = BubbleColor(rawValue: storedSystemBubble) ?? .purple

        if defaults.object(forKey: Keys.captureMicrophone) == nil {
            self.captureMicrophone = true
        } else {
            self.captureMicrophone = defaults.bool(forKey: Keys.captureMicrophone)
        }

        if defaults.object(forKey: Keys.autoScrollMainHUD) == nil {
            self.autoScrollMainHUD = true
        } else {
            self.autoScrollMainHUD = defaults.bool(forKey: Keys.autoScrollMainHUD)
        }

        // Visibility: default false (matches the original "fresh install
        // opens only the menu bar" behaviour). Once the user shows a HUD
        // it's recorded and restored on the next launch.
        self.mainHUDVisible = defaults.bool(forKey: Keys.mainHUDVisible)
        self.ccHUDVisible   = defaults.bool(forKey: Keys.ccHUDVisible)

        if defaults.object(forKey: Keys.bubbleMaxChars) == nil {
            self.bubbleMaxChars = Self.defaultBubbleMaxChars
        } else {
            self.bubbleMaxChars = defaults.integer(forKey: Keys.bubbleMaxChars)
        }
        if defaults.object(forKey: Keys.bubbleSilenceBreakSec) == nil {
            self.bubbleSilenceBreakSec = Self.defaultBubbleSilenceBreakSec
        } else {
            self.bubbleSilenceBreakSec = defaults.double(forKey: Keys.bubbleSilenceBreakSec)
        }
        if defaults.object(forKey: Keys.bubbleSentenceAware) == nil {
            self.bubbleSentenceAware = Self.defaultBubbleSentenceAware
        } else {
            self.bubbleSentenceAware = defaults.bool(forKey: Keys.bubbleSentenceAware)
        }
        if defaults.object(forKey: Keys.bubbleFontSize) == nil {
            self.bubbleFontSize = Self.defaultBubbleFontSize
        } else {
            self.bubbleFontSize = defaults.double(forKey: Keys.bubbleFontSize)
        }

        let storedUUID = defaults.string(forKey: Keys.targetDisplayUUID)
        self.targetDisplayUUID = (storedUUID?.isEmpty == false) ? storedUUID : nil

        self.deepgramAPIKey  = KeychainStore.read(account: Keys.deepgramAPIKey)
        self.elevenLabsAPIKey = KeychainStore.read(account: Keys.elevenLabsAPIKey)

        let storedEngine = defaults.string(forKey: Keys.transcriptionEngine) ?? ""
        self.transcriptionEngine = TranscriptionEngineKind(rawValue: storedEngine) ?? .whisper

        let storedModel = defaults.string(forKey: Keys.whisperModel) ?? ""
        self.whisperModel = WhisperModel(rawValue: storedModel) ?? .small

        let storedModelFolder = defaults.string(forKey: Keys.whisperModelFolderPath)
        self.whisperModelFolderPath = (storedModelFolder?.isEmpty == false) ? storedModelFolder : nil

        let storedTokenizerFolder = defaults.string(forKey: Keys.whisperTokenizerFolderPath)
        self.whisperTokenizerFolderPath = (storedTokenizerFolder?.isEmpty == false) ? storedTokenizerFolder : nil

        self.screenshotHotkey      = Self.loadCodable(key: Keys.screenshotHotkey)      ?? .defaultScreenshot
        self.mainHUDToggleHotkey   = Self.loadCodable(key: Keys.mainHUDToggleHotkey)   ?? .defaultMainHUDToggle
        self.ccHUDToggleHotkey     = Self.loadCodable(key: Keys.ccHUDToggleHotkey)     ?? .defaultCCHUDToggle
        self.screenshotTarget      = Self.loadCodable(key: Keys.screenshotTarget)      ?? .systemDefault

        // CC HUD geometry — missing dict means "every display un-tuned"
        // and the accessors fall back to the global defaults.
        self.ccHUDWidthFractionByDisplay = Self.loadCodable(key: Keys.ccHUDWidthFractionByDisplay) ?? [:]
        self.ccHUDHeightByDisplay        = Self.loadCodable(key: Keys.ccHUDHeightByDisplay)        ?? [:]
        self.ccHUDBottomOffsetByDisplay  = Self.loadCodable(key: Keys.ccHUDBottomOffsetByDisplay)  ?? [:]

        // CC HUD colours — fall back to hard defaults if absent or malformed.
        self.ccBackgroundColorHex    = defaults.string(forKey: Keys.ccBackgroundColorHex)
            ?? Self.defaultCCBackgroundColorHex
        self.ccPreviousLineColorHex  = defaults.string(forKey: Keys.ccPreviousLineColorHex)
            ?? Self.defaultCCPreviousLineColorHex
        self.ccCurrentLineColorHex   = defaults.string(forKey: Keys.ccCurrentLineColorHex)
            ?? Self.defaultCCCurrentLineColorHex
        self.ccTranslationColorHex   = defaults.string(forKey: Keys.ccTranslationColorHex)
            ?? Self.defaultCCTranslationColorHex

        self.translationEnabled = defaults.bool(forKey: Keys.translationEnabled)
        let storedTarget = defaults.string(forKey: Keys.translationTargetLanguage) ?? ""
        self.translationTargetLanguage = Language(rawValue: storedTarget) ?? .en

        self.appPresenceMode = Self.loadAppPresenceMode()

        let storedChatID = defaults.string(forKey: Keys.activeChatID)
        self.activeChatID = (storedChatID?.isEmpty == false) ? storedChatID : nil

        // Vocabulary hint — start empty by default. Users can tune it
        // per use-case (technical interview, language class, etc.).
        if let stored = defaults.string(forKey: Keys.whisperVocabularyHint) {
            self.whisperVocabularyHint = stored
        } else {
            self.whisperVocabularyHint = ""
        }
    }

    // MARK: - Codable persistence helpers

    /// JSON-encode any Codable into `UserDefaults`.
    private static func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadCodable<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Reads `appPresenceMode` straight from `UserDefaults` without
    /// constructing a full `SettingsStore`. Called early in app launch so
    /// the activation policy can be applied before the Dock has a chance
    /// to draw the icon.
    static func loadAppPresenceMode() -> AppPresenceMode {
        let raw = UserDefaults.standard.string(forKey: Keys.appPresenceMode) ?? ""
        return AppPresenceMode(rawValue: raw) ?? .menuBar
    }

    /// Loads per-HUD opacity / always-on-top / show-on-all-spaces from
    /// UserDefaults at init time.
    private static func loadHUDSettings(defaults: UserDefaults) -> (
        opacity: [String: Double],
        alwaysOnTop: [String: Bool],
        showOnAllSpaces: [String: Bool]
    ) {
        var opacity: [String: Double] = [:]
        var alwaysOnTop: [String: Bool] = [:]
        var showOnAllSpaces: [String: Bool] = [:]

        for hud in HUDDescriptor.all {
            if defaults.object(forKey: hud.opacityKey) != nil {
                let stored = defaults.double(forKey: hud.opacityKey)
                opacity[hud.id] = min(max(stored, hud.opacityRange.lowerBound),
                                      hud.opacityRange.upperBound)
            }
            if defaults.object(forKey: hud.alwaysOnTopKey) != nil {
                alwaysOnTop[hud.id] = defaults.bool(forKey: hud.alwaysOnTopKey)
            }
            if hud.supportsShowOnAllSpaces,
               defaults.object(forKey: hud.showOnAllSpacesKey) != nil {
                showOnAllSpaces[hud.id] = defaults.bool(forKey: hud.showOnAllSpacesKey)
            }
        }

        return (opacity, alwaysOnTop, showOnAllSpaces)
    }

    // MARK: - Keys

    private enum Keys {
        static let windowsHiddenFromCapture = "WhisperCaption.settings.windowsHiddenFromCapture"
        static let captureMicrophone        = "WhisperCaption.settings.captureMicrophone"
        static let autoScrollMainHUD        = "WhisperCaption.settings.autoScrollMainHUD"
        static let mainHUDVisible           = "WhisperCaption.settings.mainHUDVisible"
        static let ccHUDVisible             = "WhisperCaption.settings.ccHUDVisible"
        static let bubbleMaxChars           = "WhisperCaption.settings.bubbleMaxChars"
        static let bubbleSilenceBreakSec    = "WhisperCaption.settings.bubbleSilenceBreakSec"
        static let bubbleSentenceAware      = "WhisperCaption.settings.bubbleSentenceAware"
        static let bubbleFontSize           = "WhisperCaption.settings.bubbleFontSize"
        static let targetDisplayUUID        = "WhisperCaption.settings.targetDisplayUUID"
        static let deepgramAPIKey           = "deepgram-api-key"
        static let elevenLabsAPIKey         = "elevenlabs-api-key"
        static let transcriptionEngine      = "WhisperCaption.settings.transcriptionEngine"
        static let screenshotHotkey         = "WhisperCaption.settings.screenshotHotkey"
        static let mainHUDToggleHotkey      = "WhisperCaption.settings.mainHUDToggleHotkey"
        static let ccHUDToggleHotkey        = "WhisperCaption.settings.ccHUDToggleHotkey"
        static let screenshotTarget         = "WhisperCaption.settings.screenshotTarget"
        static let whisperModel             = "WhisperCaption.settings.whisperModel"
        static let whisperModelFolderPath   = "WhisperCaption.settings.whisperModelFolderPath"
        static let whisperTokenizerFolderPath = "WhisperCaption.settings.whisperTokenizerFolderPath"
        static let whisperVocabularyHint    = "WhisperCaption.settings.whisperVocabularyHint"
        static let ccHUDWidthFractionByDisplay = "WhisperCaption.settings.ccHUDWidthFractionByDisplay"
        static let ccHUDHeightByDisplay        = "WhisperCaption.settings.ccHUDHeightByDisplay"
        static let ccHUDBottomOffsetByDisplay  = "WhisperCaption.settings.ccHUDBottomOffsetByDisplay"
        static let ccBackgroundColorHex        = "WhisperCaption.settings.ccBackgroundColorHex"
        static let ccPreviousLineColorHex      = "WhisperCaption.settings.ccPreviousLineColorHex"
        static let ccCurrentLineColorHex       = "WhisperCaption.settings.ccCurrentLineColorHex"
        static let ccTranslationColorHex       = "WhisperCaption.settings.ccTranslationColorHex"
        static let appearance                  = "WhisperCaption.settings.appearance"
        static let accentColor                 = "WhisperCaption.settings.accentColor"
        static let micBubbleColor              = "WhisperCaption.settings.micBubbleColor"
        static let systemBubbleColor           = "WhisperCaption.settings.systemBubbleColor"
        static let activeChatID                = "WhisperCaption.settings.activeChatID"
        static let translationEnabled          = "WhisperCaption.settings.translationEnabled"
        static let translationTargetLanguage   = "WhisperCaption.settings.translationTargetLanguage"
        static let appPresenceMode             = "WhisperCaption.settings.appPresenceMode"
    }
}
