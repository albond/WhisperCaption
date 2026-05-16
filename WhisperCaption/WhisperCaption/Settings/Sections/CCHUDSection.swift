import SwiftUI

/// All CC HUD-related settings in one place: window behaviour (opacity,
/// always-on-top, show-on-all-Spaces), per-display geometry (width /
/// height / bottom offset) and content colours (background, two caption
/// rows, translation row). Windows section handles only Main / Settings
/// HUD; Display section keeps the target-display picker.
struct CCHUDSection: View {

    @Environment(SettingsStore.self) private var store
    @Environment(CCHUDController.self) private var ccHUD
    @State private var displays: [DisplayInfo] = []
    private let descriptor = SettingsCategoryID.ccHUD.descriptor

    var body: some View {
        SectionShell(descriptor: descriptor) {

            // Window behaviour — same card the Windows section uses for
            // Main / Settings HUDs, just pinned to the CC HUD descriptor.
            WindowCard(hud: HUDDescriptor.ccHUD)

            // Per-display geometry + preview button.
            SettingsCard(
                title: "Size",
                footer: "Per-display width / height / bottom offset for the caption strip."
            ) {
                if displays.isEmpty {
                    Text("No displays detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(displays.enumerated()), id: \.element.id) { idx, d in
                            CCHudSizeRow(display: d)
                            if idx < displays.count - 1 {
                                SettingsRowDivider()
                            }
                        }
                    }

                    SettingsRowDivider()

                    HStack {
                        SettingsRowLabel(
                            title: "Preview",
                            subtitle: "Show the strip with two example replies so you can tune height, width, position, and colours."
                        )
                        Spacer()
                        HStack(spacing: 8) {
                            Button {
                                ccHUD.showDemo()
                            } label: {
                                Label("Show example", systemImage: "eye")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                ccHUD.dismiss()
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!ccHUD.isShown)
                        }
                    }
                }
            }

            // Colour pickers for the four user-facing surfaces.
            SettingsCard(
                title: "Colours",
                footer: "Background colour combines with the opacity slider above. Previous row text is dimmed automatically so the current line stands out — pick a colour, the view applies the dim factor."
            ) {
                colorRow(
                    title: "Background",
                    subtitle: "Plate behind the captions.",
                    color: Binding(
                        get: { store.ccBackgroundColor },
                        set: { store.ccBackgroundColor = $0 }
                    )
                )
                SettingsRowDivider()
                colorRow(
                    title: "Previous line",
                    subtitle: "Older caption row, rendered dimmer than the current line.",
                    color: Binding(
                        get: { store.ccPreviousLineColor },
                        set: { store.ccPreviousLineColor = $0 }
                    )
                )
                SettingsRowDivider()
                colorRow(
                    title: "Current line",
                    subtitle: "Latest caption row.",
                    color: Binding(
                        get: { store.ccCurrentLineColor },
                        set: { store.ccCurrentLineColor = $0 }
                    )
                )
                SettingsRowDivider()
                colorRow(
                    title: "Translation",
                    subtitle: "Translated text shown under each caption.",
                    color: Binding(
                        get: { store.ccTranslationColor },
                        set: { store.ccTranslationColor = $0 }
                    )
                )
            }
        }
        .onAppear { displays = Displays.all() }
    }

    private func colorRow(title: String, subtitle: String, color: Binding<Color>) -> some View {
        HStack {
            SettingsRowLabel(title: title, subtitle: subtitle)
            Spacer()
            ColorPicker("", selection: color, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 44)
        }
    }
}

/// Per-display geometry tuner — Width, Height, Bottom offset. Moved here
/// from DisplaySection so every CC HUD knob lives in one place.
private struct CCHudSizeRow: View {

    @Environment(SettingsStore.self) private var store
    let display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rowTitle)
                .font(.callout.weight(.semibold))

            sliderRow(
                title: "Width",
                value: Binding(
                    get: { store.ccHUDWidthFraction(forDisplayUUID: display.uuid) },
                    set: { store.setCCHUDWidthFraction($0, forDisplayUUID: display.uuid) }
                ),
                range: SettingsStore.ccHUDWidthFractionRange,
                trailing: "\(Int(store.ccHUDWidthFraction(forDisplayUUID: display.uuid) * 100))%"
            )

            sliderRow(
                title: "Height",
                value: Binding(
                    get: { store.ccHUDHeight(forDisplayUUID: display.uuid) },
                    set: { store.setCCHUDHeight($0, forDisplayUUID: display.uuid) }
                ),
                range: SettingsStore.ccHUDHeightRange,
                trailing: "\(Int(store.ccHUDHeight(forDisplayUUID: display.uuid)))pt"
            )

            sliderRow(
                title: "Bottom",
                value: Binding(
                    get: { store.ccHUDBottomOffset(forDisplayUUID: display.uuid) },
                    set: { store.setCCHUDBottomOffset($0, forDisplayUUID: display.uuid) }
                ),
                range: SettingsStore.ccHUDBottomOffsetRange,
                trailing: "\(Int(store.ccHUDBottomOffset(forDisplayUUID: display.uuid)))pt"
            )
        }
        .padding(.vertical, 4)
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, trailing: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.callout)
            Slider(value: value, in: range)
            Text(trailing)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    private var rowTitle: String {
        display.isMain ? "\(display.name) — main" : display.name
    }
}
