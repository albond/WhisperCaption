import AppKit
import OSLog
import Observation
import SwiftUI

/// Owns the system menu-bar `NSStatusItem` and the small menu hung under
/// it. The headline action is "Start/Stop Recognition" — the same toggle
/// the main window's big Start/Stop button drives — so the user can flip
/// recording on without bringing the app window forward.
///
/// Mounted/dismounted by user choice:
///   The controller observes `settings.appPresenceMode`. Flipping that
///   value retunes BOTH halves of the app's system presence in one step:
///     - `NSApp.setActivationPolicy(.regular | .accessory)` shows/hides
///       the Dock icon (and Cmd-Tab entry);
///     - `install()` / `uninstall()` adds/removes the `NSStatusItem`
///       from the system menu bar.
///   No relaunch is needed; the change is live.
///
/// When the app is in `.menuBar`-only mode the status menu is the user's
/// ONLY way back into the app, so it always carries "Show Window" and
/// "Quit" alongside the Start/Stop toggle.
@MainActor
@Observable
final class MenuBarController {

    @ObservationIgnored private let log = Log.HUD

    @ObservationIgnored private let stream: CaptionStream
    @ObservationIgnored private weak var settings: SettingsStore?

    /// `NSStatusBar.system.statusItem(...)` — held strong while installed
    /// so the icon stays in the menu bar.
    @ObservationIgnored private var statusItem: NSStatusItem?

    @ObservationIgnored private let menu: NSMenu

    /// The Start/Stop row whose title and enabled flag we flip in `refresh()`.
    @ObservationIgnored private let toggleItem: NSMenuItem

    /// "New Chat" row — same disabled-while-busy behaviour as the Start /
    /// Stop toggle, so a fresh session can't be created mid-transition.
    @ObservationIgnored private let newChatItem: NSMenuItem

    /// "Show in Dock" toggle. Held to flip its checkmark when the user
    /// changes presence mode from anywhere.
    @ObservationIgnored private let dockItem: NSMenuItem

    /// "Translation → Off" item. Held to flip its checkmark live when
    /// the user toggles translation from anywhere.
    @ObservationIgnored private var translationOffItem: NSMenuItem?

    /// Translation target-language items.
    @ObservationIgnored private var translationLanguageItems: [(lang: Language, item: NSMenuItem)] = []

    /// Toggle the CC HUD. Injected by the app delegate after the HUD
    /// controllers are built.
    @ObservationIgnored var ccHUDAction: (() -> Void)?

    /// Toggle the Main HUD (captions window). With the on-demand model
    /// the WindowGroup is `.defaultLaunchBehavior(.suppressed)`, so the
    /// window doesn't exist at app launch. Injected from a SwiftUI bridge
    /// that captures `@Environment(\.openWindow)` / `\.dismissWindow`.
    @ObservationIgnored var mainHUDAction: (() -> Void)?

    /// Take a screenshot of the configured target. Injected by the
    /// hotkey coordinator (same action the hotkey + intent use).
    @ObservationIgnored var screenshotAction: (() -> Void)?

    /// Open the SwiftUI `Settings` scene. Injected from a SwiftUI bridge
    /// view (`OpenSettingsBridge`) that captures `@Environment(\.openSettings)`
    /// — the AppKit responder-chain selector doesn't reliably reach the
    /// scene in `.accessory` builds.
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    init(stream: CaptionStream, settings: SettingsStore) {
        self.stream = stream
        self.settings = settings
        self.menu = NSMenu()
        self.toggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        self.newChatItem = NSMenuItem(title: "New Chat", action: nil, keyEquivalent: "")
        self.dockItem = NSMenuItem(title: "Show in Dock", action: nil, keyEquivalent: "")

        configureMenu()

        // Apply current presence mode before any observation kicks in.
        applyPresence(settings.appPresenceMode)

        observeState()
        observePresence()
        observeTranslation()
        refresh()

        log.info("menu-bar controller initialised (mode=\(settings.appPresenceMode.rawValue, privacy: .public))")
    }

    // MARK: - Setup

