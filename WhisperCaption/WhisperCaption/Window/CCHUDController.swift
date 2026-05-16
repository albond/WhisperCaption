import AppKit
import SwiftUI
import OSLog

/// Owns the CC HUD NSPanel — a movie-style caption strip docked to the
/// bottom of the active display. Shows the last two SYSTEM-side captions
/// (the strip is focused on "what the other side just said"). Auto-hides
/// when there's nothing system-side to show.
///
/// Differences vs other HUDs:
///   * Anchor is BOTTOM-of-screen, not under the notch.
///   * Visibility is driven by a user toggle (hotkey / preview button)
///     plus "is there any system caption to show". When the toggle is
///     OFF the panel is orderedOut and we stop touching anything.
///   * A `demoCaptions` slot lets the Settings preview render canned
///     text without touching `CaptionStream`.
@Observable
@MainActor
final class CCHUDController {

    static let windowIdentifier = NSUserInterfaceItemIdentifier("WhisperCaption.CCHUD")

    @ObservationIgnored private let log = Log.HUD

    @ObservationIgnored private let stream: CaptionStream
    @ObservationIgnored private let store: SettingsStore

    /// The hosted NSPanel. Lazily created the first time we present.
    @ObservationIgnored private var window: NSPanel?

    /// SwiftUI host we rebuild on each refresh — captions are passed
    /// in as a plain `[Caption]` slice, so we throw away the rootView
    /// and remount when content changes. Cheap: two `Text` views.
    @ObservationIgnored private var host: NSHostingView<CCHUDView>?

    /// User-controlled visibility. `false` = hotkey/preview toggle is
    /// OFF, panel must stay hidden. `true` = controller is allowed to
    /// show the panel WHEN there's something to render.
    @ObservationIgnored private(set) var userWantsVisible: Bool = false

    /// Canned captions injected by Settings → "Show example". When
    /// non-nil they override the live `CaptionStream` data so the user
    /// can tune CC geometry without speaking.
    @ObservationIgnored private var demoCaptions: [Caption]?

    /// Cached "currently displayed" flag so re-evaluation can decide
    /// whether to animate in or out without poking the window directly.
    private(set) var isShown: Bool = false

    init(stream: CaptionStream, store: SettingsStore) {
        self.stream = stream
        self.store = store
        observeStream()
        observeSettings()
    }

    // MARK: - Public API

    /// Hotkey / Intent entry-point. Toggles user-visibility state and
    /// reevaluates whether the panel should actually be on screen.
    func toggle() {
        userWantsVisible.toggle()
        if !userWantsVisible {
            // Hiding clears any preview state — the next "show" starts
            // from a clean slate with the live caption stream.
            demoCaptions = nil
        }
        store.ccHUDVisible = userWantsVisible
        evaluate()
    }

    /// Bring the panel up programmatically (e.g. when restoring last
    /// session's visibility at app launch). Idempotent.
    func show() {
        guard !userWantsVisible else { return }
        userWantsVisible = true
        store.ccHUDVisible = true
        evaluate()
    }

    /// Settings → "Show example" entry. Switches into demo mode and
    /// forces the panel visible. Doesn't persist visibility — preview is
    /// an ephemeral UI action, not a user-state change.
    func showDemo() {
        demoCaptions = Self.demoSample
        userWantsVisible = true
        evaluate()
    }

    /// Settings → "Hide". Tears down demo state and orders out.
    func dismiss() {
        userWantsVisible = false
        demoCaptions = nil
        store.ccHUDVisible = false
        evaluate()
    }

    // MARK: - Decision

    /// Compute the captions slice (max 2) for the current state. When
    /// `demoCaptions` is set it wins; otherwise we take the last two
    /// system-side captions from the live stream.
    private func currentCaptions() -> [Caption] {
        if let demo = demoCaptions { return demo }

        let system = stream.captions
            .filter { $0.source == .system }
            .sorted { $0.startedAt < $1.startedAt }

        if system.count <= 2 { return system }
        return Array(system.suffix(2))
    }

    /// One pass of the show/hide decision. Called from observers and
    /// from public toggle/show/dismiss entry points.
    ///
    /// When the user toggles the CC HUD on a chat with no system-side
    /// captions yet, we still present the panel — the view renders a
    /// short "no system audio" hint so the user can see the hotkey is
    /// alive (silent-no-op behaviour felt like a broken binding).
    private func evaluate() {
        let captions = currentCaptions()
        if userWantsVisible {
            present(with: captions)
        } else if isShown {
            hide()
        } else {
            updateHost(captions: captions)
        }
    }

    // MARK: - Window lifecycle

