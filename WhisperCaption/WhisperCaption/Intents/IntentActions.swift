import Foundation

/// App Intents are instantiated by the system in a fresh, ephemeral
/// context — they don't have direct access to our coordinator, the
/// `CaptionStream`, or any in-memory state. This singleton bridges
/// them: at app launch the coordinator publishes its action closures
/// here, and an intent's `perform()` simply invokes them.
///
/// We don't carry any state beyond closures. If an intent fires while
/// the closures haven't been wired yet (very early launch, extension
/// context), perform() returns silently — the user just sees no effect.
@MainActor
final class IntentActions {
    static let shared = IntentActions()
    private init() {}

    /// Take a screenshot of the configured target and append it as a
    /// bubble in the System column.
    var screenshot: (() -> Void)?

    /// Toggle the Main HUD (two-column captions chat).
    var toggleMainHUD: (() -> Void)?

    /// Toggle the CC HUD (movie-style subtitle strip).
    var toggleCCHUD: (() -> Void)?

    /// Externally-driven window opacity. Caller passes the window kind
    /// and desired % (0...100); the closure clamps to the controller's
    /// legal range before pushing into SettingsStore. Used by
    /// `SetWindowOpacityIntent` so a Stream Deck slider can dial
    /// transparency without opening the Settings window.
    var setOpacity: ((WindowOpacityTarget, Int) -> Void)?
}

/// Window the opacity intent should target.
enum WindowOpacityTarget: String, Sendable, CaseIterable {
    case main
    case cc
}
