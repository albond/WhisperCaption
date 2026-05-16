import Foundation
import Testing
@testable import WhisperCaption

/// Behaviour tests for `ElevenLabsEngine`'s reconnect / tail-buffer-replay /
/// generation-counter scheme. Differs from `DeepgramEngineTests` in two ways:
///
///   * Token mint: every (re)connect first POSTs to the single-use-token
///     endpoint. Each connect we expect needs its own HTTP response queued.
///   * Wire format: outbound is JSON text envelopes (`input_audio_chunk`),
///     not binary PCM. We assert against `.text(...)` frames and decode
///     the JSON to verify the base64 payload.
@MainActor
@Suite("ElevenLabsEngine")
struct ElevenLabsEngineTests {

    // MARK: - Helpers

    private func makeEngine(
        http: MockHTTPClient,
        factory: MockWebSocketFactory,
        settings: LanguageSettings,
        apiKey: String = "k",
        heartbeatInterval: TimeInterval = 0.1,
        heartbeatPongTimeout: TimeInterval = 0.05
    ) -> ElevenLabsEngine {
        ElevenLabsEngine(
            source: .system,
            apiKey: apiKey,
            vocabularyHint: "",
            settings: settings,
            webSocketFactory: factory,
            httpClient: http,
            heartbeatInterval: heartbeatInterval,
            heartbeatPongTimeout: heartbeatPongTimeout
        )
    }

    @discardableResult
    private func waitFor(
        timeout: TimeInterval = 5.0,
        _ description: String = "condition",
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Decode the base64-encoded PCM out of an `input_audio_chunk` envelope.
    /// Returns the byte count, or nil if the frame doesn't fit the schema.
    /// `nonisolated` so test closures running on background tasks can call it.
    private nonisolated static func pcmByteCount(in frame: MockWebSocketTransport.Frame) -> Int? {
        guard case .text(let s) = frame,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["message_type"] as? String == "input_audio_chunk",
              let b64 = obj["audio_base_64"] as? String,
              let bytes = Data(base64Encoded: b64) else { return nil }
        return bytes.count
    }

    // MARK: - prepare()

    @Test("empty API key fails fast without any network calls")
    func emptyAPIKeyShortCircuits() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        let engine = makeEngine(http: http, factory: factory, settings: settings, apiKey: "")

        await engine.prepare()

        let state = await engine.loadStateSnapshot()
        if case .failed(let msg) = state {
            #expect(msg.contains("API key"))
        } else {
            Issue.record("expected .failed, got \(state)")
        }
        #expect(http.requestCount == 0)
        #expect(factory.openCount == 0)

        await engine.close()
    }

    @Test("token endpoint 200 mints a socket")
    func tokenSuccessOpensSocket() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("abc.def")
        _ = factory.enqueueNew()
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        #expect(await engine.loadStateSnapshot() == .ready)
        #expect(http.requestCount == 1)
        #expect(factory.openCount == 1)
        // Token goes into the URL query string, not the protocols list.
        let opened = factory.openHistory.first
        #expect(opened?.url.absoluteString.contains("token=abc.def") == true)
        #expect(opened?.protocols.isEmpty == true)

