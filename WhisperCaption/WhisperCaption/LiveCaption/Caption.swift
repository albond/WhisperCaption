import Foundation

/// Models for live captions. A `Caption` is a single bubble in the UI: text +
/// source (mic / system) + detected language + finality. Streaming updates
/// re-emit the same id with new text until it's finalized.

nonisolated enum CaptionSource: String, Sendable, Hashable, Codable {
    case microphone
    case system
}

/// Languages supported across the engine surface. The case set covers the
/// union of WhisperKit (≈99), ElevenLabs Scribe v2 (≈99), and Deepgram
/// Nova-3 (≈34) documented support. Raw value is ISO 639-1 wherever a
/// 1-letter code exists; one exception (`jw`) follows Whisper's tokenizer
/// table, which uses the legacy `jw` rather than the modern `jv`.
///
/// `iso639_3` is provided for cloud engines (ElevenLabs Scribe v2) that
/// take 3-letter codes. `displayName` is shown in the picker.
///
/// Engines declare which of these they accept via their static
/// `supportedLanguages` — the Speech Recognition section surfaces a
/// warning chip when the user's selection contains entries the active
/// engine can't honour.
nonisolated enum Language: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case af, am, ar
    case `as` = "as"
    case az
    case ba, be, bg, bn, bo, br, bs
    case ca, cs, cy
    case da, de
    case el, en, es, et, eu
    case fa, fi, fo, fr
    case gl, gu
    case ha, he, hi, hr, ht, hu, hy
    case id
    case `is` = "is"
    case it
    case ja
    case jw         // Whisper's legacy code for Javanese (ISO 639-3 "jav")
    case ka, kk, km, kn, ko
    case la, lb, ln, lo, lt, lv
    case mg, mi, mk, ml, mn, mr, ms, mt, my
    case ne, nl, nn, no
    case oc
    case pa, pl, ps, pt
    case ro, ru
    case sa, sd, si, sk, sl, sn, so, sq, sr, su, sv, sw
    case ta, te, tg, th, tk, tl, tr, tt
    case uk, ur, uz
    case vi
    case yi, yo
    case zh

    var id: String { rawValue }

    /// Human-friendly label, used in pickers and chips.
    var displayName: String { Self.metadata[self]?.name ?? rawValue.uppercased() }

    /// ISO 639-3 three-letter code, used by ElevenLabs Scribe v2 for the
    /// `language_code` parameter. Falls back to the 2-letter raw value if
    /// a 3-letter mapping isn't registered (won't happen in practice — the
    /// metadata table covers every case).
    var iso639_3: String { Self.metadata[self]?.iso3 ?? rawValue }

    /// 2-letter code used by Whisper (`DecodingOptions.language`) and
    /// Deepgram. Matches the raw value, which equals Whisper's tokenizer
    /// entry (including the legacy `jw` for Javanese).
    var whisperCode: String { rawValue }

    /// BCP-47 identifier for `Locale.Language(identifier:)`, used by the
    /// Apple Translation framework. We hand it the 2-letter code, with one
    /// remap: Whisper's `jw` becomes BCP-47 `jv` (the modern tag Apple
    /// expects). Apple Translation supports far fewer languages than Whisper
    /// transcribes — un-mappable pairs fail at session-open time and surface
    /// in `CaptionTranslator.permanentlyFailed`.
    var bcp47: String {
        switch self {
        case .jw: return "jv"
        default:  return rawValue
        }
    }

    /// Short uppercase badge text for compact UI chips.
    var badge: String { rawValue.uppercased() }

    /// Single source of truth for English name + ISO 639-3 code, keyed by
    /// case. A flat table beats a 200-arm switch — and adding a language
    /// is one row, not five edits in five different methods.
    private static let metadata: [Self: (name: String, iso3: String)] = [
        .af: ("Afrikaans", "afr"),
        .am: ("Amharic", "amh"),
        .ar: ("Arabic", "ara"),
        .as: ("Assamese", "asm"),
        .az: ("Azerbaijani", "aze"),
        .ba: ("Bashkir", "bak"),
        .be: ("Belarusian", "bel"),
        .bg: ("Bulgarian", "bul"),
        .bn: ("Bengali", "ben"),
        .bo: ("Tibetan", "bod"),
        .br: ("Breton", "bre"),
        .bs: ("Bosnian", "bos"),
        .ca: ("Catalan", "cat"),
        .cs: ("Czech", "ces"),
        .cy: ("Welsh", "cym"),
        .da: ("Danish", "dan"),
        .de: ("German", "deu"),
        .el: ("Greek", "ell"),
        .en: ("English", "eng"),
        .es: ("Spanish", "spa"),
        .et: ("Estonian", "est"),
        .eu: ("Basque", "eus"),
        .fa: ("Persian", "fas"),
        .fi: ("Finnish", "fin"),
        .fo: ("Faroese", "fao"),
        .fr: ("French", "fra"),
        .gl: ("Galician", "glg"),
        .gu: ("Gujarati", "guj"),
        .ha: ("Hausa", "hau"),
        .he: ("Hebrew", "heb"),
        .hi: ("Hindi", "hin"),
        .hr: ("Croatian", "hrv"),
        .ht: ("Haitian Creole", "hat"),
        .hu: ("Hungarian", "hun"),
        .hy: ("Armenian", "hye"),
        .id: ("Indonesian", "ind"),
        .is: ("Icelandic", "isl"),
        .it: ("Italian", "ita"),
        .ja: ("Japanese", "jpn"),
        .jw: ("Javanese", "jav"),
        .ka: ("Georgian", "kat"),
        .kk: ("Kazakh", "kaz"),
        .km: ("Khmer", "khm"),
        .kn: ("Kannada", "kan"),
        .ko: ("Korean", "kor"),
        .la: ("Latin", "lat"),
        .lb: ("Luxembourgish", "ltz"),
        .ln: ("Lingala", "lin"),
        .lo: ("Lao", "lao"),
        .lt: ("Lithuanian", "lit"),
        .lv: ("Latvian", "lav"),
        .mg: ("Malagasy", "mlg"),
        .mi: ("Maori", "mri"),
        .mk: ("Macedonian", "mkd"),
        .ml: ("Malayalam", "mal"),
        .mn: ("Mongolian", "mon"),
        .mr: ("Marathi", "mar"),
        .ms: ("Malay", "msa"),
        .mt: ("Maltese", "mlt"),
        .my: ("Burmese", "mya"),
        .ne: ("Nepali", "nep"),
        .nl: ("Dutch", "nld"),
        .nn: ("Norwegian Nynorsk", "nno"),
        .no: ("Norwegian", "nor"),
        .oc: ("Occitan", "oci"),
        .pa: ("Punjabi", "pan"),
        .pl: ("Polish", "pol"),
        .ps: ("Pashto", "pus"),
        .pt: ("Portuguese", "por"),
        .ro: ("Romanian", "ron"),
        .ru: ("Russian", "rus"),
        .sa: ("Sanskrit", "san"),
        .sd: ("Sindhi", "snd"),
        .si: ("Sinhala", "sin"),
        .sk: ("Slovak", "slk"),
        .sl: ("Slovenian", "slv"),
        .sn: ("Shona", "sna"),
        .so: ("Somali", "som"),
        .sq: ("Albanian", "sqi"),
        .sr: ("Serbian", "srp"),
        .su: ("Sundanese", "sun"),
        .sv: ("Swedish", "swe"),
        .sw: ("Swahili", "swa"),
        .ta: ("Tamil", "tam"),
        .te: ("Telugu", "tel"),
        .tg: ("Tajik", "tgk"),
        .th: ("Thai", "tha"),
        .tk: ("Turkmen", "tuk"),
        .tl: ("Tagalog", "tgl"),
        .tr: ("Turkish", "tur"),
        .tt: ("Tatar", "tat"),
        .uk: ("Ukrainian", "ukr"),
        .ur: ("Urdu", "urd"),
        .uz: ("Uzbek", "uzb"),
        .vi: ("Vietnamese", "vie"),
        .yi: ("Yiddish", "yid"),
        .yo: ("Yoruba", "yor"),
        .zh: ("Chinese", "zho"),
    ]
}

