import SwiftUI
import AppKit
import OSLog

/// The `NSApplicationDelegate` owns every app-wide singleton. Living
/// here (rather than `@State` on the `App` struct) means initialisation
/// runs in `applicationDidFinishLaunching` — which fires regardless of
/// whether the Main HUD's `WindowGroup` body has rendered.
///
/// `@Observable` so SwiftUI views reading `appDelegate.menuBar` etc.
/// re-render once the controllers are constructed.
@Observable
@MainActor
final class WhisperCaptionAppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Core singletons (constructed at adaptor-init time)

    let settings = SettingsStore()
    let stream   = CaptionStream()
    /// Resolved through `makeHistory()` so UI tests can redirect the
    /// store at a temp fixture directory via the `-WCFixtureHistoryDir`
    /// launch argument without touching the user's real history.
    let history  = WhisperCaptionAppDelegate.makeHistory()

    /// Picks the history store. When `-WCFixtureHistoryDir <path>` is on
    /// the launch arguments (UI test fixture mode) the store points at
    /// the provided directory; otherwise the default Application Support
    /// resolver runs.
    private static func makeHistory() -> ChatHistoryStore {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-WCFixtureHistoryDir"),
           idx + 1 < args.count {
            let path = args[idx + 1]
            return ChatHistoryStore(directory: URL(fileURLWithPath: path))
        }
        return ChatHistoryStore()
    }

    // MARK: Controllers (constructed in `applicationDidFinishLaunching`)

    @ObservationIgnored var sharingDefender:   WindowSharingDefender?
    @ObservationIgnored var levelController:   WindowLevelController?
    @ObservationIgnored var displayPinner:     DisplayPinningController?
    @ObservationIgnored var frameController:   WindowFrameController?
    @ObservationIgnored var opacityController: WindowOpacityController?
    @ObservationIgnored var ccHUDController:   CCHUDController?
    @ObservationIgnored var hotkeyCoordinator: HotkeyCoordinator?
    /// `translator` is observed (not `@ObservationIgnored`) so SwiftUI views
    /// reading `appDelegate.translator` re-evaluate the moment bootstrap
    /// finishes — notably `TranslationHostView` (mounts the Apple session
    /// hosts) and the Main HUD's bubble context menus (offer "Translate" only
    /// when the translator is wired up).
    var translator: CaptionTranslator?

    /// Menu-bar controller — observed by SwiftUI bridges that wire its
    /// action closures (`OpenSettingsBridge`, `OpenMainHUDBridge`).
    var menuBar: MenuBarController?

    /// Flips to true at the end of `applicationDidFinishLaunching`. The
    /// `Settings` scene body branches on this so it can render a
    /// placeholder for the brief window between `Cmd+,` being pressed
    /// and bootstrap finishing.
    var bootstrapComplete: Bool = false

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Activation policy MUST be set before any window appears or the
        // Dock icon flashes for users who picked menu-bar-only mode.
        NSApp.setActivationPolicy(SettingsStore.loadAppPresenceMode().activationPolicy)

        // The Main HUD is always visible on launch — we no longer suppress
        // it based on a persisted "last visibility" flag. Reflect that in
        // settings so the menu-bar checkmark + toggle action stay coherent.
        settings.mainHUDVisible = true

        // UI test fixture mode: regular activation so XCUITest can find
        // the window, plus a redirect to a temp history with a specific
        // chat preselected.
        if ProcessInfo.processInfo.arguments.contains("-WCFixtureUIMode") {
            NSApp.setActivationPolicy(.regular)
            let args = ProcessInfo.processInfo.arguments
            if let idx = args.firstIndex(of: "-WCFixtureChatID"),
               idx + 1 < args.count {
                settings.activeChatID = args[idx + 1]
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrap()
    }

    private func bootstrap() {
        // Wire CaptionStream to its sibling singletons before any UI
        // observes it, so the very first render sees a fully-attached
        // stream.
        stream.attach(settings: settings, history: history)

        sharingDefender   = WindowSharingDefender(store: settings)
        levelController   = WindowLevelController(store: settings)
        displayPinner     = DisplayPinningController(store: settings)
        frameController   = WindowFrameController()
        opacityController = WindowOpacityController(store: settings)
        ccHUDController   = CCHUDController(stream: stream, store: settings)
        hotkeyCoordinator = HotkeyCoordinator(
            store: settings,
            stream: stream,
            ccHUD: ccHUDController!
        )
        translator = CaptionTranslator(stream: stream, settings: settings)

        // Setting `menuBar` last triggers SwiftUI re-render of any view
        // observing it, so the bridges fire only once they have a non-nil
        // controller to wire callbacks into.
        menuBar = MenuBarController(stream: stream, settings: settings)
        menuBar?.ccHUDAction = { [weak hotkeyCoordinator] in
            hotkeyCoordinator?.handleCCHUDToggle()
        }
        menuBar?.screenshotAction = { [weak hotkeyCoordinator] in
            hotkeyCoordinator?.handleScreenshot()
        }
        // `mainHUDAction` is wired by `OpenMainHUDBridge` inside the
        // Main HUD's WindowGroup body — needs SwiftUI's
        // `@Environment(\.openWindow)` which only exists in scene scope.

        // Restore last session's CC HUD visibility. The Main HUD is
        // always visible on launch (no per-session restore for it), so
        // only the CC HUD needs this branch.
        if settings.ccHUDVisible {
            ccHUDController?.show()
        }

        bootstrapComplete = true
    }
}

