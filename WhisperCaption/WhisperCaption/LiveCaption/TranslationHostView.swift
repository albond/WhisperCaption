import SwiftUI
import Translation

/// Invisible bridge between `CaptionTranslator` and Apple's Translation
/// framework. Apple only exposes a `TranslationSession` through the
/// `.translationTask(_:action:)` SwiftUI modifier — there's no programmatic
/// constructor — so this view mounts one modifier per source language.
///
/// Why one sub-view per source language:
///   `CaptionTranslator.configurations` maps each source language to an
///   explicit `TranslationSession.Configuration(source: <lang>, target: <target>)`.
///   Passing an explicit source prevents Apple's framework from showing the
///   "The language could not be automatically detected" system dialog, which
///   appears whenever `source: nil` auto-detection fails. Each
///   `TranslationPairView` hosts exactly one `.translationTask` for one
///   (source, target) pair.
///
/// Mounted inside the main window so translation continues even when the
/// CC HUD is hidden — transcripts get translations saved before the user
/// ever shows the HUD.
struct TranslationHostView: View {
    var translator: CaptionTranslator

    var body: some View {
        // Stack one pair-view per source language. ForEach reacts to
        // `sourcesNeedingTranslation` changes: when the user switches
        // preset or target language, old sessions close and new ones open.
        ZStack {
            ForEach(translator.sourcesNeedingTranslation, id: \.self) { source in
                TranslationPairView(translator: translator, source: source)
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Per-source-language session view

/// Hosts a single `.translationTask` for one (source → target) pair.
/// Kept as a separate view so SwiftUI can independently manage the
/// session lifecycle: destroying the view cancels its task cleanly.
private struct TranslationPairView: View {
    var translator: CaptionTranslator
    let source: Language

    var body: some View {
        Color.clear
            .translationTask(translator.configurations[source]) { session in
                await translator.run(session: session, source: source)
            }
    }
}