nonisolated struct Caption: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let source: CaptionSource
    var text: String
    var language: Language?     // nil = couldn't classify or outside selected pool
    var isFinal: Bool
    var startedAt: Date
    var updatedAt: Date
    /// File name (no path) under the session's images/ folder. Loading happens through ChatImageStore.
    var imageFilename: String?

    /// Translated text in `translationLanguage`, or nil if not translated.
    /// Populated by `CaptionTranslator` when Translation mode is on. We
    /// store it here (not in a side-table) so it round-trips through the
    /// chat-history JSON without an extra file format.
    var translation: String?
    /// Target language of `translation`. Lets the renderer skip stale
    /// translations after the user changes the target language — and lets
    /// the translator re-translate without losing the previous result
    /// until the new one lands.
    var translationLanguage: Language?

    init(
        id: UUID = UUID(),
        source: CaptionSource,
        text: String,
        language: Language? = nil,
        isFinal: Bool = false,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        imageFilename: String? = nil,
        translation: String? = nil,
        translationLanguage: Language? = nil
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.language = language
        self.isFinal = isFinal
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.imageFilename = imageFilename
        self.translation = translation
        self.translationLanguage = translationLanguage
    }

    // Codable: `imageFilename` is plain text, included in JSON.
    private enum CodingKeys: String, CodingKey {
        case id, source, text, language, isFinal, startedAt, updatedAt
        case imageFilename
        case translation, translationLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self,        forKey: .id)
        self.source    = try c.decode(CaptionSource.self, forKey: .source)
        self.text      = try c.decode(String.self,      forKey: .text)
        self.language  = try c.decodeIfPresent(Language.self, forKey: .language)
        self.isFinal   = try c.decode(Bool.self,        forKey: .isFinal)
        self.startedAt = try c.decode(Date.self,        forKey: .startedAt)
        self.updatedAt = try c.decode(Date.self,        forKey: .updatedAt)
        self.imageFilename = try c.decodeIfPresent(String.self, forKey: .imageFilename)
        // decodeIfPresent so old chat JSONs (no translation fields) still load.
        self.translation         = try c.decodeIfPresent(String.self,   forKey: .translation)
        self.translationLanguage = try c.decodeIfPresent(Language.self, forKey: .translationLanguage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                forKey: .id)
        try c.encode(source,            forKey: .source)
        try c.encode(text,              forKey: .text)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(isFinal,           forKey: .isFinal)
        try c.encode(startedAt,         forKey: .startedAt)
        try c.encode(updatedAt,         forKey: .updatedAt)
        try c.encodeIfPresent(imageFilename,       forKey: .imageFilename)
        try c.encodeIfPresent(translation,         forKey: .translation)
        try c.encodeIfPresent(translationLanguage, forKey: .translationLanguage)
    }
}
