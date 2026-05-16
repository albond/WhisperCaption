import AppIntents
import Foundation

/// App Intents make the app's actions reachable from outside our own UI:
///
///   - The Shortcuts app (programmable workflows, Apple Watch face,
///     iPhone home, Spotlight, Siri).
///   - `shortcuts run "..."` from any terminal / launcher / Hammerspoon /
///     Karabiner / Keyboard Maestro / cron.
///   - AppleScript / Apple Events — works from osascript and any
///     automation tool that speaks AE.
///   - Stream Deck / Razer Stream Controller plugins: those macropads
///     include "Run Shortcut" actions out of the box.
///
/// All intents are `openAppWhenRun = true`. With `false`, macOS runs the
/// intent in `BackgroundShortcutRunner` — a system-extension process that
/// has no access to our `IntentActions.shared` singleton, our actor state,
/// the audio pipeline or the caption stream. The intent then fails with
/// `LNContextErrorDomain code 2002` ("internal error"). With `true`,
/// macOS guarantees execution inside the host app process where the
/// singleton is populated.

struct TakeScreenshotIntent: AppIntent {

    static var title: LocalizedStringResource = "Take Screenshot"
    static var description = IntentDescription(
        "Capture the configured screenshot target (display or app window) and post a thumbnail bubble into the System column.",
        categoryName: "WhisperCaption"
    )

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.shared.screenshot?()
        return .result()
    }
}

struct ToggleMainHUDIntent: AppIntent {

    static var title: LocalizedStringResource = "Toggle Main HUD"
    static var description = IntentDescription(
        "Show or hide the two-column captions chat window.",
        categoryName: "WhisperCaption"
    )

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.shared.toggleMainHUD?()
        return .result()
    }
}

struct ToggleCCHUDIntent: AppIntent {

    static var title: LocalizedStringResource = "Toggle CC HUD"
    static var description = IntentDescription(
        "Show or hide the bottom-of-screen subtitle strip that mirrors the system-side audio.",
        categoryName: "WhisperCaption"
    )

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.shared.toggleCCHUD?()
        return .result()
    }
}

enum WindowOpacityIntentTarget: String, AppEnum {
    case main
    case cc

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Window"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .main: "Main HUD",
        .cc:   "CC HUD",
    ]
}

struct SetWindowOpacityIntent: AppIntent {

    static var title: LocalizedStringResource = "Set Window Opacity"
    static var description = IntentDescription(
        "Set the opacity (transparency) of one of the WhisperCaption windows. Pass a percentage from 30 to 100.",
        categoryName: "WhisperCaption"
    )

    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Window",
        description: "Which window to adjust."
    )
    var window: WindowOpacityIntentTarget

    /// Percentage [0..100]. The receiver clamps to the legal opacity
    /// floor (30%) — we accept lower values to keep the parameter
    /// contract intuitive ("0 means transparent") instead of failing
    /// the intent with a validation error mid-trigger.
    @Parameter(
        title: "Opacity (%)",
        description: "Window transparency from 30 (most transparent allowed) to 100 (fully opaque). Values below 30 are clamped to 30.",
        default: 100,
        inclusiveRange: (0, 100)
    )
    var percent: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        let target: WindowOpacityTarget = window == .main ? .main : .cc
        IntentActions.shared.setOpacity?(target, percent)
        return .result()
    }
}

/// Surfaces intents in the Shortcuts app under a WhisperCaption section.
struct WhisperCaptionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TakeScreenshotIntent(),
            phrases: [
                "\(.applicationName) take screenshot",
                "Snapshot with \(.applicationName)",
            ],
            shortTitle: "Take Screenshot",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: ToggleMainHUDIntent(),
            phrases: [
                "Toggle \(.applicationName) main window",
                "Open \(.applicationName)",
            ],
            shortTitle: "Toggle Main HUD",
            systemImageName: "rectangle.and.text.magnifyingglass"
        )
        AppShortcut(
            intent: ToggleCCHUDIntent(),
            phrases: [
                "Toggle \(.applicationName) subtitles",
                "Show \(.applicationName) captions",
            ],
            shortTitle: "Toggle CC HUD",
            systemImageName: "captions.bubble"
        )
        AppShortcut(
            intent: SetWindowOpacityIntent(),
            phrases: [
                "Set \(.applicationName) opacity",
                "\(.applicationName) opacity",
            ],
            shortTitle: "Set Window Opacity",
            systemImageName: "circle.lefthalf.filled"
        )
    }
}
