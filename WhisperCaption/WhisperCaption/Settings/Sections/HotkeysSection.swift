import AppKit
import SwiftUI

/// Global hot keys + screenshot target picker. The recorder field is
/// `HotkeyRecorderField` from `Hotkeys/HotkeyRecorderField.swift`.
struct HotkeysSection: View {

    @Environment(SettingsStore.self) private var store
    private let descriptor = SettingsCategoryID.hotkeys.descriptor

    var body: some View {
        @Bindable var store = store

        SectionShell(descriptor: descriptor) {

            SettingsCard(
                title: "Global hot keys",
                footer: "These shortcuts work system-wide while WhisperCaption is running, even when the app is in the background. Press a combination with at least one modifier (⌃ ⌥ ⌘ ⇧). Press Esc to cancel recording. Use Clear to unbind. Note that some apps (Zoom, Teams) reserve their own shortcuts — pick a combo they don't use. Unbound actions can still be triggered via Shortcuts, App Intents, and Stream Deck."
            ) {
                VStack(spacing: 0) {
                    hotkeyRow(
                        title: "Take Screenshot",
                        subtitle: "Capture the chosen target into a chat bubble.",
                        binding: $store.screenshotHotkey
                    )
                    SettingsRowDivider()
                    hotkeyRow(
                        title: "Toggle Main HUD",
                        subtitle: "Show or hide the two-column captions chat window.",
                        binding: $store.mainHUDToggleHotkey
                    )
                    SettingsRowDivider()
                    hotkeyRow(
                        title: "Toggle CC HUD",
                        subtitle: "Caption strip at the bottom of the screen. Shows the last two system replies; hidden when there are none. Pressing again hides it.",
                        binding: $store.ccHUDToggleHotkey
                    )

                    SettingsRowDivider()

                    HStack {
                        Spacer()
                        Button("Clear all") {
                            store.screenshotHotkey      = .empty
                            store.mainHUDToggleHotkey   = .empty
                            store.ccHUDToggleHotkey     = .empty
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            ScreenshotTargetCard()
        }
    }

    private func hotkeyRow(
        title: String,
        subtitle: String,
        binding: Binding<HotkeyDescriptor>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 12)
            HotkeyRecorderField(descriptor: binding)
                .frame(minWidth: 170)
        }
    }
}

// MARK: - Screenshot target

private struct ScreenshotTargetCard: View {

    @Environment(SettingsStore.self) private var store

    @State private var displays: [DisplayInfo] = []
    @State private var apps: [RunningApp] = []

    enum Kind: String, CaseIterable, Identifiable {
        case systemDefault, display, app
        var id: String { rawValue }
        var title: String {
            switch self {
            case .systemDefault: return "Default (current display)"
            case .display:       return "Display"
            case .app:           return "Application"
            }
        }
    }

    private var currentKind: Kind {
        switch store.screenshotTarget {
        case .systemDefault: return .systemDefault
        case .display:       return .display
        case .app:           return .app
        }
    }

    var body: some View {
        SettingsCard(
            title: "Screenshot target",
            footer: "What \"Take Screenshot\" captures. Application captures the front-most on-screen window of the chosen app — handy when you only want the browser content, not your desktop."
        ) {
            VStack(spacing: 0) {
                HStack {
                    SettingsRowLabel(
                        title: "Source",
                        subtitle: nil
                    )
                    Spacer()
                    Picker("", selection: Binding(
                        get: { currentKind },
                        set: { newKind in
                            switch newKind {
                            case .systemDefault:
                                store.screenshotTarget = .systemDefault
                            case .display:
                                store.screenshotTarget = .display(uuid: displays.first?.uuid ?? "")
                            case .app:
                                store.screenshotTarget = .app(bundleID: apps.first?.bundleID ?? "")
                            }
                        }
                    )) {
                        ForEach(Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                switch store.screenshotTarget {
                case .systemDefault:
                    EmptyView()

                case .display(let uuid):
                    SettingsRowDivider()
                    HStack {
                        SettingsRowLabel(title: "Monitor", subtitle: nil)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { uuid },
                            set: { store.screenshotTarget = .display(uuid: $0) }
                        )) {
                            ForEach(displays) { d in
                                Text(d.isMain ? "\(d.name) — main" : d.name).tag(d.uuid)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                    if displays.first(where: { $0.uuid == uuid }) == nil {
                        Label(
                            "Selected monitor isn't connected. Will fall back to the current display.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 6)
                    }

                case .app(let bundleID):
                    SettingsRowDivider()
                    HStack {
                        SettingsRowLabel(title: "Application", subtitle: nil)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { bundleID },
                            set: { store.screenshotTarget = .app(bundleID: $0) }
                        )) {
                            ForEach(apps) { app in
                                Text(app.name).tag(app.bundleID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                    if apps.first(where: { $0.bundleID == bundleID }) == nil && !bundleID.isEmpty {
                        Label(
                            "\(RunningApps.displayName(forBundleID: bundleID)) isn't currently running. The screenshot will fail until it's launched.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 6)
                    }
                }
            }
        }
        // `.task` is more reliable than `.onAppear` inside SwiftUI's
        // Settings scene — Settings sometimes lazy-rebuilds the section
        // view without firing `.onAppear`, which was leaving the pickers
        // permanently empty.
        .task { refresh() }
        // Live-update the lists. `screensDidChangeNotification` fires
        // when a display is plugged/unplugged; the workspace
        // didLaunch/didTerminate notifications keep the apps list in
        // sync with what's actually open right now.
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refresh()
        }
        // Reset / refresh when the user flips Source — guarantees the
        // chosen list is fresh the moment they switch to Display / App.
        .onChange(of: store.screenshotTarget) { _, _ in
            refresh()
        }
    }

    private func refresh() {
        displays = Displays.all()
        apps     = RunningApps.current()
    }
}

#Preview {
    HotkeysSection()
        .environment(SettingsStore())
        .frame(width: 720, height: 700)
}
