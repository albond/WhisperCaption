import AppKit
import Foundation

/// Single registry of every "HUD" (in the broad sense — every window
/// the app owns: CC HUD, Main HUD, Settings HUD). Each entry declares:
///
///  * Defaults (opacity, always-on-top, on-all-spaces)
///  * Slider bounds for opacity (per-HUD floor — Settings floors at 0.40
///    so the user can never lock themselves out)
///  * `NSWindow.Level` to apply when "Always on top" is ON (`.floating`
///    for ordinary windows, `.overlayWindow` for HUD panels)
///  * `OpacityStrategy` — who owns the visible alpha (window-level alpha,
///    an external controller, or SwiftUI self-paints the background)
///  * `supportsShowOnAllSpaces` — true only for NSPanel-based HUDs that
///    can actually appear in dedicated fullscreen Spaces.
///  * `matches: (NSWindow) -> Bool` — predicate used by every controller
///    to find this HUD's NSWindow in `NSApp.windows`.
///
/// Adding a new HUD in the future:
///  1. Add a static entry to `HUDDescriptor.all` declaring all the above.
///  2. Create the NSWindow / NSPanel with an identifier the `matches`
///     closure can recognise.
/// Everything else (Settings UI card, opacity application, level
/// application, show-on-all-spaces wiring, persistence keys) is generated
/// from the registry.
@MainActor
struct HUDDescriptor: Identifiable, Sendable {

    /// Stable string id used as the dictionary key in `SettingsStore`
    /// and as the prefix of every UserDefaults key for this HUD.
    let id: String

    /// Human-readable name shown in Settings card titles and menu items.
    let displayName: String

    // MARK: Opacity

    let defaultOpacity: Double
    let opacityRange: ClosedRange<Double>
    let opacityStrategy: OpacityStrategy

    // MARK: Always on top

    let defaultAlwaysOnTop: Bool
    /// `NSWindow.Level` applied when the user's per-HUD always-on-top
    /// toggle is ON. OFF always means `.normal`. `.floating` covers the
    /// "above other app windows" case; `.overlayWindow` covers the
    /// "above EVERYTHING incl. fullscreen apps" case (HUD panels).
    let alwaysOnTopLevel: NSWindow.Level

    // MARK: Show on all Spaces

    /// True only when this HUD's window is structurally capable of
    /// appearing on every Mission Control Space — including dedicated
    /// fullscreen Spaces. Currently means NSPanel + `.nonactivatingPanel`.
    /// Settings UI hides the toggle when false.
    let supportsShowOnAllSpaces: Bool
    /// Default value of the toggle when `supportsShowOnAllSpaces == true`.
    /// Ignored when false.
    let defaultShowOnAllSpaces: Bool

    // MARK: Window identification

    /// Predicate used by every controller to find this HUD's NSWindow.
    /// A closure (not a flat identifier) because the Settings scene's
    /// identifier is SwiftUI-generated and needs substring matching.
    let matches: @MainActor @Sendable (NSWindow) -> Bool

    // MARK: Window chrome

    /// Should the underlying NSWindow expose the standard minimize
    /// (yellow) traffic-light button. False for every current HUD —
    /// they're toggle-shown from the menu bar, not minimized to the
    /// Dock (which doesn't even exist in `.menuBar` presence mode).
    let allowsMinimize: Bool

    var id_: String { id }
}

extension HUDDescriptor {

    /// Where the visible alpha for this HUD lives.
    enum OpacityStrategy: Sendable {
        /// `WindowOpacityController` writes `store.opacity(for: self)` into
        /// `window.alphaValue`. Default for ordinary NSWindow-backed HUDs.
        case windowAlpha
        /// A bespoke controller owns the window's alphaValue (e.g.
        /// `HoverOpacityController`). `WindowOpacityController` MUST
        /// skip this window or the two writers fight.
        case external
        /// SwiftUI body paints its own background opacity (e.g. CC HUD's
        /// `Color.black.opacity(...)` plate). Window stays fully opaque
        /// at the NSWindow level; opacity is a property of the rendered
        /// content. `WindowOpacityController` MUST skip the window.
        case selfPainted
    }
}

// MARK: - Registry

extension HUDDescriptor {

