import Foundation

/// Common surface for any speech-to-text backend (local Whisper, cloud
/// Deepgram, cloud ElevenLabs Scribe). The coordinator (`CaptionStream`)
/// talks only to this protocol, so swapping engines is a matter of
/// constructing a different conformance — no branches in the pump /
/// lifecycle code.
///
/// Constraint: `Actor` so concrete engines can carry mutable state without
/// needing to manually serialize callers; every requirement is implicitly
/// async at the call site.
protocol TranscriptionEngine: Actor {
    /// Languages this engine can transcribe. Lets the UI surface a
    /// capability-driven language picker.
    static var supportedLanguages: [Language] { get }

    /// Caption updates produced by this engine. Consumer iterates this
    /// stream from a single Task; the engine yields interim and final
    /// captions through the same stream (id stays stable for in-place
    /// UI updates of the same bubble).
    nonisolated var captions: AsyncStream<Caption> { get }

    /// Load whatever the engine needs (model files, network handshake).
    /// May be a no-op. Called once before any `ingest`.
    func prepare() async

    /// Coarse load/health snapshot for the UI. Engines that don't need
    /// loading just return `.ready` immediately.
    func loadStateSnapshot() -> WhisperLoadState

    /// Feed a chunk of 16 kHz mono Float32 PCM samples. Engine decides
    /// when to emit captions; returns immediately.
    func ingest(_ samples: [Float]) async

    /// Reset internal phrase / buffer state without tearing down the
    /// engine itself. Called between sessions.
    func reset()

    /// Tear down: close the captions stream, drop network sockets, etc.
    func close()
}
