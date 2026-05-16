import AppKit
import Foundation
import Observation
import OSLog

/// Pins `NSWindow.alphaValue` on every HUD whose `HUDDescriptor.opacityStrategy`
/// is `.windowAlpha` (Main HUD + Settings HUD by default — CC HUD paints
/// its own background in SwiftUI). Iterates `HUDDescriptor.all` so adding
/// a new HUD is just one entry in the registry — no controller changes
/// needed.
///
/// Live re-application: observes `store.hudOpacity` (the @Observable
/// dictionary) so any slider move in `WindowsSection` repaints the
/// matching window immediately. Also listens for
/// `NSWindow.didBecomeMainNotification` so a freshly-opened window
/// picks up the correct alpha as soon as it appears.
@MainActor
final class WindowOpacityController {

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

    /// Walk `HUDDescriptor.all`, find each HUD's NSWindow in `NSApp.windows`,
    /// and apply its opacity if (and only if) the descriptor uses
    /// `.windowAlpha`. HUDs that paint their own opacity (CC HUD) or hand
    /// the window's alpha to another controller are left untouched so
    /// there's never two writers fighting over the same `alphaValue`.
    /// Idempotent.
    func applyToAllWindows() {
        var applied = 0
        var skipped = 0
        for hud in HUDDescriptor.all where hud.opacityStrategy == .windowAlpha {
            guard let window = NSApp.windows.first(where: hud.matches) else {
                continue  // window not yet created — picked up by didBecomeMain
            }
            // macOS docs: `alphaValue` only takes effect once `isOpaque`
            // is false. Without this the compositor's fast path skips
            // alpha blending and the window stays solid.
            if window.isOpaque { window.isOpaque = false }
            window.alphaValue = CGFloat(store.opacity(for: hud))
            applied += 1
        }
        for hud in HUDDescriptor.all where hud.opacityStrategy != .windowAlpha {
            if NSApp.windows.first(where: hud.matches) != nil { skipped += 1 }
        }
        log.info("applied per-HUD opacity to \(applied) window(s), skipped \(skipped) externally-managed HUD(s)")
    }

    private func observeSettings() {
        withObservationTracking { [self] in
            _ = store.hudOpacity
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyToAllWindows()
                self.observeSettings()
            }
        }
    }

    private func observeNewWindows() {
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

    /// Clamp helper retained for the App Intent call-sites — keeps the
    /// intent's "0...100" contract intuitive while ensuring the written
    /// value lands inside the target HUD's legal opacity range.
    static func clampOpacity(_ value: Double, for hud: HUDDescriptor) -> Double {
        let range = hud.opacityRange
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