@main
struct WhisperCaptionApp: App {

    @NSApplicationDelegateAdaptor(WhisperCaptionAppDelegate.self) var appDelegate

    var body: some Scene {

        // Main HUD — the two-column captions chat. Always visible on
        // launch: SwiftUI auto-opens this WindowGroup at app start and
        // nothing dismisses it. The user toggles it via the menu bar or
        // the global hotkey; that toggle uses `OpenMainHUDBridge` to
        // dismiss/re-open the same window.
        WindowGroup(id: "main") {
            ContentView()
                .environment(appDelegate.settings)
                .environment(appDelegate.stream)
                .environment(appDelegate.history)
                .environment(\.captionTranslator, appDelegate.translator)
                // Theme + accent. Live-tracked through SettingsStore so the
                // Main HUD reacts to Appearance changes the same way the
                // Settings window does. `Color.accentColor` inside ContentView
                // (including any bubble whose color is set to `Match accent`)
                // resolves through this `.tint(...)`.
                .preferredColorScheme(appDelegate.settings.appearance.colorScheme)
                .tint(appDelegate.settings.accentColor.color)
                .background {
                    // Translation framework bridge — mounted whenever
                    // the WindowGroup body renders. Auto-translate keeps
                    // working even after the window is dismissed because
                    // the underlying `CaptionTranslator` outlives the view.
                    if let translator = appDelegate.translator {
                        TranslationHostView(translator: translator)
                    }
                    OpenSettingsBridge(menuBar: appDelegate.menuBar)
                    OpenMainHUDBridge(menuBar: appDelegate.menuBar, settings: appDelegate.settings)
                    MainHUDIdentifierApplier()
                }
        }

        Settings {
            if appDelegate.bootstrapComplete, let cc = appDelegate.ccHUDController {
                SettingsView()
                    .environment(appDelegate.settings)
                    .environment(appDelegate.history)
                    .environment(appDelegate.stream)
                    .environment(cc)
            } else {
                ProgressView()
                    .frame(width: 600, height: 400)
            }
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
    }
}

// MARK: - Main HUD SwiftUI bridges

/// Captures `@Environment(\.openWindow)` / `\.dismissWindow` and wires
/// them into `MenuBarController.mainHUDAction`. Lives in the Main HUD's
/// WindowGroup body so the environment values are in scope.
struct OpenMainHUDBridge: View {
    var menuBar: MenuBarController?
    var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: menuBar != nil) {
                menuBar?.mainHUDAction = {
                    toggleMainHUD(openWindow: openWindow, dismissWindow: dismissWindow)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleMainHUDRequested)) { _ in
                toggleMainHUD(openWindow: openWindow, dismissWindow: dismissWindow)
            }
    }

    private func toggleMainHUD(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        let visible = NSApp.windows.contains { window in
            HUDDescriptor.mainHUD.matches(window) && window.isVisible
        }
        if visible {
            dismissWindow(id: "main")
            settings.mainHUDVisible = false
        } else {
            openWindow(id: "main")
            // In `.accessory` (menu-bar-only) mode SwiftUI's `openWindow`
            // creates the window but doesn't raise it above other apps'
            // windows — async-hop to let SwiftUI finish constructing the
            // window, then explicitly bring it forward.
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: HUDDescriptor.mainHUD.matches) {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                }
            }
            settings.mainHUDVisible = true
        }
    }
}