    private func configureMenu() {
        toggleItem.target = self
        toggleItem.action = #selector(toggleRecognition)
        menu.addItem(toggleItem)

        newChatItem.target = self
        newChatItem.action = #selector(newChat)
        menu.addItem(newChatItem)

        menu.addItem(.separator())

        let mainHUD = NSMenuItem(title: "Open Main HUD", action: #selector(toggleMainHUD), keyEquivalent: "")
        mainHUD.target = self
        menu.addItem(mainHUD)

        let ccHUD = NSMenuItem(title: "Toggle CC HUD", action: #selector(toggleCCHUD), keyEquivalent: "")
        ccHUD.target = self
        menu.addItem(ccHUD)

        let screenshot = NSMenuItem(title: "Take Screenshot", action: #selector(takeScreenshot), keyEquivalent: "")
        screenshot.target = self
        menu.addItem(screenshot)

        menu.addItem(.separator())

        // Translation submenu — Off + per-target-language radio.
        let translationItem = NSMenuItem(title: "Translation", action: nil, keyEquivalent: "")
        translationItem.submenu = buildTranslationSubmenu()
        menu.addItem(translationItem)

        menu.addItem(.separator())

        let tipJarItem = NSMenuItem(title: "Tip Jar…", action: #selector(openTipJar), keyEquivalent: "")
        tipJarItem.target = self
        menu.addItem(tipJarItem)

        menu.addItem(.separator())

        // ⌘, matches the standard "open Settings" shortcut.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Show in Dock — flips between `.menuBar` (Dock hidden) and `.both`
        // (Dock visible). Doesn't expose the third option (`.dock` only)
        // because picking that from this menu would tear down the menu —
        // there'd be no way back without opening Settings.
        dockItem.target = self
        dockItem.action = #selector(toggleDockPresence)
        menu.addItem(dockItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit WhisperCaption", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Presence (Dock + status item)

    /// Apply the chosen presence mode in one step: set the activation
    /// policy and ensure the status item is mounted iff the mode wants it.
    /// Idempotent — safe to call from observers on every settings tick.
    private func applyPresence(_ mode: AppPresenceMode) {
        NSApp.setActivationPolicy(mode.activationPolicy)
        if mode.showsMenuBarItem {
            install()
        } else {
            uninstall()
        }
    }

    /// Mount the status item if it isn't already. No-op when already up.
    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.menu = menu
        statusItem = item
        refresh()
        log.info("status item installed")
    }

    /// Remove the status item from the menu bar. No-op when already down.
    private func uninstall() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        log.info("status item uninstalled")
    }

    // MARK: - Observation

    /// Re-arms after each fire; standard Observation tracking pattern.
    private func observeState() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.stream.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observeState()
            }
        }
    }

    /// Watches the translation flags so the submenu checkmarks stay live
    /// as the user (or Settings, or a hotkey) flips state from anywhere.
    private func observeTranslation() {
        withObservationTracking { [weak self] in
            guard let self, let settings = self.settings else { return }
            _ = settings.translationEnabled
            _ = settings.translationTargetLanguage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observeTranslation()
            }
        }
    }

