import AppKit
import Foundation
import OSLog

/// Two responsibilities:
///
/// 1. Persist window frames across launches per logical role (main /
///    settings / future HUD), so the user's chosen size and monitor
///    stick. Done via NSWindow's built-in `setFrameAutosaveName` —
///    macOS reads/writes UserDefaults under `NSWindow Frame <name>`.
///
/// 2. Recover when a saved frame lands offscreen — most commonly when
///    the user disconnects a monitor between sessions. AppKit will
///    happily place the window outside any visible NSScreen, leaving
///    it unreachable except via Mission Control. We detect this and
///    re-centre on the main screen.
///
/// Also handles a `.resetWindowFrames` notification (posted by Settings
/// → Display → "Reset window positions") so the user has an emergency
/// button when something goes wrong despite the live recovery.
@MainActor
final class WindowFrameController {

    private let log = Log.HUD

    init() {
        // Apply once on launch — by the time we're constructed, the
        // first NSWindow already exists (called from onAppear in App).
        applyToAllWindows()

        // New windows: catch each one as it appears. The Settings
        // window is created lazily on first ⌘, — without this hook we'd
        // miss it on the first open.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                Self.apply(to: window)
            }
        }

        // Manual reset path from Settings → Display.
        NotificationCenter.default.addObserver(
            forName: .resetWindowFrames,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetAll()
            }
        }
    }

    private func applyToAllWindows() {
        for window in NSApp.windows {
            Self.apply(to: window)
        }
    }

    private static func apply(to window: NSWindow) {
        // Skip transient AppKit-internal windows (NSStatusBarWindow,
        // accessory inspectors, completion popovers) — they don't have
        // user-visible identity and persisting their frames pollutes
        // UserDefaults. Heuristic: only main-content-style windows have
        // a non-empty identifier or are titled.
        guard window.canBecomeKey || window.canBecomeMain else { return }
        guard let name = autosaveName(for: window) else { return }

        if window.frameAutosaveName != name {
            window.setFrameAutosaveName(name)
            // `setFrameAutosaveName` already restores the saved frame if
            // one exists — so the offscreen check below catches the
            // restored value, not the freshly-built default.
        }

        if !isOnAnyScreen(window.frame) {
            recenter(window)
        }
    }

    private static func autosaveName(for window: NSWindow) -> String? {
        // SwiftUI gives the main scene's NSWindow a synthesised identifier
        // that can contain a substring resembling another scene's name.
        // Match the exact stable substring SwiftUI uses for the Settings
        // scene to disambiguate.
        let id = window.identifier?.rawValue ?? ""
        if id.contains("com_apple_SwiftUI_Settings") || id.contains("NSPreferencesPanel") {
            return "WhisperCaption.SettingsWindow"
        }
        return "WhisperCaption.MainWindow"
    }

    private static func isOnAnyScreen(_ frame: CGRect) -> Bool {
        // `visibleFrame` excludes the menu bar / Dock — using the full
        // `frame` here would consider a window "on-screen" when its
        // titlebar is hidden under the menu bar.
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private static func recenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Clamp size to the target screen so a window remembered from a
        // larger monitor doesn't bleed off the smaller current one.
        let size = CGSize(
            width:  min(window.frame.width,  visible.width  - 40),
            height: min(window.frame.height, visible.height - 40)
        )
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(CGRect(origin: origin, size: size), display: true, animate: false)
    }

    /// Wipe persisted frames and re-centre everything currently open.
    /// Triggered by the Settings button — last-resort escape hatch when
    /// a window has wandered off all displays despite the live recovery.
    private func resetAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("NSWindow Frame WhisperCaption.") {
            defaults.removeObject(forKey: key)
        }
        for window in NSApp.windows {
            guard window.canBecomeKey || window.canBecomeMain else { continue }
            Self.recenter(window)
        }
        log.info("reset window frames + re-centred all open windows")
    }
}

extension Notification.Name {
    /// Posted by Settings → Display → "Reset window positions". The
    /// `WindowFrameController` listens and re-centres every visible
    /// window plus clears all saved frame defaults.
    static let resetWindowFrames = Notification.Name("whispercaption.resetWindowFrames")
}
