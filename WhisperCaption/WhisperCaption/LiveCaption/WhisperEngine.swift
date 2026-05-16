import Foundation
import OSLog
import WhisperKit

/// Owns ONE WhisperKit pipeline and turns a stream of 16 kHz mono Float32 PCM
/// chunks into a stream of Caption updates.
///
/// Streaming strategy:
///   - We keep a rolling Float buffer of the "current phrase".
///   - Periodically we re-decode the whole buffer and emit an interim
///     Caption (re-using the same id, so the UI updates one bubble in place).
///     Per-model cadence, see `decodeStepSamples` / `maxPhraseSamples`.
///   - Three triggers finalize the bubble and start a new one:
///       * Silence: ~1 s of RMS-silence (energy-based VAD).
///       * Punctuation: an interim decode whose text already ends in
///         `.`/`?`/`!`/`…` and whose buffer is >= 1.5 s. Whisper places
///         sentence terminators reliably even on rapid-fire speech with
///         no audible pauses, so this gives us sentence-sized captions for
///         the streaming UX even before the max-length cap.
///       * Max length: see the per-model values below.
///     On finalize we drop only the audio we actually decoded; samples that
///     arrived in `phraseBuffer` AFTER the snapshot stay as the head of the
///     next phrase, so we don't lose the start of the next sentence.
///
/// One instance per source: `CaptionStream` owns one for the microphone
/// and one for system audio, so they decode in parallel.
enum WhisperEngineError: Error {
    case notReady
    case loadFailed(underlying: Error)
}

/// Which Whisper checkpoint to load.
///
/// `small` is fast (~500 MB) and fine for everyday speech; `medium`
/// (~1.5 GB) is markedly more accurate on technical jargon and non-
/// native accents. On Apple Silicon (M2 Pro and up) `medium` runs in
/// real time on the ANE without breaking a sweat.
nonisolated enum WhisperModel: String, Sendable, Codable, CaseIterable, Identifiable {
    case small
    case medium

    var id: String { rawValue }

    /// Subdirectory name within the WhisperKit model layout.
    var modelName: String {
        switch self {
        case .small:  return "openai_whisper-small"
        case .medium: return "openai_whisper-medium"
        }
    }

    /// Folder name for the tokenizer / config files (separate upstream repo).
    var tokenizerRepo: String {
        switch self {
        case .small:  return "whisper-small"
        case .medium: return "whisper-medium"
        }
    }

    /// Approximate on-disk size for UI hints.
    var displaySize: String {
        switch self {
        case .small:  return "~500 MB"
        case .medium: return "~1.5 GB"
        }
    }

    var displayName: String {
        switch self {
        case .small:  return "Whisper-small"
        case .medium: return "Whisper-medium"
        }
    }
}

