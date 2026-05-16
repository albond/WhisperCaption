import Foundation
import Observation

/// User-toggleable set of expected languages. Persisted to UserDefaults.
///
/// How this maps to engines:
///   - 0 selected: fall back to engine default / auto-detect
///   - 1 selected: pass that one as the locked decoding language
///   - 2+ selected: enable auto-detect, then filter results by detected
///     language to reject anything outside the pool
///
/// No fixed presets — the supported set comes from the currently-active
/// `TranscriptionEngine.supportedLanguages`. The UI can warn when a user's
/// selection doesn't fit an engine (e.g. `uk` on Deepgram Nova-3 multilingual).
@Observable
final class LanguageSettings {

    private let defaultsKey = "WhisperCaption.LanguageSettings.selected"

    /// Subset of languages user wants captioned. Order is irrelevant.
    var selectedLanguages: Set<Language> {
        didSet {
            persist()
        }
    }

    init() {
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [String] ?? []
        let parsed = stored.compactMap(Language.init(rawValue:))
        if parsed.isEmpty {
            // No persisted choice yet — default to English-only. Users can
            // expand from Settings; defaulting to one locked language is
            // cheaper and more accurate than auto-detect on first launch.
            self.selectedLanguages = [.en]
        } else {
            self.selectedLanguages = Set(parsed)
        }
    }

    /// Language to pass to Whisper's `DecodingOptions.language`.
    /// Returns nil when the user has selected ≠ 1 language (auto-detect mode).
    var forcedWhisperLanguage: String? {
        guard selectedLanguages.count == 1, let only = selectedLanguages.first else { return nil }
        return only.whisperCode
    }

    /// Whether `lang` (as detected by the engine) is allowed to surface in the UI.
    func accepts(_ lang: Language?) -> Bool {
        guard let lang else { return true }     // unknown → don't filter
        return selectedLanguages.contains(lang)
    }

    /// Languages selected by the user but not supported by `engineLanguages`.
    /// Used by the UI to display a warning chip.
    func unsupported(by engineLanguages: [Language]) -> Set<Language> {
        let allowed = Set(engineLanguages)
        return selectedLanguages.subtracting(allowed)
    }

    private func persist() {
        let raw = selectedLanguages.map(\.rawValue).sorted()
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }
}
