import SwiftUI

/// Per-window settings auto-generated from the `HUDDescriptor` registry.
/// One card per HUD (Main, Settings). CC HUD has its own dedicated
/// section so the same `WindowCard` is reused there. Each card exposes:
///   * Opacity slider (range = `descriptor.opacityRange`, percent label)
///   * Always-on-top toggle
///   * Show-on-all-Spaces toggle — rendered ONLY when the descriptor
///     declares `supportsShowOnAllSpaces == true` (NSPanel-based HUDs).
///     Honest UI: ordinary windows can't fully participate in dedicated
///     fullscreen Spaces, so we don't pretend.
///
/// Above the per-HUD cards sits the GLOBAL "Hide from screen capture"
/// toggle — one flag that applies to every window. Lives here (not in
/// Privacy) so every window-visibility control is in one place.
struct WindowsSection: View {

    @Environment(SettingsStore.self) private var store
    private let descriptor = SettingsCategoryID.windows.descriptor

    var body: some View {
        SectionShell(descriptor: descriptor) {
            // Per-HUD cards — one per registry entry except the CC HUD,
            // which has its own dedicated Settings section. The global
            // "Hide from screen capture" toggle now lives in Privacy
            // because it's a privacy concern, not a per-window setting.
            ForEach(HUDDescriptor.all.filter { $0.id != "cc" }) { hud in
                WindowCard(hud: hud)
            }
        }
    }
}

// MARK: - Per-HUD card

/// One card with opacity slider + always-on-top toggle + (conditional)
/// show-on-all-spaces toggle. Used both here (Main / Settings HUDs) and
/// from `CCHUDSection` for the CC HUD descriptor.
struct WindowCard: View {

    @Environment(SettingsStore.self) private var store
    let hud: HUDDescriptor

    var body: some View {
        SettingsCard(
            title: hud.displayName,
            footer: footer
        ) {
            VStack(spacing: 0) {
                opacityRow
                SettingsRowDivider()
                alwaysOnTopRow
                if hud.supportsShowOnAllSpaces {
                    SettingsRowDivider()
                    showOnAllSpacesRow
                }
            }
        }
    }

    // MARK: Rows

    private var opacityRow: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title: "Opacity", subtitle: opacitySubtitle)
            Spacer(minLength: 12)
            Slider(
                value: store.opacityBinding(for: hud),
                in: hud.opacityRange
            )
            .frame(maxWidth: 240)
            Text("\(Int(store.opacity(for: hud) * 100))%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    private var alwaysOnTopRow: some View {
        Toggle(isOn: store.alwaysOnTopBinding(for: hud)) {
            SettingsRowLabel(
                title: "Always on top",
                subtitle: alwaysOnTopSubtitle
            )
        }
        .toggleStyle(.switch)
    }

    private var showOnAllSpacesRow: some View {
        Toggle(isOn: store.showOnAllSpacesBinding(for: hud)) {
            SettingsRowLabel(
                title: "Show on all Spaces",
                subtitle: "Appears on every Mission Control desktop AND inside dedicated fullscreen Spaces (e.g. fullscreen Safari / Zoom)."
            )
        }
        .toggleStyle(.switch)
    }

    // MARK: Per-HUD copy

    /// Footer copy depends on the HUD — different ones have different
    /// quirks worth surfacing in plain text under the card.
    private var footer: String? {
        switch hud.id {
        case "cc":
            return "CC HUD paints its own background — opacity affects the black plate behind the captions; text always stays fully legible regardless of the slider."
        case "main":
            return "Main HUD is the two-column captions chat. Opacity floors at 20% so it never becomes completely invisible."
        case "settings":
            return "Settings stays this window even when transparent. The slider floors at 40% so you can always read it — there's no other way back."
        default:
            return nil
        }
    }

    /// Subtitle on the opacity slider — keeps copy compact but useful.
    private var opacitySubtitle: String {
        switch hud.id {
        case "cc":
            return "Alpha of the background plate. Caption text stays opaque."
        default:
            return "Alpha applied to the window itself."
        }
    }

    /// Subtitle on the always-on-top toggle — describes WHAT "on top"
    /// means for this specific HUD (different levels for panels vs
    /// regular windows).
    private var alwaysOnTopSubtitle: String {
        switch hud.opacityStrategy {
        case .external, .selfPainted:
            // Panel-based HUDs — overlay level, above everything incl.
            // fullscreen apps.
            return "Floats above EVERYTHING including fullscreen apps."
        case .windowAlpha:
            // Regular SwiftUI windows — floating level, above other apps
            // but can be covered by fullscreen content.
            return "Floats above other apps. Fullscreen content can still cover it."
        }
    }
}

#Preview {
    WindowsSection()
        .environment(SettingsStore())
        .frame(width: 720, height: 800)
}
