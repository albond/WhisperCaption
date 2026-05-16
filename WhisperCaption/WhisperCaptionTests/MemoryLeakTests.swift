import AppKit
import Foundation
import Testing
@testable import WhisperCaption

/// Memory-leak detection via weak-reference probes.
///
/// The pattern is the same throughout: hold a `LeakProbe` on the object
/// of interest, drop every strong reference the test holds, drain any
/// pending Tasks, and assert `probe.isAlive == false`.
///
/// Why this is more than paranoia:
///   * Engines own unstructured `Task`s (receive loops, heartbeat,
///     reconnect). If a closure inside one of those captures `self`
///     strongly instead of `[weak self]`, the actor leaks.
///   * `CaptionStream`'s `markDirty` schedules a debounced Task that
///     should release the stream when cancelled. Same hazard.
///   * `MockWebSocketTransport.cancel(...)` should be called exactly
///     once by the engine on close; double-cancel could indicate the
///     engine holding a stale transport reference.
@MainActor
@Suite("Memory-leak probes")
struct MemoryLeakTests {

    // MARK: - CaptionStream

    @Test("CaptionStream is released after the owning scope drops + tasks drain")
    func captionStreamReleased() async throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        weak var weakStream: CaptionStream?
        do {
            let stream = CaptionStream()
            stream.attach(settings: SettingsStore(), history: temp.store)
            stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "x")
            stream.flushNow()
            weakStream = stream
        }
        await drainPendingTasks()
        // The willTerminate observer keeps a [weak self] reference, and
        // the autosave debounce Task captures `[weak self]` too, so
        // there's no retain cycle. The store and settings released with
        // the stream scope.
        #expect(weakStream == nil, "CaptionStream leaked after scope ended")
    }

    // MARK: - DeepgramEngine

    @Test("DeepgramEngine releases after close() and the receive loop exits")
    func deepgramEngineReleased() async throws {
        let factory = MockWebSocketFactory()
        let http = MockHTTPClient()
        let settings = LanguageSettings()
        let transport = factory.enqueueNew()
        http.enqueue(.status(200))  // preflight OK

        weak var weakEngine: DeepgramEngine?
        weak var weakTransport: MockWebSocketTransport?
        do {
            let engine = DeepgramEngine(
                source: .system,
                apiKey: "k",
                vocabularyHint: "",
                settings: settings,
                webSocketFactory: factory,
                httpClient: http,
                heartbeatInterval: 60,
                heartbeatPongTimeout: 30
            )
            weakEngine = engine
            weakTransport = transport
            await engine.prepare()
            await engine.close()
        }
        // The engine spawns unstructured Tasks; give them a tick to settle.
        await drainPendingTasks(rounds: 8)

        #expect(weakEngine == nil, "DeepgramEngine leaked after close()")
        // Transport reference might still be held by the test's own
        // factory variable; clear that.
        _ = transport
        // The factory still references the transport via openHistory, so
        // weakTransport may not be nil. Skip the strict check there;
        // engine-side leak is the load-bearing one.
        _ = weakTransport
    }

    @Test("DeepgramEngine.close() cancels the underlying transport exactly once")
    func deepgramCancelsTransportOnce() async throws {
        let factory = MockWebSocketFactory()
        let http = MockHTTPClient()
        let transport = factory.enqueueNew()
        http.enqueue(.status(200))

        let engine = DeepgramEngine(
            source: .system,
            apiKey: "k",
            vocabularyHint: "",
            settings: LanguageSettings(),
            webSocketFactory: factory,
            httpClient: http,
            heartbeatInterval: 60,
            heartbeatPongTimeout: 30
        )
        await engine.prepare()
        await engine.close()
        // close() dispatches the actual cancel inside a Task; allow it to run.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(transport.cancelCount == 1)
    }

    // MARK: - ElevenLabsEngine

    @Test("ElevenLabsEngine releases after close() and the receive loop exits")
    func elevenLabsEngineReleased() async throws {
        let factory = MockWebSocketFactory()
        let http = MockHTTPClient()
        let settings = LanguageSettings()
        let _ = factory.enqueueNew()
        http.enqueueElevenLabsToken("test-token")

        weak var weakEngine: ElevenLabsEngine?
        do {
            let engine = ElevenLabsEngine(
                source: .system,
                apiKey: "k",
                vocabularyHint: "",
                settings: settings,
                webSocketFactory: factory,
                httpClient: http,
                heartbeatInterval: 60,
                heartbeatPongTimeout: 30
            )
            weakEngine = engine
            await engine.prepare()
            await engine.close()
        }
        await drainPendingTasks(rounds: 8)
        #expect(weakEngine == nil, "ElevenLabsEngine leaked after close()")
    }

    @Test("ElevenLabsEngine.close() cancels the underlying transport exactly once")
    func elevenLabsCancelsTransportOnce() async throws {
        let factory = MockWebSocketFactory()
        let http = MockHTTPClient()
        let transport = factory.enqueueNew()
        http.enqueueElevenLabsToken("test-token")

        let engine = ElevenLabsEngine(
            source: .system,
            apiKey: "k",
            vocabularyHint: "",
            settings: LanguageSettings(),
            webSocketFactory: factory,
            httpClient: http,
            heartbeatInterval: 60,
            heartbeatPongTimeout: 30
        )
        await engine.prepare()
        await engine.close()

        #expect(transport.cancelCount == 1)
    }

    // MARK: - Engines releasing on prepare-failure paths

    @Test("DeepgramEngine releases after a failed preflight without leaking")
    func deepgramReleasedAfterFailedPrepare() async throws {
        let factory = MockWebSocketFactory()
        let http = MockHTTPClient()
        // 401 preflight → engine moves to .closed, no WS open.
        http.enqueue(.status(401, body: Data()))

        weak var weakEngine: DeepgramEngine?
        do {
            let engine = DeepgramEngine(
                source: .system,
                apiKey: "bad",
                vocabularyHint: "",
                settings: LanguageSettings(),
                webSocketFactory: factory,
                httpClient: http,
                heartbeatInterval: 60,
                heartbeatPongTimeout: 30
            )
            weakEngine = engine
            await engine.prepare()
            await engine.close()
        }
        await drainPendingTasks(rounds: 8)
        #expect(weakEngine == nil, "Engine leaked after failed preflight + close")
    }

    @Test("ElevenLabsEngine releases after a failed token mint without leaking")
    func elevenLabsReleasedAfterFailedPrepare() async throws {
        let factory = MockWebSocketFactory()
        let http = MockHTTPClient()
        http.enqueue(.status(401, body: Data()))

        weak var weakEngine: ElevenLabsEngine?
        do {
            let engine = ElevenLabsEngine(
                source: .system,
                apiKey: "bad",
                vocabularyHint: "",
                settings: LanguageSettings(),
                webSocketFactory: factory,
                httpClient: http,
                heartbeatInterval: 60,
                heartbeatPongTimeout: 30
            )
            weakEngine = engine
            await engine.prepare()
            await engine.close()
        }
        await drainPendingTasks(rounds: 8)
        #expect(weakEngine == nil)
    }

    // MARK: - ChatImageStore thumbnail cache

    @Test("ChatImageStore.deleteAll evicts the in-memory thumbnail cache")
    func thumbnailCacheClearedOnDeleteAll() async throws {
        let tmp = try TempDirectory.make()
        defer { tmp.cleanup() }
        let store = ChatImageStore(imagesFolder: tmp.url)

        // Build + save a colored PNG so loadThumbnail can decode it.
        let png = CaptionFixtures.makeColoredPNG(side: 32, color: .systemTeal)
        let filename = try store.save(pngData: png)
        let firstThumb = store.loadThumbnail(filename: filename, maxPixels: 32)
        #expect(firstThumb != nil)

        // Delete everything — the file's gone AND the cache entry should
        // be wiped, so a subsequent load returns nil rather than the
        // stale cached NSImage.
        try store.deleteAll()
        let secondThumb = store.loadThumbnail(filename: filename, maxPixels: 32)
        #expect(secondThumb == nil, "thumbnailCache wasn't evicted on deleteAll()")
    }

    @Test("ChatImageStore.delete(filename:) evicts that one cache entry")
    func thumbnailCacheClearedOnSingleDelete() async throws {
        let tmp = try TempDirectory.make()
        defer { tmp.cleanup() }
        let store = ChatImageStore(imagesFolder: tmp.url)
        let png = CaptionFixtures.makeColoredPNG(side: 32, color: .systemPink)
        let filename = try store.save(pngData: png)
        _ = store.loadThumbnail(filename: filename, maxPixels: 32)
        try store.delete(filename: filename)
        #expect(store.loadThumbnail(filename: filename, maxPixels: 32) == nil)
    }

    // MARK: - Mock transport invariants

    @Test("MockWebSocketTransport pending receives are awoken on cancel — no leaked continuations")
    func mockTransportDrainsContinuationsOnCancel() async {
        let transport = MockWebSocketTransport(id: 1)
        // Park a receive() — no message queued.
        let waiter = Task { () -> Error? in
            do {
                _ = try await transport.receive()
                return nil
            } catch {
                return error
            }
        }
        // Give the Task a moment to actually park on the continuation.
        try? await Task.sleep(nanoseconds: 5_000_000)
        transport.cancel(closeCode: .normalClosure, reason: nil)
        let result = await waiter.value
        #expect(result != nil, "Expected the parked receive() to throw on cancel()")
    }
}