actor WhisperEngine: TranscriptionEngine {

    static let supportedLanguages: [Language] = Language.allCases

    private let log = Log.WhisperEngine

    private let source: CaptionSource
    private let model: WhisperModel
    private let modelName: String      // resolved from model.modelName
    private let vocabularyHint: String
    /// User-configured local model folder. Required — no auto-download.
    private let modelFolder: URL
    /// User-configured tokenizer folder. Required when the chosen model
    /// doesn't carry tokenizer files alongside its weights.
    private let tokenizerFolder: URL?
    private weak var settings: LanguageSettings?

    /// Lazily-tokenized vocabulary hint, fed to Whisper as `promptTokens`.
    /// Computed once after the pipe loads and re-used on every decode.
    private var promptTokensCache: [Int]?

    private var pipe: WhisperKit?
    private var loadState: WhisperLoadState = .idle

    // Output stream of caption updates.
    nonisolated let captions: AsyncStream<Caption>
    private let captionContinuation: AsyncStream<Caption>.Continuation

    // Streaming buffer state.
    private static let sampleRate: Float = 16_000
    private static let silenceFinalizeSamples = Int(sampleRate * 1.0)   // 1 s of silence = end of phrase
    // Don't punctuation-finalize tiny fragments: wait until the buffer is
    // at least this long. Below this threshold a sentence-terminator is more
    // likely a transient Whisper artefact than a real end-of-thought.
    private static let minPunctuationFinalizeSamples = Int(sampleRate * 1.5)
    // Whisper hallucinates on tiny buffers (~0.3–0.7 s) — usually emitting
    // a single comma, period, or random word. Two guards:
    //   * silence-finalize is suppressed below `minDecodeSamples` (we drop
    //     the buffer instead of decoding garbage),
    //   * after a punctuation-finalize, anything shorter than `minTailSamples`
    //     left in the buffer is junk — discard it instead of carrying over.
    private static let minDecodeSamples = Int(sampleRate * 0.7)
    private static let minTailSamples   = Int(sampleRate * 0.3)

    // Per-model timing. Whisper internally pads input to its 30-second
    // window before running the AudioEncoder, so each `transcribe()` call
    // has a roughly constant wall-clock cost regardless of input length.
    // Measured on M2 Pro: ~200 ms for `small`, ~4.6 s for `medium`.
    //
    // If we re-decode every 1.2 s on `medium`, we generate work at 4× real
    // time and the buffer never drains — the phrase grows to `maxPhrase`
    // each time and Whisper hallucinates ("and", ",") because we keep
    // feeding it the same audio. So we slow down interim re-decodes for
    // the heavier model and let phrases run longer before force-finalize.
    private let decodeStepSamples: Int
    private let maxPhraseSamples: Int

    private var phraseBuffer: [Float] = []
    private var samplesSinceLastDecode = 0
    private var silenceRunSamples = 0
    private var currentCaptionId: UUID?
    private var phraseStartedAt: Date?
    private var decodeInFlight = false

    init(
        source: CaptionSource,
        model: WhisperModel,
        vocabularyHint: String = "",
        modelFolder: URL,
        tokenizerFolder: URL?,
        settings: LanguageSettings
    ) {
        self.source = source
        self.model = model
        self.modelName = model.modelName
        self.vocabularyHint = vocabularyHint
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
        self.settings = settings

        switch model {
        case .small:
            // Lightweight: ~200 ms decode → can comfortably re-decode every
            // 1.2 s and force-finalize at 7 s without falling behind.
            self.decodeStepSamples = Int(Self.sampleRate * 1.2)
            self.maxPhraseSamples  = Int(Self.sampleRate * 7)
        case .medium:
            // Heavy: ~4.6 s decode wall-clock per call on M2 Pro. Re-decoding
            // every 1.2 s would queue work faster than it drains; instead
            // we re-decode every 3.5 s and let phrases run up to 15 s so a
            // single decode at the cap completes within real time.
            self.decodeStepSamples = Int(Self.sampleRate * 3.5)
            self.maxPhraseSamples  = Int(Self.sampleRate * 15)
        }

        var localContinuation: AsyncStream<Caption>.Continuation!
        self.captions = AsyncStream(Caption.self, bufferingPolicy: .unbounded) { c in
            localContinuation = c
        }
        self.captionContinuation = localContinuation
    }

    // MARK: - Lifecycle

    func loadStateSnapshot() -> WhisperLoadState { loadState }

    /// Load the model strictly from the user-supplied local folder. We do
    /// NOT auto-download — partial-download corruption is reproducible and
    /// the user owns model management here.
    func prepare() async {
        guard pipe == nil else { return }

        loadState = .loading(progress: 0, message: "Loading \(modelName)…")

        let folderPath = modelFolder.path
        guard Self.modelLooksComplete(at: folderPath) else {
            let msg = "Model folder is missing required files. Expected a WhisperKit-compatible layout under \(folderPath)."
            loadState = .failed(msg)
            log.error("\(msg, privacy: .public)")
            return
        }

        let tokenizerURL = tokenizerFolder
        if let url = tokenizerURL, !Self.tokenizerLooksComplete(at: url.path) {
            let msg = "Tokenizer folder is missing required files (tokenizer.json / tokenizer_config.json / config.json) at \(url.path)."
            loadState = .failed(msg)
            log.error("\(msg, privacy: .public)")
            return
        }

        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: folderPath,
            tokenizerFolder: tokenizerURL,
            download: false
        )

        do {
            let pipe = try await WhisperKit(config)
            self.pipe = pipe
            // Encode the vocabulary hint once so we can re-use the tokens
            // on every subsequent decode.
            tokenizeVocabularyHint(using: pipe)
            loadState = .ready
            log.info("whisper engine ready (\(self.modelName, privacy: .public)) for \(self.source.rawValue, privacy: .public); promptTokens=\(self.promptTokensCache?.count ?? 0)")
        } catch {
            loadState = .failed("Failed to load \(modelName): \(error.localizedDescription)")
            log.error("whisper load failed: \(error.localizedDescription)")
        }
    }

    /// Best-effort encode of the vocabulary hint into Whisper token ids.
    /// If the WhisperKit tokenizer surface area changes between versions,
    /// we silently fall back to no prompt — Whisper still works, just
    /// without the bias. We never want this to crash startup.
    private func tokenizeVocabularyHint(using pipe: WhisperKit) {
        let hint = vocabularyHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hint.isEmpty else {
            promptTokensCache = nil
            return
        }
        guard let tokenizer = pipe.tokenizer else {
            log.notice("vocabulary hint set but tokenizer is nil; skipping prompt tokens")
            promptTokensCache = nil
            return
        }
        let tokens = tokenizer.encode(text: " " + hint)
        // Guard against absurd lengths — long hints push out useful context.
        let maxPromptTokens = 224
        promptTokensCache = Array(tokens.prefix(maxPromptTokens))
    }

    /// Heuristic: every required `.mlmodelc/weights/weight.bin` exists and is non-empty.
    private static func modelLooksComplete(at folder: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { return false }
        let required = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        for component in required {
            let weight = "\(folder)/\(component).mlmodelc/weights/weight.bin"
            guard fm.fileExists(atPath: weight) else { return false }
            if let attrs = try? fm.attributesOfItem(atPath: weight),
               let size = attrs[.size] as? NSNumber, size.intValue > 0 {
                continue
            }
            return false
        }
        return true
    }

    /// Bare minimum the tokenizer loader walks looking for.
    private static func tokenizerLooksComplete(at folder: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { return false }
        let required = ["tokenizer.json", "tokenizer_config.json", "config.json"]
        return required.allSatisfy { fm.fileExists(atPath: "\(folder)/\($0)") }
    }

    /// Reset internal phrase state without unloading the model. Called on session stop.
    func reset() {
        phraseBuffer.removeAll(keepingCapacity: false)
        samplesSinceLastDecode = 0
        silenceRunSamples = 0
        currentCaptionId = nil
        phraseStartedAt = nil
    }

    func close() {
        captionContinuation.finish()
    }

    // MARK: - Streaming

    // VAD threshold. Voice processing in some macOS versions attenuates
    // speech significantly, so we keep this low. Drop further if even loud
    // speech looks silent in the logs.
    private static let silenceRMS: Float = 0.001
    // First-call-only diagnostic state.
    private var firstChunkLogged = false
    private var maxRMSObserved: Float = 0
    private var ingestCount: Int = 0

    /// Feed a chunk of 16 kHz mono Float32 samples.
    func ingest(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }

        let energy = rms(samples)
        ingestCount += 1
        if energy > maxRMSObserved { maxRMSObserved = energy }

        if !firstChunkLogged {
            firstChunkLogged = true
            log.info("ingest first chunk: source=\(self.source.rawValue, privacy: .public) samples=\(samples.count) rms=\(energy)")
        }
        // Periodically dump RMS so we can confirm audio is actually flowing.
        if ingestCount % 50 == 0 {
            log.info("ingest tick: source=\(self.source.rawValue, privacy: .public) count=\(self.ingestCount) maxRMS=\(self.maxRMSObserved) bufSec=\(Float(self.phraseBuffer.count) / Self.sampleRate)")
        }

        let isSilent = energy < Self.silenceRMS

        if isSilent {
            silenceRunSamples += samples.count
        } else {
            silenceRunSamples = 0
        }

        if phraseBuffer.isEmpty && isSilent {
            return
        }

        if phraseStartedAt == nil {
            phraseStartedAt = Date()
        }
        phraseBuffer.append(contentsOf: samples)
        samplesSinceLastDecode += samples.count

        if !phraseBuffer.isEmpty && silenceRunSamples >= Self.silenceFinalizeSamples {
            // Whisper on < ~0.7 s of audio is a hallucination machine. If
            // the speaker only produced a tiny blip before going silent,
            // drop the buffer instead of asking the model to invent text.
            if phraseBuffer.count < Self.minDecodeSamples {
                log.info("silence on tiny buffer: dropping, source=\(self.source.rawValue, privacy: .public) bufSec=\(Float(self.phraseBuffer.count) / Self.sampleRate)")
                phraseBuffer.removeAll(keepingCapacity: false)
                samplesSinceLastDecode = 0
                silenceRunSamples = 0
                currentCaptionId = nil
                phraseStartedAt = nil
                return
            }
            log.info("decode trigger: SILENCE finalize, source=\(self.source.rawValue, privacy: .public) bufSec=\(Float(self.phraseBuffer.count) / Self.sampleRate)")
            await decode(finalize: true)
            return
        }

        if phraseBuffer.count >= self.maxPhraseSamples {
            log.info("decode trigger: MAX cap, source=\(self.source.rawValue, privacy: .public)")
            await decode(finalize: true)
            return
        }

        if samplesSinceLastDecode >= self.decodeStepSamples {
            log.info("decode trigger: STEP, source=\(self.source.rawValue, privacy: .public) bufSec=\(Float(self.phraseBuffer.count) / Self.sampleRate)")
            await decode(finalize: false)
        }
    }

    // MARK: - Decoding

    private func decode(finalize: Bool) async {
        guard let pipe else { return }
        guard !decodeInFlight else { return }   // skip if previous decode still running
        guard !phraseBuffer.isEmpty else { return }

        decodeInFlight = true
        defer { decodeInFlight = false }

        let snapshot = phraseBuffer
        let startedAt = phraseStartedAt ?? Date()
        let id = currentCaptionId ?? UUID()
        if currentCaptionId == nil { currentCaptionId = id }

        let forced = await settings?.forcedWhisperLanguage
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: forced,
            temperature: 0.0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: forced == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokensCache,
            chunkingStrategy: nil
        )

        samplesSinceLastDecode = 0

        let bufSec = Float(snapshot.count) / Self.sampleRate
        log.info("decode start: source=\(self.source.rawValue, privacy: .public) bufSec=\(bufSec) finalize=\(finalize)")

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioArray: snapshot, decodeOptions: options)
        } catch {
            log.error("transcribe failed: \(error.localizedDescription)")
            return
        }

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedRaw = results.first?.language ?? ""
        let detected = Language(rawValue: detectedRaw)

        log.info("decode result: source=\(self.source.rawValue, privacy: .public) lang=\(detectedRaw, privacy: .public) text=\"\(text, privacy: .public)\"")

        let accepted = await settings?.accepts(detected) ?? true
        if !text.isEmpty && !accepted {
            log.info("caption dropped (lang \(detectedRaw, privacy: .public) not in selected pool)")
        }

        // Soft-finalize on a sentence terminator that the model already
        // produced. Skip if the caller already requested a hard finalize
        // (silence / max-cap) — avoids double work — and skip if the buffer
        // is too short for the punctuation to be a real end-of-thought.
        let endsSentence = !finalize
            && Self.endsWithSentenceTerminator(text)
            && snapshot.count >= Self.minPunctuationFinalizeSamples
        let effectiveFinalize = finalize || endsSentence

        // Whisper sometimes returns just punctuation (",", ".", "...") on
        // short or noisy buffers. Treat as junk: don't show the bubble, but
        // still run the cleanup below so the buffer doesn't keep accumulating.
        let hasContent = text.contains { $0.isLetter || $0.isNumber }
        let shouldEmit = !text.isEmpty && accepted && hasContent
        if !text.isEmpty && accepted && !hasContent {
            log.info("caption dropped (no letters/digits): \"\(text, privacy: .public)\"")
        }

        if shouldEmit {
            let caption = Caption(
                id: id,
                source: source,
                text: text,
                language: detected,
                isFinal: effectiveFinalize,
                startedAt: startedAt,
                updatedAt: Date()
            )
            captionContinuation.yield(caption)
        }

        if effectiveFinalize {
            // Consume only what we decoded; keep any samples that arrived
            // AFTER the snapshot as the head of the next phrase. Otherwise
            // the start of the next sentence (which the speaker may have
            // begun while we were decoding) gets dropped on the floor.
            let consumed = min(snapshot.count, phraseBuffer.count)
            phraseBuffer.removeFirst(consumed)
            // A tail shorter than ~0.3 s is just residual noise around the
            // sentence boundary; carrying it over only feeds Whisper more
            // hallucination fuel on the next decode.
            if phraseBuffer.count < Self.minTailSamples {
                phraseBuffer.removeAll(keepingCapacity: false)
            }
            samplesSinceLastDecode = 0
            silenceRunSamples = 0
            currentCaptionId = nil
            phraseStartedAt = phraseBuffer.isEmpty ? nil : Date()
            let reason = finalize ? "external" : "punctuation"
            log.info("finalize: source=\(self.source.rawValue, privacy: .public) reason=\(reason, privacy: .public) consumed=\(consumed) tailSec=\(Float(self.phraseBuffer.count) / Self.sampleRate)")
        }
    }

    /// Whisper places `.` / `?` / `!` / `…` reliably even on fast speech.
    /// We detect a sentence end so the streaming UI can flush the bubble
    /// without waiting for an audible pause.
    private nonisolated static func endsWithSentenceTerminator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }

    private nonisolated func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
