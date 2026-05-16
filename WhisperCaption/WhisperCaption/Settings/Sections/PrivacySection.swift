import SwiftUI

/// Audio-input switch + screen-capture invisibility. Per-window opacity
/// and on-top flags live in `Windows`; `Hide from screen capture` is a
/// privacy toggle that applies to every window the app owns, which is
/// why it sits here.
struct PrivacySection: View {

    @Environment(SettingsStore.self) private var store
    private let descriptor = SettingsCategoryID.privacy.descriptor

    var body: some View {
        @Bindable var store = store

        SectionShell(descriptor: descriptor) {
            SettingsCard(
                title: "Audio inputs",
                footer: "Off = transcribe only system audio (the other side of the call). Frees the Apple Neural Engine from running two pipelines at once — noticeably faster on the `medium` Whisper model. Applies on next Start."
            ) {
                Toggle(isOn: $store.captureMicrophone) {
                    SettingsRowLabel(
                        title: "Capture microphone",
                        subtitle: "When off, the app only transcribes what macOS is playing."
                    )
                }
                .toggleStyle(.switch)
            }

            SettingsCard(
                title: "Screen capture",
                footer: "Single switch that applies to ALL windows. Compositor-level filtering — windows are not rendered as black to other apps, they're not there at all."
            ) {
                Toggle(isOn: $store.windowsHiddenFromCapture) {
                    SettingsRowLabel(
                        title: "Hide from screen capture",
                        subtitle: "Invisible to Zoom, Teams, Webex, OBS, ScreenCaptureKit, and the system screenshot tool."
                    )
                }
                .toggleStyle(.switch)
            }
        }
    }
}

#Preview {
    PrivacySection()
        .environment(SettingsStore())
        .frame(width: 720, height: 700)
}
