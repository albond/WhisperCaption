import SwiftUI

/// Settings page for the auto-translation feature: master toggle +
/// target language picker. Uses Apple's on-device Translation framework,
/// so there's no API key, no cost, and no network — just a one-time
/// per-pair language model download macOS prompts for on first use.
///
/// Scope: translation applies to the **CC HUD only**. The system-side
/// chat column in the Main HUD still shows captions in the original
/// language. Mic captions are never translated.
struct TranslationSection: View {

    @Environment(SettingsStore.self) private var store
    private let descriptor = SettingsCategoryID.translation.descriptor

    var body: some View {
        @Bindable var store = store

        SectionShell(descriptor: descriptor) {

            SettingsCard(
                title: "Auto-translate captions",
                footer: "Translation applies to the CC HUD only. The Main HUD's system column shows the original language. Uses Apple's on-device Translation framework — free, offline, ~50 ms. macOS may prompt to download a language pair the first time it's used."
            ) {
                Toggle(isOn: $store.translationEnabled) {
                    SettingsRowLabel(
                        title: "Enable translation",
                        subtitle: store.translationEnabled
                            ? "On — system captions translate to \(store.translationTargetLanguage.displayName)."
                            : "Off — captions display in their original language only."
                    )
                }
                .toggleStyle(.switch)
            }

            SettingsCard(
                title: "Target language",
                footer: "What language to translate into. Translations are saved with the chat history, so transcripts remain bilingual after the session."
            ) {
                HStack {
                    SettingsRowLabel(
                        title: "Translate into",
                        subtitle: "Apple's framework downloads language pairs on demand the first time you need one."
                    )
                    Spacer()
                    Picker("", selection: $store.translationTargetLanguage) {
                        ForEach(Language.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!store.translationEnabled)
                }
            }
        }
    }
}