    /// Every HUD known to the app, in the order they appear in
    /// Settings → Windows. Add new entries here; the rest of the app
    /// (Settings UI, persistence, controllers) reads from this array.
    static let all: [HUDDescriptor] = [ccHUD, mainHUD, settingsHUD]

    /// Lookup by id. nil if the id is unknown — callers should treat
    /// that as "this is a window we don't manage" and skip.
    static func descriptor(forID id: String) -> HUDDescriptor? {
        all.first { $0.id == id }
    }

    /// Find the descriptor whose `matches` closure recognises this
    /// window. nil for windows we don't own (e.g. AppKit's hidden helper
    /// windows). Cheap — linear scan over `all.count`.
    static func descriptor(for window: NSWindow) -> HUDDescriptor? {
        all.first { $0.matches(window) }
    }
}

// MARK: - Individual descriptors

extension HUDDescriptor {

    /// CC HUD — NSPanel docked to the bottom of the active display.
    /// Opacity is painted by SwiftUI on a solid-black plate
    /// (`Color.black.opacity(...)`), NOT on the window alpha — text on
    /// top stays fully opaque even at low background opacity. Range
    /// floors at 0.20 to keep the strip visible.
    static let ccHUD = HUDDescriptor(
        id: "cc",
        displayName: "CC HUD",
        defaultOpacity: 0.70,
        opacityRange: 0.20 ... 1.0,
        opacityStrategy: .selfPainted,
        defaultAlwaysOnTop: true,
        alwaysOnTopLevel: NSWindow.Level(Int(CGWindowLevelForKey(.overlayWindow))),
        supportsShowOnAllSpaces: true,
        defaultShowOnAllSpaces: true,
        matches: { $0.identifier == CCHUDController.windowIdentifier },
        allowsMinimize: false
    )

    /// Main HUD — the two-column captions window, rendered as a regular
    /// SwiftUI WindowGroup window. Floored at 0.20 so it never becomes
    /// completely invisible.
    static let mainHUD = HUDDescriptor(
        id: "main",
        displayName: "Main HUD",
        defaultOpacity: 1.0,
        opacityRange: 0.20 ... 1.0,
        opacityStrategy: .windowAlpha,
        defaultAlwaysOnTop: false,
        alwaysOnTopLevel: .floating,
        supportsShowOnAllSpaces: false,
        defaultShowOnAllSpaces: false,
        matches: { $0.identifier?.rawValue == HUDDescriptor.mainHUDWindowIdentifierRaw },
        allowsMinimize: false
    )

    /// Settings HUD — the SwiftUI Settings scene. Floored at 0.40 as a
    /// hard safety net: even fully cranked down the user can still see
    /// the slider that controls everything else.
    static let settingsHUD = HUDDescriptor(
        id: "settings",
        displayName: "Settings HUD",
        defaultOpacity: 1.0,
        opacityRange: 0.40 ... 1.0,
        opacityStrategy: .windowAlpha,
        defaultAlwaysOnTop: false,
        alwaysOnTopLevel: .floating,
        supportsShowOnAllSpaces: false,
        defaultShowOnAllSpaces: false,
        matches: { window in
            let raw = window.identifier?.rawValue ?? ""
            return raw.contains("com_apple_SwiftUI_Settings")
                || raw.contains("NSPreferencesPanel")
        },
        allowsMinimize: false
    )

    /// Identifier we set on the Main HUD's NSWindow at first appearance.
    /// Plain string + matches by `rawValue` keeps the descriptor
    /// independent of the controller that mounts the window.
    static let mainHUDWindowIdentifierRaw = "WhisperCaption.MainHUD"
}

// MARK: - UserDefaults keys

extension HUDDescriptor {

    /// UserDefaults key for this HUD's opacity.
    var opacityKey: String {
        "WhisperCaption.settings.\(id)HUDOpacity"
    }

    /// UserDefaults key for this HUD's always-on-top toggle.
    var alwaysOnTopKey: String {
        "WhisperCaption.settings.\(id)HUDAlwaysOnTop"
    }

    /// UserDefaults key for this HUD's "show on all Spaces" toggle.
    /// Only meaningful when `supportsShowOnAllSpaces == true`.
    var showOnAllSpacesKey: String {
        "WhisperCaption.settings.\(id)HUDShowOnAllSpaces"
    }
}