    private func present(with captions: [Caption]) {
        ensureWindow()
        guard let w = window else { return }

        updateHost(captions: captions)
        applyCollectionBehavior(w)
        applySharingType(w)
        positionAtBottomOfTargetScreen(w)

        if !isShown {
            // Subtle fade-in from below. We don't slide it because the
            // strip can be tall (110pt+); a sliding 110pt rectangle
            // crossing the dock looks busier than a clean fade.
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1
            }
            isShown = true
            log.info("CC HUD shown with \(captions.count) caption(s)")
        }
    }

    private func hide() {
        guard let w = window, isShown else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.window?.orderOut(nil)
            }
        })
        isShown = false
        log.info("CC HUD hidden")
    }

    private func ensureWindow() {
        guard window == nil else { return }

        // Initial host with whatever captions the current state has —
        // saves a round-trip on the first show.
        let initialCaptions = currentCaptions()
        let host = NSHostingView(
            rootView: CCHUDView(
                captions: initialCaptions,
                backgroundOpacity: store.opacity(for: .ccHUD),
                backgroundColor: store.ccBackgroundColor,
                previousLineColor: store.ccPreviousLineColor,
                currentLineColor: store.ccCurrentLineColor,
                translationColor: store.ccTranslationColor
            )
        )
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        host.layer?.masksToBounds = true

        // NSPanel + `.nonactivatingPanel` is the ONLY combination that
        // reliably draws inside a dedicated full-screen Space without
        // yanking the user out of it.
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.worksWhenModal = true
        p.identifier = Self.windowIdentifier
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        // Level reflects the per-HUD `alwaysOnTop` toggle.
        // `WindowLevelController` keeps it in sync across toggle flips.
        p.level = store.alwaysOnTop(for: .ccHUD)
            ? HUDDescriptor.ccHUD.alwaysOnTopLevel
            : .normal
        p.isMovable = false
        // Click-through. The CC strip is pure read-only output; we don't
        // want it intercepting scrolls over browser content behind.
        p.ignoresMouseEvents = true
        p.contentView = host
        p.isReleasedWhenClosed = false

        // Critical: set collection-behavior + sharing type BEFORE the
        // first orderFront. WindowServer registers Space membership
        // and capture exclusion at first display; retro-patching has
        // edge cases.
        applyCollectionBehavior(p)
        applySharingType(p)

        self.host = host
        self.window = p
        log.info("CC HUD panel created at level \(p.level.rawValue)")
    }

    /// Reaches into the (possibly nil) host view and pushes a fresh
    /// rootView with the latest captions / opacity / colours.
    /// `NSHostingView` is fine with rapid `rootView` reassignment —
    /// diffing is internal.
    private func updateHost(captions: [Caption]) {
        host?.rootView = CCHUDView(
            captions: captions,
            backgroundOpacity: store.opacity(for: .ccHUD),
            backgroundColor: store.ccBackgroundColor,
            previousLineColor: store.ccPreviousLineColor,
            currentLineColor: store.ccCurrentLineColor,
            translationColor: store.ccTranslationColor
        )
    }

    private func positionAtBottomOfTargetScreen(_ w: NSWindow) {
        let screen = preferredScreen()
        let frame = screen.frame
        let widthFraction = store.ccHUDWidthFraction(forDisplayUUID: screen.wc_displayUUID)
        let height = store.ccHUDHeight(forDisplayUUID: screen.wc_displayUUID)
        let bottomOffset = store.ccHUDBottomOffset(forDisplayUUID: screen.wc_displayUUID)
        let width = frame.width * widthFraction

        let newFrame = NSRect(
            x: frame.midX - width / 2,
            y: frame.minY + bottomOffset,
            width: width,
            height: height
        )
        w.setFrame(newFrame, display: true)
    }

    /// Pinned display first, then `NSScreen.main` (the one with the
    /// cursor), then any screen.
    private func preferredScreen() -> NSScreen {
        if let uuid = store.targetDisplayUUID,
           let screen = Displays.screen(forUUID: uuid) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
    }

    private func applyCollectionBehavior(_ w: NSWindow) {
        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if store.showOnAllSpaces(for: .ccHUD) {
            behavior.insert(.canJoinAllSpaces)
            behavior.insert(.fullScreenAuxiliary)
        }
        w.collectionBehavior = behavior
    }

    /// Mirror `windowsHiddenFromCapture` onto the panel directly —
    /// `WindowSharingDefender` only hooks `didBecomeMainNotification`
    /// and our `.nonactivatingPanel` NSPanel never becomes main, so
    /// the defender doesn't see it.
    private func applySharingType(_ w: NSWindow) {
        w.sharingType = store.windowsHiddenFromCapture ? .none : .readOnly
    }

    // MARK: - Observation

    /// Watch the caption stream. Each change re-runs `evaluate()`.
    private func observeStream() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.stream.captions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluate()
                self?.observeStream()
            }
        }
    }

    /// Watch the geometry / behaviour settings. Any change re-applies
    /// to the panel (if it's been created) so live-tuning sliders in
    /// Settings → Display moves / resizes / re-styles the strip in
    /// real time.
    private func observeSettings() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.store.hudOpacity
            _ = self.store.hudShowOnAllSpaces
            _ = self.store.ccHUDWidthFractionByDisplay
            _ = self.store.ccHUDHeightByDisplay
            _ = self.store.ccHUDBottomOffsetByDisplay
            _ = self.store.targetDisplayUUID
            _ = self.store.windowsHiddenFromCapture
            _ = self.store.ccBackgroundColorHex
            _ = self.store.ccPreviousLineColorHex
            _ = self.store.ccCurrentLineColorHex
            _ = self.store.ccTranslationColorHex
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let w = self.window {
                    self.applyCollectionBehavior(w)
                    self.applySharingType(w)
                    if self.isShown {
                        self.positionAtBottomOfTargetScreen(w)
                        self.updateHost(captions: self.currentCaptions())
                    }
                }
                self.observeSettings()
            }
        }
    }

    // MARK: - Demo data

    /// Canned captions used by the Settings preview button.
    private static let demoSample: [Caption] = {
        let now = Date()
        return [
            Caption(
                id: UUID(),
                source: .system,
                text: "And tell me how the cache layer is set up in your backend.",
                language: .en,
                isFinal: true,
                startedAt: now.addingTimeInterval(-6),
                updatedAt: now.addingTimeInterval(-6)
            ),
            Caption(
                id: UUID(),
                source: .system,
                text: "We used Redis with a 60-second TTL on hot keys and a cron job that refreshed them every minute.",
                language: .en,
                isFinal: false,
                startedAt: now.addingTimeInterval(-1),
                updatedAt: now
            )
        ]
    }()
}
