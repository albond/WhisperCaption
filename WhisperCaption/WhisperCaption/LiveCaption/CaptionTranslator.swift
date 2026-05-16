import Foundation
import OSLog
import Observation
import SwiftUI
import Translation

/// Auto-translates SYSTEM-side captions through Apple's on-device
/// Translation framework when the user has opted in via Settings →
/// Translation (or the top-level "Translation" menu).
///
/// Lives at app scope, alongside `CaptionStream` and `SettingsStore`.
/// The translation engine itself is driven by SwiftUI: Apple only
/// exposes a session through the `.translationTask` view modifier, so
/// `TranslationHostView` mounts one invisible View per source language
/// and hands us the session on each (re)configuration.
///
/// Why one session per source language (not source:nil auto-detect):
///   Passing `source: nil` causes Apple's framework to show a system
///   dialog — "The language could not be automatically detected" — when
///   it's unsure about the input. Using explicit source languages derived
///   from the active language selection avoids the dialog entirely and
///   produces better translations.
///
/// Lifecycle:
///   1. User flips Translation ON in Settings or the menu.
///      → `recomputeConfigurations()` builds one
///        `TranslationSession.Configuration(source: <lang>, target: <target>)`
///        for each source language in the active selection (excluding the
///        target itself, e.g. target→target would be useless).
///      → `TranslationHostView` renders one `TranslationPairView` per
///        entry; each mounts a `.translationTask` and calls our
///        `run(session:source:)` when the session opens.
///   2. `run(session:source:)` loops while not cancelled:
///        - Drains every caption of that source language needing
///          translation right now.
///        - Sleeps 250 ms when the queue is empty.
///   3. User changes target language → configurations recompute →
///      SwiftUI cancels old sessions, opens new ones with new target.
///   4. User changes language selection → configurations recompute →
///      sessions for removed source languages close; new ones open.
///   5. User toggles Translation OFF → `configurations` empties →
///      all sessions close; existing translations remain visible.
///
/// Skipped captions (never enqueued):
///   - mic side — translation is a "what the other side just said" feature;
///   - source language equals target — excluded from sessions entirely;
///   - finalized + already translated to current target — idempotent.
///
/// Interim (non-final) captions DO get translated, live, every poll.
/// The `inFlight` throttle caps us at one outstanding request per
/// caption ID, and we drop interim text below 4 visible characters.
@MainActor
@Observable
final class CaptionTranslator {

    @ObservationIgnored private let log = Log.CaptionTranslator

    @ObservationIgnored private weak var stream: CaptionStream?
    @ObservationIgnored private weak var settings: SettingsStore?

    /// One configuration per source language. The key is the source
    /// language; the value is `Configuration(source: <lang>, target: <target>)`.
    /// Empty means "Translation is off or no sessions needed".
    /// `TranslationHostView` observes this to mount/unmount `.translationTask`
    /// modifiers — one per entry — so each source language gets its own
    /// Apple session with an explicit source locale.
    private(set) var configurations: [Language: TranslationSession.Configuration] = [:]

    /// Caption IDs currently being translated (any session). Shared across
    /// all sessions so two sessions don't translate the same caption race.
    @ObservationIgnored private var inFlight: Set<UUID> = []

    /// Caption IDs whose translation Apple has refused (e.g. "language pair
    /// not supported on this device"). Cleared on target/selection change.
    @ObservationIgnored private var permanentlyFailed: Set<UUID> = []

    /// Caption IDs the user explicitly asked to translate from the Main HUD
    /// context menu, keyed by the source language they chose (or the source
    /// detected on the caption itself). Manual requests bypass every auto-
    /// pipeline filter — they always run, even for mic-side captions, even
    /// when auto-translation is OFF, even when the source language isn't in
    /// the user's active language selection. Entries are removed once the
    /// translation lands (or permanently fails).
    @ObservationIgnored private var pendingManual: [UUID: Language] = [:]