    /// Watches `appPresenceMode`. Re-arms after each change so the next
    /// flip is observed too.
    private func observePresence() {
        withObservationTracking { [weak self] in
            guard let self, let settings = self.settings else { return }
            _ = settings.appPresenceMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let settings = self.settings else { return }
                self.applyPresence(settings.appPresenceMode)
                self.refresh()
                self.observePresence()
            }
        }
    }

    /// Mirror the current `stream.state` into the menu item + status icon,
    /// and the current `appPresenceMode` into the Dock toggle's checkmark.
    private func refresh() {
        let s = stream.state
        toggleItem.title = menuItemTitle(for: s)
        // Disable while busy so a double-click can't enqueue start+stop+start.
        toggleItem.isEnabled = !s.isBusy
        newChatItem.isEnabled = !s.isBusy

        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: iconName(for: s),
                accessibilityDescription: "WhisperCaption"
            )
            // Tint red while running so the menu-bar icon is a glance-check
            // for "am I being recorded?". Nil → system default tint.
            button.contentTintColor = s.isRunning ? .systemRed : nil
        }

        dockItem.state = (settings?.appPresenceMode == .both) ? .on : .off
        refreshTranslationItems()
    }

    /// Mirror `settings.translationEnabled` + `settings.translationTargetLanguage`
    /// into the Translation submenu's checkmarks.
    private func refreshTranslationItems() {
        guard let settings else { return }
        translationOffItem?.state = settings.translationEnabled ? .off : .on
        for (lang, item) in translationLanguageItems {
            item.state = (settings.translationEnabled
                          && settings.translationTargetLanguage == lang) ? .on : .off
        }
    }

    // MARK: - Submenu builders

    /// Build the Translation submenu once at init. "Off" sits above
    /// a divider; each target language item carries its `Language`
    /// via `representedObject`.
    private func buildTranslationSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Translation")
        submenu.autoenablesItems = false

        let off = NSMenuItem(
            title: "Off",
            action: #selector(translationOff),
            keyEquivalent: ""
        )
        off.target = self
        submenu.addItem(off)
        translationOffItem = off

        submenu.addItem(.separator())

        for lang in Language.allCases {
            let item = NSMenuItem(
                title: lang.displayName,
                action: #selector(selectTranslationTarget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang
            submenu.addItem(item)
            translationLanguageItems.append((lang, item))
        }

        return submenu
    }

    private func menuItemTitle(for state: CaptionStream.State) -> String {
        switch state {
        case .idle, .error:        return "Start Recognition"
        case .running:             return "Stop Recognition"
        case .checkingPermissions: return "Checking permissions…"
        case .loadingModel:        return "Loading model…"
        case .starting:            return "Starting…"
        case .stopping:            return "Stopping…"
        }
    }

    private func iconName(for state: CaptionStream.State) -> String {
        switch state {
        case .running: return "waveform.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        default:       return "waveform"
        }
    }

    // MARK: - Actions

    @objc private func toggleRecognition() {
        Task { @MainActor in
            if stream.state.isRunning {
                await stream.stop()
            } else if !stream.state.isBusy {
                await stream.start()
            }
        }
    }

    @objc private func newChat() {
        guard !stream.state.isBusy else { return }
        stream.newSession()
    }

    @objc private func toggleMainHUD() {
        // Raise the app first so the window comes to focus in
        // `.accessory` mode.
        NSApp.activate(ignoringOtherApps: true)
        if let action = mainHUDAction {
            action()
            return
        }
        // Fallback before the bridge wires up (early launch race):
        // try to find an existing Main HUD window and bring it forward.
        if let main = NSApp.windows.first(where: HUDDescriptor.mainHUD.matches) {
            main.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func toggleCCHUD() {
        // CC HUD is a non-activating panel pinned to all Spaces, so it
        // doesn't need NSApp.activate — `ccHUDAction` (the controller's
        // own toggle) handles its own visibility.
        ccHUDAction?()
    }

    @objc private func takeScreenshot() {
        screenshotAction?()
    }

    @objc private func translationOff() {
        settings?.translationEnabled = false
    }

    @objc private func selectTranslationTarget(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? Language,
              let settings else { return }
        settings.translationTargetLanguage = lang
        settings.translationEnabled = true
    }

    /// Open Settings and jump straight to the Tip Jar page. Posts the
    /// category-selection notification one main-queue hop after the open
    /// call so `SettingsView` has mounted (and subscribed) by the time
    /// we ask it to change pages.
    @objc private func openTipJar() {
        NSApp.activate(ignoringOtherApps: true)
        if let action = openSettingsAction {
            action()
        } else {
            NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .selectSettingsCategory,
                object: SettingsCategoryID.tipJar
            )
        }
    }

    @objc private func openSettings() {
        // Activate first so the Settings window comes to the front in
        // `.accessory` mode (it would otherwise open behind whatever app
        // is frontmost).
        NSApp.activate(ignoringOtherApps: true)
        if let action = openSettingsAction {
            action()
            return
        }
        // Fallback: try the standard responder-chain selector. Doesn't
        // reliably reach SwiftUI's Settings scene in `.accessory` builds,
        // but works fine for `.regular`/`.both` users until the SwiftUI
        // bridge installs the real action.
        NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil)
    }

    @objc private func toggleDockPresence() {
        guard let settings else { return }
        switch settings.appPresenceMode {
        case .both:
            // Was visible in both → drop the Dock icon. Status item stays.
            settings.appPresenceMode = .menuBar
        case .menuBar:
            // Was menu-bar only → bring the Dock icon back.
            settings.appPresenceMode = .both
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - SwiftUI bridge for `\.openSettings`

/// Invisible 0×0 view whose only job is to capture SwiftUI's
/// `@Environment(\.openSettings)` action and hand it to `MenuBarController`
/// as a closure. Mounted inside the main `WindowGroup`'s `.background`,
/// where the environment value is in scope.
///
/// Why this exists: in `.accessory` builds the AppKit-style
/// `NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), …)` doesn't
/// reach SwiftUI's `Settings` scene — the responder chain doesn't have the
/// scene's responder installed when no window is key. The Environment-backed
/// `OpenSettingsAction` goes through SwiftUI's own scene plumbing and works
/// in both `.accessory` and `.regular`.
struct OpenSettingsBridge: View {
    var menuBar: MenuBarController?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // `task(id:)` re-runs whenever the controller flips between
            // nil and non-nil — covers both initial mount-after-onAppear
            // and any future re-creation.
            .task(id: menuBar != nil) {
                menuBar?.openSettingsAction = {
                    openSettings()
                    // In `.accessory` (menu-bar-only) mode the Settings
                    // window opens behind other apps because SwiftUI
                    // doesn't activate us. Async-hop, then explicitly
                    // raise the panel to front.
                    DispatchQueue.main.async {
                        let settingsWindow = NSApp.windows.first { window in
                            let raw = window.identifier?.rawValue ?? ""
                            return raw.contains("com_apple_SwiftUI_Settings")
                                || raw.contains("NSPreferencesPanel")
                        }
                        if let settingsWindow {
                            NSApp.activate()
                            settingsWindow.makeKeyAndOrderFront(nil)
                        }
                    }
                }
            }
    }
}
