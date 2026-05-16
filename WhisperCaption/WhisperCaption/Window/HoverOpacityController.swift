import AppKit
import Foundation
import Observation
import OSLog

/// Drives a HUD's `alphaValue` based on where the cursor is on the display
/// the window lives on:
///
///   • Top-LEFT corner box  → alpha 0.0 (window fades out — peek behind it)
///   • Top-RIGHT corner box → alpha 1.0 (window fully visible)
///   • Anywhere else        → alpha = `SettingsStore.opacity(for: descriptor)`
///     (the user-controlled baseline tuned in Settings)
///
/// Rationale: cursor-driven opacity is a "hover that doesn't need focus":
/// no clicks, no keyboard, no extra hotkey to remember; it just responds
/// to where you're already looking.
///
/// Why polling instead of `addGlobalMonitorForEvents(.mouseMoved)`:
/// global mouse-moved monitors fire HUNDREDS of times per second when
/// the user is being expressive with the trackpad, on a thread we can't
/// throttle. A 20 Hz polling timer reading `NSEvent.mouseLocation` is
/// plenty for an opacity ease, and never spikes CPU. It also doesn't
/// require any Accessibility permission.
///
/// Coordination with `WindowOpacityController`:
/// the global controller skips windows whose descriptor uses
/// `.external` so the two writers never fight.
@MainActor
final class HoverOpacityController {

    /// Size in points of the hover-trigger box anchored at each top
    /// corner of the host display. 140pt × 140pt is large enough to hit
    /// without aiming and small enough not to swallow ordinary menu-bar
    /// use.
    static let zoneSize: CGFloat = 140

    /// Tween duration for alpha transitions when the cursor enters or
    /// leaves a zone. Short enough to feel responsive, long enough not
    /// to flicker on edge-skim.
    private static let animationDuration: TimeInterval = 0.18

    /// How often we sample the mouse location. 20 Hz is imperceptible to
    /// the user (the alpha tween smooths whatever cadence we feed it).
    private static let pollInterval: TimeInterval = 1.0 / 20.0

    private let log = Log.HUD
    private let store: SettingsStore
    private let descriptor: HUDDescriptor
    private let windowFinder: () -> NSWindow?
    private var timer: Timer?

    /// The zone whose target alpha is currently being applied to the
    /// window. We only animate on transition — re-applying the same
    /// alpha every tick would either thrash AppKit or never stabilise.
    private var currentZone: Zone = .baseline

    enum Zone: Equatable {
        case topLeft, topRight, baseline
    }

    /// `descriptor` MUST have `opacityStrategy == .external` so the global
    /// `WindowOpacityController` doesn't also try to paint the window's alpha.
    init(
        store: SettingsStore,
        descriptor: HUDDescriptor,
        windowFinder: @escaping () -> NSWindow?
    ) {
        self.store = store
        self.descriptor = descriptor
        self.windowFinder = windowFinder
        start()
        observeBaseline()
    }

    deinit {
        // Timer captures self; invalidating here breaks the cycle so the
        // controller can deallocate cleanly if the app ever tears it
        // down (currently lifecycle-bound to App).
        timer?.invalidate()
    }

    // MARK: - Mouse polling

    private func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        // Common modes so the timer keeps firing during menu tracking,
        // window dragging, etc. — exactly when the user is most likely
        // to be reaching for the corners.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let window = windowFinder(), window.isVisible else {
            // Window not visible → nothing to do. We DON'T skip the timer
            // entirely so that the moment it reappears we resume applying
            // the correct baseline immediately on the next tick.
            return
        }

        let zone = currentZone(for: window)
        guard zone != currentZone else { return }
        currentZone = zone

        let target = targetAlpha(for: zone)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.animationDuration
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
        }
    }

    /// Maps current mouse location to one of the three zones. Zone
    /// boxes are computed against the display the window actually sits
    /// on (`window.screen`) so the trigger geometry follows the user
    /// when they move the window to a different monitor.
    private func currentZone(for window: NSWindow) -> Zone {
        guard let screen = window.screen else { return .baseline }
        let mouse = NSEvent.mouseLocation
        // Mouse must be on the same screen as the window; on a multi-
        // monitor setup a TL corner of the OTHER screen shouldn't fade
        // the window on this one.
        guard screen.frame.contains(mouse) else { return .baseline }

        let f = screen.frame
        let s = Self.zoneSize
        let tl = NSRect(x: f.minX, y: f.maxY - s, width: s, height: s)
        let tr = NSRect(x: f.maxX - s, y: f.maxY - s, width: s, height: s)
        if tl.contains(mouse) { return .topLeft }
        if tr.contains(mouse) { return .topRight }
        return .baseline
    }

    private func targetAlpha(for zone: Zone) -> CGFloat {
        switch zone {
        case .topLeft:  return 0.0
        case .topRight: return 1.0
        case .baseline:
            // `store.opacity(for:)` already returns a value inside the
            // descriptor's `opacityRange`; no extra clamp needed.
            return CGFloat(store.opacity(for: descriptor))
        }
    }

    // MARK: - Baseline observation

    /// When the user moves the slider AND the cursor is currently in the
    /// neutral zone, we want the window to follow the new baseline
    /// immediately. Re-run the tick after invalidating `currentZone` so
    /// the next sample applies.
    private func observeBaseline() {
        withObservationTracking { [weak self] in
            // Track the whole per-HUD opacity dict — any change re-evaluates
            // (cheap), and only our slot affects this controller's output.
            _ = self?.store.hudOpacity
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentZone == .baseline {
                    self.currentZone = .topLeft  // force a transition on next tick
                }
                self.observeBaseline()
            }
        }
    }
}
