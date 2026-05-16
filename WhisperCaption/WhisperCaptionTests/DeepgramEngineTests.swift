import Foundation
import Testing
@testable import WhisperCaption

/// Behaviour tests for `DeepgramEngine`'s reconnect / tail-buffer-replay /
/// generation-counter scheme. The engine talks only to `WebSocketFactory`
/// and `HTTPClient`; both are mocked here so nothing touches the network.
///
/// Timing notes: backoff is `0.5 * 2^attempt * jitter` so the first reconnect
/// lands in 0.4–0.6 s. Most assertions sit behind a ~1 s wait so they don't
/// flake on slow CI; heartbeat-driven tests use a tight 0.1 s cadence so
/// they finish well under a second.
@MainActor
@Suite("DeepgramEngine")
struct DeepgramEngineTests {

    // MARK: - Helpers

    /// Construct an engine with the injection points filled in. Caller
    /// supplies whatever responses it wants pre-loaded on `http` and `factory`.
    private func makeEngine(
        http: MockHTTPClient,
        factory: MockWebSocketFactory,
        settings: LanguageSettings,
        apiKey: String = "k",
        heartbeatInterval: TimeInterval = 0.1,
        heartbeatPongTimeout: TimeInterval = 0.05
    ) -> DeepgramEngine {
        DeepgramEngine(
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

    /// Wait until `condition` returns true, or fail after `timeout`.
    /// Polls every 20 ms — short enough to make the happy path snappy but
    /// long enough not to thrash. Default 5 s because Swift Testing
    /// schedules suites in parallel by default, and Task.sleep budgets
    /// stretch when the host is oversubscribed.
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

    @Test("200 preflight opens exactly one socket with the token subprotocol")
    func preflightSuccessOpensSocketOnce() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(200))
        let transport1 = factory.enqueueNew()
        let engine = makeEngine(http: http, factory: factory, settings: settings, apiKey: "k")

        await engine.prepare()

        #expect(await engine.loadStateSnapshot() == .ready)
        #expect(http.requestCount == 1)
        #expect(factory.openCount == 1)
        let protocols = factory.openHistory.first?.protocols ?? []
        #expect(protocols == ["token", "k"])
        #expect(transport1.cancelCount == 0)

        await engine.close()
    }

