import SwiftUI

/// Unified "look & layout" page — theme, accent, chat bubble colors,
/// app-presence (Dock icon), reset windows, and target display.
///
/// This section is the merge of what used to be three separate sidebar
/// entries (General + Appearance + Display). They were collapsed because
/// the underlying knobs are all about *how the app presents itself* on
/// screen, and three near-empty sidebar rows were costing more attention
/// than they earned. Live previewed — switching theme animates the rest
/// of the Settings window immediately via `.preferredColorScheme(...)`
/// installed at the SettingsView root.
struct AppearanceSection: View {

    @Environment(SettingsStore.self) private var store
    @State private var displays: [DisplayInfo] = []
    private let descriptor = SettingsCategoryID.appearance.descriptor

    var body: some View {
        @Bindable var store = store

        SectionShell(descriptor: descriptor) {

            // Theme tiles
            SettingsCard(
                title: "Theme",
                footer: "Match system follows the macOS Light / Dark setting. Pick Light or Dark to lock the app regardless of the system."
            ) {
                HStack(spacing: 12) {
                    ForEach(AppearanceMode.allCases) { mode in
                        ThemeTile(
                            mode: mode,
                            isSelected: store.appearance == mode
                        ) {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                store.appearance = mode
                            }
                        }
                    }
                }
            }

            // Accent picker
            SettingsCard(
                title: "Accent color",
                footer: "Applies app-wide — Settings controls, Main HUD chrome, and any bubble whose color is set to `Match accent`. `System` follows the macOS-wide accent."
            ) {
                AccentPicker(selection: $store.accentColor)
            }

            // Bubble colors
            SettingsCard(
                title: "Chat bubble colors",
                footer: "Per-side tint for the chat in the Main HUD. `Match accent` makes a bubble follow the accent above; pick a fixed color to lock it. Use the same value for both sides if you prefer a single-color chat."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Microphone (your side)")
                            .font(.callout.weight(.medium))
                        BubbleColorPicker(selection: $store.micBubbleColor)
                    }
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System audio (other side)")
                            .font(.callout.weight(.medium))
                        BubbleColorPicker(selection: $store.systemBubbleColor)
                    }
                }
            }

            // Windows: dock presence + target display + reset
            SettingsCard(
                title: "Windows",
                footer: "Menu-bar status item is always present (primary entry point). Dock icon is optional. Target display tells every window which monitor to land on. Reset clears saved window sizes/positions and re-centres them on the main display — use it when a window has wandered off all displays."
            ) {
                VStack(spacing: 0) {
                    dockRow(store: store)
                    SettingsRowDivider()
                    targetDisplayRow(store: store)
                    SettingsRowDivider()
                    resetWindowsRow
                }
            }
        }
        .onAppear { displays = Displays.all() }
    }

    // MARK: - Rows

    private func dockRow(store: SettingsStore) -> some View {
        Toggle(isOn: Binding(
            get: { store.appPresenceMode == .both },
            set: { store.appPresenceMode = $0 ? .both : .menuBar }
        )) {
            SettingsRowLabel(
                title: "Show Dock icon",
                subtitle: "When off, WhisperCaption lives in the menu bar only."
            )
        }
        .toggleStyle(.switch)
    }

    private func targetDisplayRow(store: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SettingsRowLabel(
                    title: "Target display",
                    subtitle: "Where the app's windows land. If the chosen display is disconnected, windows fall back to whatever is available."
                )
                Spacer()
                Picker("", selection: Binding(
                    get: { store.targetDisplayUUID ?? "" },
                    set: { store.targetDisplayUUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default (any display)").tag("")
                    Divider()
                    ForEach(displays) { d in
                        Text(label(for: d)).tag(d.uuid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if let uuid = store.targetDisplayUUID, Displays.screen(forUUID: uuid) == nil {
                Label(
                    "\(Displays.name(forUUID: uuid)) — not currently connected. Windows will appear on whatever display is available until it's plugged in again.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var resetWindowsRow: some View {
        HStack {
            SettingsRowLabel(
                title: "Reset window positions",
                subtitle: "Restores windows to their default placement on the main display."
            )
            Spacer()
            Button("Reset") {
                NotificationCenter.default.post(name: .resetWindowFrames, object: nil)
            }
            .buttonStyle(.bordered)
        }
    }

    private func label(for d: DisplayInfo) -> String {
        d.isMain ? "\(d.name) — main" : d.name
    }
}

// MARK: - Theme tile

private struct ThemeTile: View {

    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                Text(mode.displayName)
                    .font(.system(.callout, weight: .medium))
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Mini "window" mock-up: title bar + two faux text lines.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(previewBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                )

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 6, height: 6)
                    Circle().fill(Color.yellow.opacity(0.85)).frame(width: 6, height: 6)
                    Circle().fill(Color.green.opacity(0.85)).frame(width: 6, height: 6)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)

                RoundedRectangle(cornerRadius: 2)
                    .fill(previewForeground.opacity(0.55))
                    .frame(height: 4)
                    .padding(.horizontal, 8)

                RoundedRectangle(cornerRadius: 2)
                    .fill(previewForeground.opacity(0.30))
                    .frame(height: 4)
                    .padding(.horizontal, 8)

                Spacer()
            }
        }
        .frame(height: 60)
        .preferredColorScheme(mode.colorScheme)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var previewBackground: Color {
        switch mode {
        case .system: return Color(nsColor: .windowBackgroundColor)
        case .light:  return Color(red: 0.97, green: 0.97, blue: 0.98)
        case .dark:   return Color(red: 0.12, green: 0.12, blue: 0.14)
        }
    }

    private var previewForeground: Color {
        switch mode {
        case .system: return Color.primary
        case .light:  return Color.black
        case .dark:   return Color.white
        }
    }
}

// MARK: - Accent picker

private struct AccentPicker: View {

    @Binding var selection: AccentChoice

    private let columns = [
        GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(AccentChoice.allCases) { choice in
                AccentSwatch(
                    choice: choice,
                    isSelected: selection == choice
                ) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = choice
                    }
                }
            }
        }
    }
}

private struct AccentSwatch: View {

    let choice: AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(choice.swatchColor.gradient)
                        .frame(width: 26, height: 26)

                    if isSelected {
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 2)
                            .frame(width: 32, height: 32)
                    }

                    if choice == .system {
                        Image(systemName: "a.circle")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 34, height: 34)

                Text(choice.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.displayName)
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Bubble color picker

private struct BubbleColorPicker: View {

    @Binding var selection: BubbleColor

    private let columns = [
        GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(BubbleColor.allCases) { choice in
                BubbleColorSwatch(
                    choice: choice,
                    isSelected: selection == choice
                ) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = choice
                    }
                }
            }
        }
    }
}

private struct BubbleColorSwatch: View {

    let choice: BubbleColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(choice.swatchColor.gradient)
                        .frame(width: 26, height: 26)

                    if isSelected {
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 2)
                            .frame(width: 32, height: 32)
                    }

                    // The `accent` choice is a sentinel — overlay an `a`
                    // glyph to distinguish it from the literal accent-hued
                    // swatches, since both render the same color.
                    if choice == .accent {
                        Image(systemName: "a.circle")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 34, height: 34)

                Text(choice.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.displayName)
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    AppearanceSection()
        .environment(SettingsStore())
        .frame(width: 720, height: 820)
}