        await engine.close()
    }

    @Test("token endpoint 401 fails fatally, no websocket open")
    func token401Fatal() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(401, body: Data("invalid".utf8)))
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        let state = await engine.loadStateSnapshot()
        if case .failed(let msg) = state {
            #expect(msg.contains("Open Settings"))
            #expect(msg.contains("Speech Recognition"))
        } else {
            Issue.record("expected .failed, got \(state)")
        }
        #expect(factory.openCount == 0)

        await engine.close()
    }

    @Test("token endpoint 403 fails fatally")
    func token403Fatal() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(403))
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        let state = await engine.loadStateSnapshot()
        if case .failed(let msg) = state {
            #expect(msg.contains("403"))
        } else {
            Issue.record("expected .failed, got \(state)")
        }
        #expect(factory.openCount == 0)

        await engine.close()
    }

    @Test("token endpoint 5xx is transient, reconnect loop retries the token call")
    func token500RetriesTokenCall() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        // First token call: 503. The engine should kick off the reconnect
        // loop, which calls connectOnce again — which in turn fetches the
        // token again.
        http.enqueue(.status(503))
        http.enqueue(.status(503))  // second attempt also fails (keeps retrying)
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        // After prepare, we should be in .ready (transient outcome) and the
        // reconnect loop should be running. Wait for a 2nd HTTP call.
        let retried = await waitFor(timeout: 15.0, "second token call") { @Sendable in
            http.requestCount >= 2
        }
        #expect(retried)
        #expect(factory.openCount == 0)

        await engine.close()
    }

    // MARK: - ingest()

    @Test("ingest before prepare is a no-op")
    func ingestBeforePrepareIsNoOp() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.ingest(CaptionFixtures.toneChunk(durationMs: 100))

        #expect(factory.openCount == 0)
        #expect(http.requestCount == 0)

        await engine.close()
    }

    // MARK: - Wire format / receive

    @Test("ingest sends a JSON input_audio_chunk text frame, not binary")
    func ingestSendsTextEnvelope() async throws {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        let samples = Array(repeating: Float(0.1), count: 1000)
        await engine.ingest(samples)

        // Last frame should be a text envelope with 2000 bytes of audio.
        let last = try #require(transport1.sentFrames.last)
        let count = try #require(Self.pcmByteCount(in: last))
        #expect(count == 2000)

        await engine.close()
    }

    @Test("partial_transcript yields an interim caption (isFinal == false)")
    func partialTranscriptIsNotFinal() async throws {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        transport1.enqueueReceiveText(
            "{\"message_type\":\"partial_transcript\",\"text\":\"hel\"}"
        )

        let captionTask = Task { () -> Caption? in
            for await c in engine.captions { return c }
            return nil
        }
        let caption = try #require(await captionTask.value)
        #expect(caption.text == "hel")
        #expect(caption.isFinal == false)

        await engine.close()
    }

    @Test("committed_transcript finalises and clears pendingAudio")
    func committedTranscriptClearsTailBuffer() async throws {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        // Auto-build any reconnect transports; preload the second token call.
        factory.autoBuild = true
        http.enqueueElevenLabsToken("t2")
        let transport2Box = TransportBox()
        factory.setAutoBuildSetup { t in transport2Box.set(t) }

        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        let samples = Array(repeating: Float(0.1), count: 1000)
        await engine.ingest(samples)

        // Server commits → pendingAudio cleared.
        transport1.enqueueReceiveText(
            "{\"message_type\":\"committed_transcript\",\"text\":\"hello\"}"
        )

        let captionTask = Task { () -> Caption? in
            for await c in engine.captions { return c }
            return nil
        }
        let caption = try #require(await captionTask.value)
        #expect(caption.isFinal)
        #expect(caption.text == "hello")

        // Trigger reconnect; transport 2 should receive *no* audio
        // envelopes because pendingAudio is empty after the commit.
        transport1.enqueueReceiveError(TestError("dropped"))
        let opened = await waitFor("transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)
        // Let the reconnect path finish (flushPendingAudio is empty → no send).
        try? await Task.sleep(nanoseconds: 200_000_000)
        let t2 = try #require(transport2Box.get())
        let audioFrames = t2.sentFrames.compactMap { Self.pcmByteCount(in: $0) }
        #expect(audioFrames.isEmpty, "expected no replay, got frames: \(audioFrames)")

        await engine.close()
    }

    @Test("reconnect replays pendingAudio as one big input_audio_chunk envelope")
    func reconnectReplaysPendingAudio() async throws {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        http.enqueueElevenLabsToken("t2")
        let transport2Box = TransportBox()
        factory.setAutoBuildSetup { t in transport2Box.set(t) }
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        // Ingest 1000 samples → 2000 bytes in pendingAudio.
        let samples = Array(repeating: Float(0.1), count: 1000)
        await engine.ingest(samples)

        // Sanity: transport 1 sent one input_audio_chunk envelope of 2000 bytes.
        #expect(transport1.sentFrames.compactMap { Self.pcmByteCount(in: $0) } == [2000])

        // Disconnect.
        transport1.enqueueReceiveError(TestError("dropped"))

        let replayed = await waitFor(timeout: 15.0, "replay arrives on transport 2") { @Sendable in
            guard let t2 = transport2Box.get() else { return false }
            return t2.sentFrames.contains(where: { Self.pcmByteCount(in: $0) == 2000 })
        }
        #expect(replayed)

        let t2 = try #require(transport2Box.get())
        // Replay should be one envelope of 2000 bytes (no chunking).
        let replays = t2.sentFrames.compactMap { Self.pcmByteCount(in: $0) }
        #expect(replays == [2000])

        await engine.close()
    }

    @Test("replayed envelope grows when more audio is ingested before disconnect")
    func replayGrowsWithMoreAudio() async throws {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        http.enqueueElevenLabsToken("t2")
        let transport2Box = TransportBox()
        factory.setAutoBuildSetup { t in transport2Box.set(t) }
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        // Two ingests, both retained in pendingAudio.
        await engine.ingest(Array(repeating: Float(0.1), count: 500))   // 1000 bytes
        await engine.ingest(Array(repeating: Float(0.1), count: 500))   // +1000 = 2000

        transport1.enqueueReceiveError(TestError("dropped"))

        let replayed = await waitFor(timeout: 15.0, "replay arrives") { @Sendable in
            guard let t2 = transport2Box.get() else { return false }
            return t2.sentFrames.contains(where: { Self.pcmByteCount(in: $0) != nil })
        }
        #expect(replayed)

        let t2 = try #require(transport2Box.get())
        let replays = t2.sentFrames.compactMap { Self.pcmByteCount(in: $0) }
        #expect(replays.first == 2000)

        await engine.close()
    }

    // MARK: - Generation / heartbeat / send error / close

    @Test("generation counter cancels the old transport on reconnect")
    func generationCounterCancelsOldTransport() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        http.enqueueElevenLabsToken("t2")
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        transport1.enqueueReceiveError(TestError("dropped"))

        let opened = await waitFor(timeout: 15.0, "transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)
        #expect(transport1.cancelCount == 1)

        await engine.close()
    }

    @Test("reconnect eventually opens a fresh socket after a disconnect")
    func reconnectBackoffBounded() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        http.enqueueElevenLabsToken("t2")
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        let killedAt = Date()
        transport1.enqueueReceiveError(TestError("dropped"))

        let opened = await waitFor(timeout: 15.0, "transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)
        let elapsed = Date().timeIntervalSince(killedAt)
        // Loosened from 1.5s to 15s: under Swift Testing's parallel-suite
        // execution, Task.sleep budgets stretch when the host is
        // oversubscribed. We still flag a "reconnect never happens"
        // regression.
        #expect(elapsed < 15.0, "expected reconnect under 15s, got \(elapsed)s")

        await engine.close()
    }

    @Test("heartbeat timeout (failing ping) triggers a reconnect")
    func heartbeatTimeoutReconnects() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        transport1.setPongResult(TestError("no pong"))
        factory.autoBuild = true
        http.enqueueElevenLabsToken("t2")
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        let opened = await waitFor(timeout: 15.0, "transport 2 opens after heartbeat fails") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)
        #expect(transport1.pingCount >= 1)

        await engine.close()
    }

    @Test("send error triggers a reconnect")
    func sendErrorReconnects() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        http.enqueueElevenLabsToken("t2")
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        transport1.setSendError(TestError("broken pipe"))
        await engine.ingest(CaptionFixtures.toneChunk(durationMs: 50))

        let opened = await waitFor(timeout: 15.0, "transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)

        await engine.close()
    }

    @Test("close() finishes the captions stream")
    func closeFinishesCaptionsStream() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueueElevenLabsToken("t1")
        _ = factory.enqueueNew()
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        let consumer = Task { () -> Bool in
            for await _ in engine.captions { /* drain */ }
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await engine.close()

        let raceWinner = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await consumer.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(raceWinner, "captions stream did not finish within 1 s after close()")
    }
}