/// Stamps the Main HUD's underlying NSWindow with
/// `HUDDescriptor.mainHUDWindowIdentifierRaw` so `WindowOpacityController`,
/// `WindowLevelController`, and the menu-bar toggle can recognise it.
struct MainHUDIdentifierApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(
                HUDDescriptor.mainHUDWindowIdentifierRaw
            )
            // Strip the minimize button per the Main HUD descriptor —
            // HUDs are toggled from the menu bar.
            if !HUDDescriptor.mainHUD.allowsMinimize {
                window.styleMask.remove(.miniaturizable)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Bridges `SettingsStore` to `HotkeyManager`: holds the manager, watches
/// the descriptors via `Observation.withObservationTracking`, and re-
/// registers when the user re-binds.
@MainActor
final class HotkeyCoordinator {

    private let manager = HotkeyManager()
    private weak var store: SettingsStore?
    private weak var stream: CaptionStream?
    private weak var ccHUD: CCHUDController?

    init(
        store: SettingsStore,
        stream: CaptionStream,
        ccHUD: CCHUDController
    ) {
        self.store = store
        self.stream = stream
        self.ccHUD = ccHUD

        // Publish callbacks for App Intents so Shortcuts / `shortcuts run` /
        // Stream Deck reach the same code path as the local hot keys.
        IntentActions.shared.screenshot     = { [weak self] in self?.handleScreenshot() }
        IntentActions.shared.toggleMainHUD  = { [weak self] in self?.handleMainHUDToggle() }
        IntentActions.shared.toggleCCHUD    = { [weak self] in self?.handleCCHUDToggle() }
        IntentActions.shared.setOpacity = { [weak self] target, percent in
            self?.handleSetOpacity(target: target, percent: percent)
        }
        applyAndObserve()
    }

    /// Receives a window target + 0...100 from `SetWindowOpacityIntent`,
    /// normalises into the target HUD's legal opacity range, and writes
    /// through the store.
    private func handleSetOpacity(target: WindowOpacityTarget, percent: Int) {
        guard let store else { return }
        let hud: HUDDescriptor = target == .main ? .mainHUD : .ccHUD
        let normalized = WindowOpacityController.clampOpacity(Double(percent) / 100.0, for: hud)
        store.setOpacity(normalized, for: hud)
    }

    private func applyAndObserve() {
        guard let store else { return }
        registerScreenshot(descriptor: store.screenshotHotkey)
        registerMainHUDToggle(descriptor: store.mainHUDToggleHotkey)
        registerCCHUDToggle(descriptor: store.ccHUDToggleHotkey)

        // Observation framework: re-runs the closure once per change to
        // any of the read properties. We re-arm tracking after each fire.
        withObservationTracking {
            _ = store.screenshotHotkey
            _ = store.mainHUDToggleHotkey
            _ = store.ccHUDToggleHotkey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyAndObserve()
            }
        }
    }

    private func registerScreenshot(descriptor: HotkeyDescriptor) {
        guard !descriptor.isEmpty else {
            manager.unregister(id: "screenshot")
            return
        }
        do {
            try manager.register(id: "screenshot", descriptor: descriptor) { [weak self] in
                self?.handleScreenshot()
            }
        } catch {
            showAlert(title: "Couldn't bind Take Screenshot", message: error.localizedDescription)
        }
    }

    private func registerMainHUDToggle(descriptor: HotkeyDescriptor) {
        guard !descriptor.isEmpty else {
            manager.unregister(id: "mainHUDToggle")
            return
        }
        do {
            try manager.register(id: "mainHUDToggle", descriptor: descriptor) { [weak self] in
                self?.handleMainHUDToggle()
            }
        } catch {
            showAlert(title: "Couldn't bind Toggle Main HUD", message: error.localizedDescription)
        }
    }

    private func registerCCHUDToggle(descriptor: HotkeyDescriptor) {
        guard !descriptor.isEmpty else {
            manager.unregister(id: "ccHUDToggle")
            return
        }
        do {
            try manager.register(id: "ccHUDToggle", descriptor: descriptor) { [weak self] in
                self?.handleCCHUDToggle()
            }
        } catch {
            showAlert(title: "Couldn't bind Toggle CC HUD", message: error.localizedDescription)
        }
    }

    // MARK: - Actions

    func handleMainHUDToggle() {
        // Routed through `OpenMainHUDBridge` so SwiftUI's scene-scoped
        // `\.openWindow` / `\.dismissWindow` can drive the window
        // lifecycle. The bridge observes this notification.
        NotificationCenter.default.post(name: .toggleMainHUDRequested, object: nil)
    }

    func handleCCHUDToggle() {
        ccHUD?.toggle()
    }

    func handleScreenshot() {
        let target = store?.screenshotTarget ?? .systemDefault
        guard let stream else { return }
        Task {
            let result = await ScreenshotCapture.capture(target: target)
            switch result {
            case .success(let png):
                let label = Self.screenshotLabel(target: target)
                stream.appendScreenshot(pngData: png, label: label)
            case .failure(let error):
                Log.App.error("screenshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func screenshotLabel(target: ScreenshotTarget) -> String {
        let time = Date().formatted(date: .omitted, time: .standard)
        switch target {
        case .systemDefault:
            return "Snapshot · \(time)"
        case .display(let uuid):
            let name = Displays.name(forUUID: uuid)
            return "Snapshot · \(name) · \(time)"
        case .app(let bundleID):
            let name = RunningApps.displayName(forBundleID: bundleID)
            return "Snapshot · \(name) · \(time)"
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension Notification.Name {
    /// Posted when the user requests a Main HUD toggle from a context
    /// that can't reach SwiftUI's scene-scoped `\.openWindow` directly
    /// (the global hotkey). `OpenMainHUDBridge` observes this and runs
    /// the same toggle action it exposes to `MenuBarController`.
    static let toggleMainHUDRequested = Notification.Name("whispercaption.toggleMainHUDRequested")
}
