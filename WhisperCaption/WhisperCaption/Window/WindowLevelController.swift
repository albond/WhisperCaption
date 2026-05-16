import AppKit
import Foundation
import Observation
import OSLog

/// Drives `NSWindow.level` per HUD based on `store.alwaysOnTop(for:)`.
/// Walks `HUDDescriptor.all` on every change so adding a new HUD is
/// zero-touch here.
///
/// Level mapping:
///  * ON  → `descriptor.alwaysOnTopLevel` (`.floating` for ordinary
///          windows, `.overlayWindow` for NSPanel-based HUDs)
///  * OFF → `.normal` — the window can be covered by other apps and is
///          subject to standard window cycling.
///
/// Each HUD's `alwaysOnTop` toggle is independent, so you can have one
/// HUD pinned overlay-style, another at normal level, and Settings
/// floating — all at once.
@MainActor
final class WindowLevelController {

    private let log = Log.HUD
    private let store: SettingsStore
    private var newWindowToken: NSObjectProtocol?

    init(store: SettingsStore) {
        self.store = store
        applyToAllWindows()
        observeSettings()
        observeNewWindows()
    }

    deinit {
        if let token = newWindowToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Push the per-HUD always-on-top level onto every recognised
    /// NSWindow. Windows we don't manage (auxiliary AppKit helpers,
    /// hidden frames) are left alone.
    func applyToAllWindows() {
        var touched = 0
        for hud in HUDDescriptor.all {
            guard let window = NSApp.windows.first(where: hud.matches) else { continue }
            let level: NSWindow.Level = store.alwaysOnTop(for: hud)
                ? hud.alwaysOnTopLevel
                : .normal
            if window.level != level {
                window.level = level
            }
            touched += 1
        }
        log.info("applied per-HUD window levels to \(touched) window(s)")
    }

    private func observeSettings() {
        withObservationTracking { [self] in
            _ = store.hudAlwaysOnTop
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyToAllWindows()
                self.observeSettings()
            }
        }
    }

    private func observeNewWindows() {
        newWindowToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyToAllWindows()
            }
        }
    }
}
