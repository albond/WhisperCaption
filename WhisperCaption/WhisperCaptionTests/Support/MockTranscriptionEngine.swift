import Foundation
@testable import WhisperCaption

/// Test-controllable conformance of `TranscriptionEngine` that emits
/// scripted captions instead of doing any speech recognition. Used by
/// every test that needs to drive `CaptionStream` or its consumers
/// without paying for real model loading or network traffic.
///
/// Drive it from tests:
///   * `emit(_:)` yields a caption into the AsyncStream the engine
///     exposes. Pumps in `CaptionStream` consume the same stream that
///     `DeepgramEngine` / `ElevenLabsEngine` produce in production.
///   * Read counters (`ingestCount`, `prepareCount`, `closeCount`, ...)
///     to verify the lifecycle calls the engine receives.
actor MockTranscriptionEngine: TranscriptionEngine {

    /// Engines normally declare which languages they accept; we allow all
    /// so language-filtering tests don't trip over us.
    static let supportedLanguages: [Language] = Language.allCases

    let source: CaptionSource

    nonisolated let captions: AsyncStream<Caption>
    private let captionContinuation: AsyncStream<Caption>.Continuation

    // Lifecycle counters — every test reads these to confirm the
    // `CaptionStream` plumbing called what it should have called.
    private(set) var prepareCount: Int = 0
    private(set) var ingestCount: Int = 0
    private(set) var totalSamplesIngested: Int = 0
    private(set) var resetCount: Int = 0
    private(set) var closeCount: Int = 0
    private(set) var lastIngestedSize: Int = 0

    private var loadState: WhisperLoadState = .idle

    /// Tests can flip this BEFORE `prepare()` to simulate a failed engine
    /// startup (bad API key, missing model folder, etc.). The mock
    /// returns the supplied state from `loadStateSnapshot()` so
    /// `CaptionStream.start()` surfaces an error.
    private var scriptedLoadOutcome: WhisperLoadState = .ready

    init(source: CaptionSource) {
        self.source = source
        var continuation: AsyncStream<Caption>.Continuation!
        self.captions = AsyncStream(Caption.self, bufferingPolicy: .unbounded) { c in
            continuation = c
        }
        self.captionContinuation = continuation
    }

    // MARK: - Test driver API

    /// Yield a caption to whatever is iterating `captions`.
    func emit(_ caption: Caption) {
        captionContinuation.yield(caption)
    }

    /// Convenience: emit a final caption with the engine's source tag.
    func emitFinal(text: String, language: Language? = nil) {
        let c = Caption(
            source: source,
            text: text,
            language: language,
            isFinal: true
        )
        captionContinuation.yield(c)
    }

    /// Convenience: emit an interim caption (same id used twice so the
    /// `CaptionStream.applyCaption` in-place-update path runs).
    func emitInterim(id: UUID = UUID(), text: String, language: Language? = nil) {
        let c = Caption(
            id: id,
            source: source,
            text: text,
            language: language,
            isFinal: false
        )
        captionContinuation.yield(c)
    }

    /// End the captions stream — what production engines do in `close()`.
    func finishStream() {
        captionContinuation.finish()
    }

    /// Script what `loadStateSnapshot()` returns after `prepare()`.
    /// `.failed(...)` triggers the engine-failed branch in `CaptionStream.start()`.
    func scriptLoadOutcome(_ outcome: WhisperLoadState) {
        scriptedLoadOutcome = outcome
    }

    // MARK: - TranscriptionEngine

    func loadStateSnapshot() -> WhisperLoadState { loadState }

    func prepare() async {
        prepareCount += 1
        loadState = scriptedLoadOutcome
    }

    func ingest(_ samples: [Float]) async {
        ingestCount += 1
        totalSamplesIngested += samples.count
        lastIngestedSize = samples.count
    }

    func reset() {
        resetCount += 1
    }

    func close() {
        closeCount += 1
        captionContinuation.finish()
    }
}