    init(stream: CaptionStream, settings: SettingsStore) {
        self.stream = stream
        self.settings = settings
        recomputeConfigurations()
        observeSettings()
    }

    // MARK: - Configuration

    /// Rebuilds `configurations` from current settings, selection, and any
    /// pending manual requests. Source languages = (auto pipeline's selection
    /// minus target) ∪ (manual queue's source languages minus target). The
    /// auto half contributes only when `translationEnabled` is on; manual
    /// entries always contribute. Each surviving entry becomes one
    /// `.translationTask` session in `TranslationHostView`.
    ///
    /// `permanentlyFailed` is intentionally NOT reset here: this rebuild
    /// runs on every manual request and on auto-pipeline toggles, but a
    /// caption that Apple refused once still won't translate. The reset
    /// belongs to the settings-observation callback below, where target /
    /// selection changes might legitimately resurrect a previously-failed
    /// caption.
    private func recomputeConfigurations() {
        guard let settings, let stream else {
            configurations = [:]
            return
        }

        let target = settings.translationTargetLanguage
        let targetLocale = Locale.Language(identifier: target.bcp47)

        var sourceLangs: Set<Language> = []

        if settings.translationEnabled {
            sourceLangs.formUnion(stream.languages.selectedLanguages.subtracting([target]))
        }

        // Manual entries always contribute their source language, regardless
        // of auto pipeline state.
        sourceLangs.formUnion(pendingManual.values)
        sourceLangs.remove(target) // target→target is never a session.

        var newConfigs: [Language: TranslationSession.Configuration] = [:]
        for lang in sourceLangs {
            newConfigs[lang] = TranslationSession.Configuration(
                source: Locale.Language(identifier: lang.bcp47),
                target: targetLocale
            )
        }
        configurations = newConfigs

        let sources = sourceLangs.map(\.rawValue).sorted().joined(separator: "+")
        let manualCount = pendingManual.count
        log.info("translation reconfigured: [\(sources, privacy: .public)] → \(target.rawValue, privacy: .public) (manual=\(manualCount))")
    }

