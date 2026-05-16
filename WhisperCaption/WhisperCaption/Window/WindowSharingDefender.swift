import AppKit
import Foundation
import Observation
import OSLog

/// Forces `NSWindow.sharingType = .none` on every window of the app
/// (configurable via `SettingsStore.windowsHiddenFromCapture`). With
/// sharing disabled, the window is excluded by the compositor from ANY
/// screen capture path:
///   - ScreenCaptureKit / `SCStream`
///   - `CGWindowListCreateImage`
///   - `screencapture` CLI
///   - Zoom / Teams / Webex / Google Meet / OBS screen-share
///
/// On older macOS the window appeared as a black rectangle in screenshots;
/// on recent macOS it's outright invisible.
///
/// Lifecycle:
///   - We listen for `NSWindow.didBecomeMainNotification` to catch new
///     windows the user might open (e.g. Settings sheet).
///   - We re-apply on every change to the settings flag using `@Observable`
///     tracking + re-arm.
@MainActor
final class WindowSharingDefender {

    private let log = Log.HUD
    private let store: SettingsStore
    private var notificationToken: NSObjectProtocol?

    init(store: SettingsStore) {
        self.store = store
        applyToAllWindows()
        observeSettings()
        observeNewWindows()
    }

    deinit {
        if let token = notificationToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public

    /// Apply the current setting to every NSWindow of the app.
    /// Idempotent — safe to call as often as you want.
    func applyToAllWindows() {
        let target: NSWindow.SharingType = store.windowsHiddenFromCapture ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = target
        }
        log.info("applied sharingType=\(self.describe(target), privacy: .public) to \(NSApp.windows.count) windows")
    }

    // MARK: - Internals

    private func observeSettings() {
        // `@Observable` tracking only fires once per onChange; we have to
        // re-arm after each fire to keep watching.
        withObservationTracking { [self] in
            _ = store.windowsHiddenFromCapture
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyToAllWindows()
                self.observeSettings()
            }
        }
    }

    private func observeNewWindows() {
        // `didBecomeMainNotification` fires when any NSWindow becomes the
        // app's main window — including the Settings panel the first time
        // it's opened. Cheap, fires rarely.
        notificationToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyToAllWindows()
            }
        }
    }

    private nonisolated func describe(_ type: NSWindow.SharingType) -> String {
        switch type {
        case .none: return "none (invisible to screen capture)"
        case .readOnly: return "readOnly (visible)"
        @unknown default: return "unknown"
        }
    }
}
