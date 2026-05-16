import AppKit
import Foundation
import Observation
import OSLog

/// Keeps app windows on the user's chosen display.
///
/// Behaviour:
///   - On settings change: every visible window is moved to the target
///     display's center.
///   - When a display is connected/disconnected, we re-evaluate. If the
///     target reappears, windows go back to it. If it disappears, windows
///     stay where they are (we don't kick them around at random).
///   - If no target is set (`targetDisplayUUID == nil`), we don't move
///     anything — the user is free to drag windows wherever.
@MainActor
final class DisplayPinningController {

    private let log = Log.HUD
    private let store: SettingsStore
    private var screensToken: NSObjectProtocol?
    private var newWindowToken: NSObjectProtocol?

    init(store: SettingsStore) {
        self.store = store
        observeSettings()
        observeScreens()
        observeNewWindows()
        // Defer the initial move until after the app's first window appears.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.repinAllWindows()
        }
    }

    deinit {
        if let t = screensToken { NotificationCenter.default.removeObserver(t) }
        if let t = newWindowToken { NotificationCenter.default.removeObserver(t) }
    }

    // MARK: - Public

    /// Moves every currently-visible app window to the target display's
    /// center, but ONLY if the window is currently on a different display.
    /// If a window is already on the target, we leave it where the user
    /// dragged it — re-centering on every focus change is infuriating.
    /// No-op if no target is configured. If the chosen display isn't
    /// connected, we don't kick windows around.
    func repinAllWindows() {
        guard let uuid = store.targetDisplayUUID, !uuid.isEmpty else { return }
        guard let target = Displays.screen(forUUID: uuid) else {
            log.info("target display \(uuid, privacy: .public) not connected — leaving windows alone")
            return
        }
        for window in NSApp.windows where window.isVisible {
            if isAlreadyOn(window: window, screen: target) { continue }
            move(window: window, to: target)
        }
    }

    private func isAlreadyOn(window: NSWindow, screen: NSScreen) -> Bool {
        guard let current = window.screen else { return false }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let currentID = current.deviceDescription[key] as? NSNumber
        let targetID = screen.deviceDescription[key] as? NSNumber
        return currentID == targetID
    }

    // MARK: - Internals

    private func move(window: NSWindow, to screen: NSScreen) {
        // Re-center the window on the target screen. We keep the existing
        // size; the user can tune layout later.
        let target = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func observeSettings() {
        withObservationTracking { [self] in
            _ = store.targetDisplayUUID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.repinAllWindows()
                self.observeSettings()
            }
        }
    }

    private func observeScreens() {
        screensToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.log.info("screen parameters changed; re-pinning")
                self?.repinAllWindows()
            }
        }
    }

    private func observeNewWindows() {
        // When a new window opens (e.g. Settings sheet), nudge it onto the
        // target display so the whole UI stays put.
        newWindowToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repinAllWindows()
            }
        }
    }
}
