import SwiftUI

/// Bubble formatting — three knobs that normalise the wildly different
/// per-engine output cadences (Whisper short, ElevenLabs huge, Nova-3
/// middle) into a single user-controlled shape.
///
/// All controls feed `BubbleSplitter` inside `CaptionStream`. No
/// engine-specific logic here; the splitter is applied uniformly across
/// every transcription engine.
struct BubblesSection: View {

    @Environment(SettingsStore.self) private var store
    private let descriptor = SettingsCategoryID.bubbles.descriptor

    var body: some View {
        @Bindable var store = store

        SectionShell(descriptor: descriptor) {

            SettingsCard(
                title: "Max bubble length",
                footer: "When an in-flight bubble grows past this many characters the splitter cuts it and the tail continues in a new bubble. Lower = more, smaller bubbles; higher = fewer, longer bubbles. ElevenLabs benefits most from a lower value; Whisper rarely hits this cap."
            ) {
                HStack(spacing: 12) {
                    SettingsRowLabel(
                        title: "Maximum characters",
                        subtitle: "Cap for one bubble. Cut happens at the nearest sentence or word boundary, never mid-word."
                    )
                    Spacer(minLength: 12)
                    Slider(
                        value: Binding(
                            get: { Double(store.bubbleMaxChars) },
                            set: { store.bubbleMaxChars = Int($0) }
                        ),
                        in: Double(SettingsStore.bubbleMaxCharsRange.lowerBound)
                            ... Double(SettingsStore.bubbleMaxCharsRange.upperBound),
                        step: 10
                    )
                    .frame(maxWidth: 240)
                    Text("\(store.bubbleMaxChars)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                        .contentTransition(.numericText())
                }
            }

            SettingsCard(
                title: "Silence break",
                footer: "If an in-flight bubble sees no new partials for this long it's forcibly finalised. Useful when an engine sits on an utterance too long (Whisper waiting for its own silence detect, ElevenLabs hugging a long pause). Set lower for snappier breaks, higher to let natural pauses through."
            ) {
                HStack(spacing: 12) {
                    SettingsRowLabel(
                        title: "Idle timeout",
                        subtitle: "Seconds of inactivity before the current bubble is closed."
                    )
                    Spacer(minLength: 12)
                    Slider(
                        value: $store.bubbleSilenceBreakSec,
                        in: SettingsStore.bubbleSilenceBreakRange,
                        step: 0.1
                    )
                    .frame(maxWidth: 240)
                    Text(String(format: "%.1f s", store.bubbleSilenceBreakSec))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                        .contentTransition(.numericText())
                }
            }

            SettingsCard(
                title: "Cutting strategy",
                footer: "On: when the bubble overflows the splitter prefers cutting at `. ? ! …` within the last ~30% of the cap; if no sentence terminator is in range, falls back to the nearest space. Off: cuts at the last space only. In both modes mid-word cuts are avoided unless the word is longer than the cap on its own."
            ) {
                Toggle(isOn: $store.bubbleSentenceAware) {
                    SettingsRowLabel(
                        title: "Prefer sentence boundaries",
                        subtitle: store.bubbleSentenceAware
                            ? "Splitter looks for end-of-sentence punctuation first."
                            : "Splitter goes straight to whitespace cuts."
                    )
                }
                .toggleStyle(.switch)
            }

            SettingsCard(
                title: "Text size",
                footer: "Font size for caption text in the Main HUD chat. Translation rows render one point smaller so the original / translation hierarchy stays readable at any size. CC HUD has its own auto-fit ladder and isn't affected."
            ) {
                HStack(spacing: 12) {
                    SettingsRowLabel(
                        title: "Bubble font size",
                        subtitle: "Caption text in points. Default 13 matches SwiftUI's body size."
                    )
                    Spacer(minLength: 12)
                    Slider(
                        value: $store.bubbleFontSize,
                        in: SettingsStore.bubbleFontSizeRange,
                        step: 1
                    )
                    .frame(maxWidth: 240)
                    Text("\(Int(store.bubbleFontSize)) pt")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                        .contentTransition(.numericText())
                }
            }
        }
    }
}