    /// Re-arms after each fire; observes translation settings AND the active
    /// language selection (selection change → different source languages needed).
    private func observeSettings() {
        withObservationTracking { [weak self] in
            guard let self, let settings = self.settings else { return }
            _ = settings.translationEnabled
            _ = settings.translationTargetLanguage
            _ = self.stream?.languages.selectedLanguages
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.permanentlyFailed.removeAll()
                self?.recomputeConfigurations()
                self?.observeSettings()
            }
        }
    }

    // MARK: - Manual requests (Main HUD context menu)

    /// Enqueues a one-shot translation for `captionID` using `sourceLanguage`
    /// as the explicit source. Used by the Main HUD right-click "Translate"
    /// action. The request bypasses every auto-pipeline filter: it runs even
    /// for mic-side captions, when Translation is OFF, or when the source
    /// language isn't in the active selection.
    ///
    /// If a session for `sourceLanguage` isn't already mounted, a fresh
    /// configuration is added and `TranslationHostView` will mount the
    /// corresponding `.translationTask`. Re-translating an already-translated
    /// caption is a valid use case (target language changed since the last
    /// translation) — the old text stays visible until the new one lands.
    func requestManualTranslation(captionID: UUID, sourceLanguage: Language) {
        pendingManual[captionID] = sourceLanguage
        permanentlyFailed.remove(captionID)
        recomputeConfigurations()
    }

    // MARK: - Queue

    /// Source languages that currently have an active session, in a stable
    /// order so `ForEach` in the host view doesn't thrash on dict key sets.
    var sourcesNeedingTranslation: [Language] {
        configurations.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Captions that need translation by the given source-language session.
    /// Two paths feed the queue:
    ///
    ///   * **Manual** — user picked "Translate" in the bubble context menu.
    ///     Routes by the explicit source the user (or `caption.language`)
    ///     provided; bypasses all auto-pipeline filters (mic side, isFinal,
    ///     translation-enabled, language-selection membership).
    ///
    ///   * **Auto** — the CC HUD pipeline. Routes by `caption.language ==
    ///     source`, system side only, only while `translationEnabled` is on,
    ///     skip captions already translated to the current target.
    private func pending(for source: Language) -> [Caption] {
        guard let stream, let settings else { return [] }
        let target = settings.translationTargetLanguage

        return stream.captions.filter { cap in
            let trimmed = cap.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if inFlight.contains(cap.id) { return false }
            if permanentlyFailed.contains(cap.id) { return false }

            // Manual path wins outright when the user explicitly enqueued
            // this caption. The chosen source must match this session's
            // language; otherwise some OTHER source session owns the work.
            if let manualSource = pendingManual[cap.id] {
                return manualSource == source
            }

            // Auto pipeline.
            guard settings.translationEnabled else { return false }
            guard cap.source == .system else { return false }
            if !cap.isFinal && trimmed.count < Self.minInterimChars { return false }
            if cap.isFinal, cap.translation != nil, cap.translationLanguage == target {
                return false
            }
            guard let lang = cap.language else { return false }
            return lang == source
        }
    }

    /// Minimum interim text length before we bother translating. Short
    /// interim chunks produce unstable single-char results that flicker.
    private static let minInterimChars = 4

    // MARK: - Run loop

    /// Driven by a `.translationTask` modifier for one specific source
    /// language. Returns when the task is cancelled (configuration changed,
    /// session closed, or module unmounted).
    func run(session: TranslationSession, source: Language) async {
        guard let stream, let settings else { return }
        let target = settings.translationTargetLanguage

        log.info("session opened: \(source.rawValue, privacy: .public) → \(target.rawValue, privacy: .public)")

        while !Task.isCancelled {
            let work = pending(for: source)
            if work.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
                continue
            }
            for cap in work {
                if Task.isCancelled { return }
                // Bail if target changed — the session for the new target
                // will handle any remaining work.
                guard settings.translationTargetLanguage == target else { return }
                guard !inFlight.contains(cap.id) else { continue }
                inFlight.insert(cap.id)
                let wasManual = pendingManual[cap.id] != nil
                do {
                    let captureText = cap.text
                    let response = try await session.translate(captureText)
                    let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !translated.isEmpty {
                        // Hand the source text we actually translated back
                        // to the store. If the bubble's text changed while
                        // we were awaiting, `setTranslation` will drop the
                        // result and we'll re-translate next poll.
                        stream.setTranslation(translated, sourceText: captureText, language: target, forCaptionID: cap.id)
                    }
                    if wasManual {
                        pendingManual.removeValue(forKey: cap.id)
                    }
                } catch {
                    log.warning("translate failed for \(cap.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    permanentlyFailed.insert(cap.id)
                    if wasManual {
                        // Don't requeue forever — surface the failure and let
                        // the user retry via the menu (Re-translate clears
                        // permanentlyFailed before re-enqueueing).
                        pendingManual.removeValue(forKey: cap.id)
                    }
                }
                inFlight.remove(cap.id)
                if wasManual {
                    // Drop the source-language session if it's no longer
                    // serving auto OR any other manual request.
                    recomputeConfigurations()
                }
            }
        }

        log.info("session closed: \(source.rawValue, privacy: .public) → \(target.rawValue, privacy: .public)")
    }
}

// MARK: - Environment plumbing

/// Optional carrier so bubble-level views can call `requestManualTranslation`
/// without the full singleton being plumbed through every parent. The value
/// is set at the WindowGroup root from `WhisperCaptionApp`; views read it via
/// `@Environment(\.captionTranslator)`.
private struct CaptionTranslatorKey: EnvironmentKey {
    static let defaultValue: CaptionTranslator? = nil
}

extension EnvironmentValues {
    var captionTranslator: CaptionTranslator? {
        get { self[CaptionTranslatorKey.self] }
        set { self[CaptionTranslatorKey.self] = newValue }
    }
}