    @Test("401 preflight fails fatally, no websocket open, message points to Settings")
    func preflight401Fatal() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(401, body: Data("nope".utf8)))
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

    @Test("403 preflight fails fatally with a streaming-permissions message")
    func preflight403Fatal() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(403))
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        let state = await engine.loadStateSnapshot()
        if case .failed(let msg) = state {
            #expect(msg.contains("streaming"))
        } else {
            Issue.record("expected .failed, got \(state)")
        }
        #expect(factory.openCount == 0)

        await engine.close()
    }

    @Test("5xx preflight is surfaced as a failure (preflight is one-shot)")
    func preflight500Fatal() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(503, body: Data("scheduled maintenance".utf8)))
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        let state = await engine.loadStateSnapshot()
        if case .failed(let msg) = state {
            #expect(msg.contains("503"))
        } else {
            Issue.record("expected .failed, got \(state)")
        }
        #expect(factory.openCount == 0)

        await engine.close()
    }

    // MARK: - ingest()

    @Test("ingest before prepare is a no-op (no send, no crash)")
    func ingestBeforePrepareIsNoOp() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.ingest(CaptionFixtures.toneChunk(durationMs: 100))

        #expect(factory.openCount == 0)
        #expect(http.requestCount == 0)
        // No queued transport was consumed → ingest did nothing.

        await engine.close()
    }

    // MARK: - Reconnect

    @Test("is_final caption clears pendingAudio, reconnect replays nothing")
    func finalizeClearsTailBuffer() async throws {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(200))
        let transport1 = factory.enqueueNew()
        let transport2Box = TransportBox()
        factory.setAutoBuildSetup { t in transport2Box.set(t) }
        factory.autoBuild = true
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        // Feed audio so pendingAudio is non-empty.
        await engine.ingest(CaptionFixtures.toneChunk(durationMs: 100))

        // Server says final → pendingAudio should be cleared.
        transport1.enqueueReceiveText(
            "{\"type\":\"Results\",\"is_final\":true,\"channel\":{\"alternatives\":[{\"transcript\":\"hello\"}]}}"
        )

        // Pull the caption off the stream so we know parseAndEmit ran.
        let captionTask = Task { () -> Caption? in
            for await c in engine.captions { return c }
            return nil
        }
        let caption = try #require(await captionTask.value)
        #expect(caption.isFinal)
        #expect(caption.text == "hello")

        // Now provoke a disconnect on transport 1 — the engine should
        // auto-build transport 2 via the factory.
        transport1.enqueueReceiveError(TestError("dropped"))

        let reconnected = await waitFor("transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(reconnected)

        // Give the engine a beat to finish wiring up transport 2 + flush.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // pendingAudio was cleared by the prior is_final → replay should
        // be a no-op → transport 2 has zero data frames.
        let t2 = try #require(transport2Box.get())
        #expect(t2.sentDataByteCount == 0, "expected no replay on transport 2, got \(t2.sentDataByteCount) bytes")

        await engine.close()
    }

    @Test("reconnect replays the un-finalised tail buffer on the new socket")
    func reconnectReplaysPendingAudio() async throws {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(200))
        let transport1 = factory.enqueueNew()

        // Capture transport 2 the moment the factory mints it.
        let transport2Box = TransportBox()
        factory.setAutoBuildSetup { t in transport2Box.set(t) }
        factory.autoBuild = true

        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        // Feed exactly 1000 samples (100ms @ 16kHz). With no is_final
        // received yet, pendingAudio retains all of it → 2000 bytes.
        let samples = Array(repeating: Float(0.1), count: 1000)
        await engine.ingest(samples)

        // Sanity: transport 1 received one direct send of 2000 bytes.
        #expect(transport1.sentDataByteCount == 2000)

        // Disconnect.
        transport1.enqueueReceiveError(TestError("dropped"))

        let opened = await waitFor("transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)

        // Wait for the replay to land. flushPendingAudio runs inside
        // connectOnce → before the reconnect loop returns success.
        let replayed = await waitFor("replay arrives on transport 2") { @Sendable in
            guard let t2 = transport2Box.get() else { return false }
            return t2.sentDataByteCount >= 2000
        }
        #expect(replayed)

        let t2 = try #require(transport2Box.get())
        #expect(t2.sentDataByteCount == 2000)
        // The bytes should be in exactly one frame.
        let dataFrames = t2.sentFrames.filter { if case .data = $0 { return true } else { return false } }
        #expect(dataFrames.count == 1)
        if case .data(let d) = dataFrames.first! {
            #expect(d.count == 2000)
        }

        await engine.close()
    }

    @Test("generation counter cancels the old transport on reconnect")
    func generationCounterCancelsOldTransport() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(200))
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        transport1.enqueueReceiveError(TestError("dropped"))

        let opened = await waitFor(timeout: 15.0, "transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)

        // The engine's triggerReconnect() must have cancelled transport 1
        // exactly once. (Belt-and-braces: a second cancel would also be
        // tolerated by the mock but signals a logic bug.)
        #expect(transport1.cancelCount == 1)

        await engine.close()
    }

    @Test("reconnect eventually opens a fresh socket after a disconnect")
    func reconnectBackoffBounded() async {
        // We can't reach the private `backoffDelay(attempt:)` from a test,
        // so instead we measure the wall-clock latency between socket death
        // and the next open(). First attempt's backoff is 0.5s * jitter
        // (0.8-1.2), so 0.4-0.6s. Allow a generous upper bound so the test
        // doesn't flake on a loaded CI.
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(200))
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        let killedAt = Date()
        transport1.enqueueReceiveError(TestError("dropped"))

        let opened = await waitFor(timeout: 15.0, "transport 2 opens") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)
        let elapsed = Date().timeIntervalSince(killedAt)
        // The engine's backoff caps at 8s. Under heavy parallel test
        // load Task.sleep budgets can stretch — we still want a bound
        // that catches a "reconnect never happens" regression without
        // flaking, so 15s is a comfortable ceiling.
        #expect(elapsed < 15.0, "expected reconnect under 15s, got \(elapsed)s")

        await engine.close()
    }

    @Test("heartbeat timeout (failing ping) triggers a reconnect")
    func heartbeatTimeoutReconnects() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(200))
        let transport1 = factory.enqueueNew()
        // Make every ping "fail" — the engine should treat the socket as dead.
        transport1.setPongResult(TestError("no pong"))
        factory.autoBuild = true
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        let opened = await waitFor(timeout: 15.0, "transport 2 opens after heartbeat fails") { @Sendable in
            factory.openCount >= 2
        }
        #expect(opened)
        // We expect at least one ping to have fired on transport 1.
        #expect(transport1.pingCount >= 1)

        await engine.close()
    }

    @Test("send error triggers a reconnect")
    func sendErrorReconnects() async {
        let settings = LanguageSettings()
        let http = MockHTTPClient()
        let factory = MockWebSocketFactory()
        http.enqueue(.status(200))
        let transport1 = factory.enqueueNew()
        factory.autoBuild = true
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()
        // Now arm send to fail and trigger an ingest. send() throws →
        // triggerReconnect → second transport opens.
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
        http.enqueue(.status(200))
        _ = factory.enqueueNew()
        let engine = makeEngine(http: http, factory: factory, settings: settings)

        await engine.prepare()

        // Background consumer: counts how many captions it sees, exits when
        // the stream ends.
        let consumer = Task { () -> Bool in
            for await _ in engine.captions { /* drain */ }
            return true   // reached only after .finish()
        }

        // Tiny delay so the consumer task has time to subscribe.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await engine.close()

        // Bound the await — if close() doesn't finish the stream, the task
        // would block forever.
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

// MARK: - Shared test plumbing

/// Tiny thread-safe box for handing the second auto-built transport from
/// the factory back into the test body. Reaches across closure boundaries
/// without needing to make every test parameter Sendable.
final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MockWebSocketTransport?
    func set(_ t: MockWebSocketTransport) { lock.withLock { value = t } }
    func get() -> MockWebSocketTransport? { lock.withLock { value } }
}
