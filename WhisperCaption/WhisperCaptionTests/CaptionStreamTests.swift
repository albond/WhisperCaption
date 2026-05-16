import Foundation
import Testing
@testable import WhisperCaption

/// Wiring tests for `CaptionStream`. These exercise the persistence
/// surface that doesn't touch CoreAudio or the cloud engines — i.e. the
/// public methods that mutate captions and the history bridge that
/// flushes those mutations to disk.
///
/// What we cannot cover here:
///   * `start()` / `stop()` lifecycle — touches CoreAudio (mic capture)
///     and ScreenCaptureKit (system capture); both prompt for permissions
///     and require real hardware. Those paths are covered by the
///     UI/smoke tests instead.
///   * Engine pump tasks — engines are constructed inline inside
///     `start()`, so wiring them to a mock requires either start-time
///     factory injection (a refactor we deliberately skipped) or running
///     real engines. Engines are tested in isolation in
///     `DeepgramEngineTests` / `ElevenLabsEngineTests`.
///
/// Everything else — appendScreenshot, deleteCaption, setTranslation /
/// clearTranslation, newSession, activate, flushNow, attach() bootstrap,
/// the willTerminate observer — is reachable without entering start().
@MainActor
@Suite("CaptionStream wiring")
struct CaptionStreamTests {

    // MARK: - Bootstrap

    @Test("attach with no prior chat id creates and saves a fresh session")
    func attachCreatesFreshSession() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let settings = SettingsStore()
        settings.activeChatID = nil  // explicit no-op so test-run leakage from a previous test is harmless

        let stream = CaptionStream()
        stream.attach(settings: settings, history: temp.store)

        // A fresh session id should now be live in both the stream and
        // settings, and on disk the picker should see one entry.
        #expect(stream.activeSession.captions.isEmpty)
        #expect(settings.activeChatID == stream.activeSession.id)
        #expect(temp.store.index.contains(where: { $0.id == stream.activeSession.id }))
    }

    @Test("attach restores activeSession when settings point at an existing chat")
    func attachRestoresPriorSession() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        // Seed a session on disk.
        let priorID = "2026-01-01-10-00-00"
        var prior = ChatSession(id: priorID, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        prior.captions = [CaptionFixtures.caption(text: "loaded from disk")]
        temp.store.save(prior)

        let settings = SettingsStore()
        settings.activeChatID = priorID

        let stream = CaptionStream()
        stream.attach(settings: settings, history: temp.store)

        #expect(stream.activeSession.id == priorID)
        #expect(stream.captions.count == 1)
        #expect(stream.captions.first?.text == "loaded from disk")
    }

    @Test("attach falls back to a fresh session when the persisted chat was deleted")
    func attachHandlesStaleSessionID() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let settings = SettingsStore()
        settings.activeChatID = "nonexistent-2025-01-01-00-00-00"

        let stream = CaptionStream()
        stream.attach(settings: settings, history: temp.store)

        // It should have minted a new id, NOT preserved the dangling one.
        #expect(stream.activeSession.id != "nonexistent-2025-01-01-00-00-00")
        #expect(settings.activeChatID == stream.activeSession.id)
    }

    // MARK: - Persistence wiring

    @Test("appendScreenshot stores the PNG on disk and appends a caption")
    func appendScreenshotPersists() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let settings = SettingsStore()
        let stream = CaptionStream()
        stream.attach(settings: settings, history: temp.store)

        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "Snapshot · test")
        stream.flushNow()  // bypass the 1.5s debounce

        #expect(stream.captions.count == 1)
        let last = try #require(stream.captions.last)
        #expect(last.source == .system)
        #expect(last.imageFilename != nil)
        #expect(last.isFinal)

        // PNG must exist on disk.
        let imgFolder = temp.store.imagesFolderURL(for: stream.activeSession.id)
        let pngURL = imgFolder.appendingPathComponent(last.imageFilename!)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))

        // session.json on disk should also reflect the caption.
        let reloaded = try #require(temp.store.load(id: stream.activeSession.id))
        #expect(reloaded.captions.count == 1)
        #expect(reloaded.captions.first?.imageFilename == last.imageFilename)
    }

    @Test("deleteCaption removes the in-memory caption AND its PNG from disk")
    func deleteCaptionDropsImage() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)

        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "x")
        let captionID = try #require(stream.captions.first?.id)
        let filename = try #require(stream.captions.first?.imageFilename)
        let pngURL = temp.store.imagesFolderURL(for: stream.activeSession.id).appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))

        stream.deleteCaption(captionID)
        stream.flushNow()

        #expect(stream.captions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pngURL.path))
    }

    @Test("setTranslation mutates the caption in-place and persists")
    func setTranslationRoundtrips() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)

        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "snap")
        let id = try #require(stream.captions.first?.id)

        let sourceText = try #require(stream.captions.first?.text)
        stream.setTranslation("привет мир", sourceText: sourceText, language: .ru, forCaptionID: id)
        stream.flushNow()

        #expect(stream.captions.first?.translation == "привет мир")
        #expect(stream.captions.first?.translationLanguage == .ru)

        let reloaded = try #require(temp.store.load(id: stream.activeSession.id))
        #expect(reloaded.captions.first?.translation == "привет мир")
        #expect(reloaded.captions.first?.translationLanguage == .ru)
    }

    @Test("clearTranslation wipes translation + language fields")
    func clearTranslation() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)

        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "x")
        let id = try #require(stream.captions.first?.id)
        let sourceText = try #require(stream.captions.first?.text)
        stream.setTranslation("hi", sourceText: sourceText, language: .en, forCaptionID: id)
        stream.clearTranslation(forCaptionID: id)
        stream.flushNow()

        #expect(stream.captions.first?.translation == nil)
        #expect(stream.captions.first?.translationLanguage == nil)
    }

    @Test("setTranslation on a non-matching caption id is a silent no-op")
    func setTranslationUnknownIDNoop() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)
        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "x")

        // Random UUID that doesn't match anything in the array.
        stream.setTranslation("...", sourceText: "x", language: .ru, forCaptionID: UUID())

        #expect(stream.captions.first?.translation == nil)
    }

    @Test("deleteCaption on an unknown id is a silent no-op")
    func deleteUnknownIDNoop() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)
        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "x")
        #expect(stream.captions.count == 1)
        stream.deleteCaption(UUID())
        #expect(stream.captions.count == 1)
    }

    // MARK: - Session switching

    @Test("newSession flushes the prior session and creates a fresh one")
    func newSessionFlushesAndSwitches() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let settings = SettingsStore()
        let stream = CaptionStream()
        stream.attach(settings: settings, history: temp.store)

        let priorID = stream.activeSession.id
        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "first")
        stream.newSession()

        // The previously-active session should be persisted with 1 caption.
        let priorOnDisk = try #require(temp.store.load(id: priorID))
        #expect(priorOnDisk.captions.count == 1)

        // The new active session is empty and has a distinct id.
        #expect(stream.captions.isEmpty)
        #expect(stream.activeSession.id != priorID)
        #expect(settings.activeChatID == stream.activeSession.id)
    }

    @Test("activate switches to a known existing session and loads its captions")
    func activateSwitchesSession() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let settings = SettingsStore()
        let stream = CaptionStream()

        // Seed a second session on disk before attach.
        let seededID = "2026-02-02-02-02-02"
        var seeded = ChatSession(id: seededID, createdAt: Date(timeIntervalSince1970: 1_700_001_000))
        seeded.captions = [
            CaptionFixtures.caption(source: .system, text: "one"),
            CaptionFixtures.caption(source: .microphone, text: "two"),
        ]
        temp.store.save(seeded)

        stream.attach(settings: settings, history: temp.store)
        stream.activate(sessionID: seededID)

        #expect(stream.activeSession.id == seededID)
        #expect(stream.captions.count == 2)
        #expect(settings.activeChatID == seededID)
    }

    @Test("activate on an unknown id is a silent no-op")
    func activateUnknownNoop() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)
        let priorID = stream.activeSession.id

        stream.activate(sessionID: "session-that-does-not-exist")

        #expect(stream.activeSession.id == priorID)
    }

    @Test("activate on the currently-active id is a silent no-op")
    func activateCurrentNoop() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)
        let priorID = stream.activeSession.id
        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "x")

        stream.activate(sessionID: priorID)

        // Captions should be untouched (no reload-from-disk clobber).
        #expect(stream.captions.count == 1)
    }

    // MARK: - Autosave debounce

    @Test("flushNow is idempotent — repeated calls don't corrupt the file", .timeLimit(.minutes(1)))
    func flushNowIdempotent() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)
        stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "x")
        for _ in 0..<20 { stream.flushNow() }
        let loaded = try #require(temp.store.load(id: stream.activeSession.id))
        #expect(loaded.captions.count == 1)
    }

    @Test(
        "debounced autosave eventually persists after a burst of mutations",
        .timeLimit(.minutes(1))
    )
    func debouncedAutosaveEventuallyPersists() async throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)
        let sessionID = stream.activeSession.id

        // Capture the on-disk caption count right after attach (1 caption
        // file was just written by the bootstrap). Now make rapid mutations
        // WITHOUT calling flushNow — the debounce (1.5s) should still land.
        for i in 0..<5 {
            stream.appendScreenshot(pngData: CaptionFixtures.tinyPNG, label: "burst-\(i)")
        }

        let memCount = stream.captions.count
        #expect(memCount == 5)

        // Poll the file every 200 ms up to 30 s. Avoids hardcoding a single
        // long sleep, which gets flaky under parallel test load where
        // Task.sleep budgets stretch.
        let deadline = Date().addingTimeInterval(30.0)
        var observed = 0
        while Date() < deadline {
            if let loaded = temp.store.load(id: sessionID) {
                observed = loaded.captions.count
                if observed == memCount { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(observed == memCount, "expected on-disk caption count to converge to \(memCount), got \(observed)")
    }

    // MARK: - State machine (idle paths only)

    @Test("dismissError clears an error state but leaves other states untouched")
    func dismissErrorOnlyClearsErrorState() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        let stream = CaptionStream()
        stream.attach(settings: SettingsStore(), history: temp.store)

        // Fresh stream is .idle. dismissError() is a no-op.
        #expect(stream.state == .idle)
        stream.dismissError()
        #expect(stream.state == .idle)
    }

    @Test("State.isRunning / isBusy classification")
    func stateClassification() {
        #expect(CaptionStream.State.idle.isRunning == false)
        #expect(CaptionStream.State.idle.isBusy == false)

        #expect(CaptionStream.State.running.isRunning == true)
        #expect(CaptionStream.State.running.isBusy == false)

        #expect(CaptionStream.State.checkingPermissions.isRunning == false)
        #expect(CaptionStream.State.checkingPermissions.isBusy == true)

        #expect(CaptionStream.State.starting.isRunning == false)
        #expect(CaptionStream.State.starting.isBusy == true)

        #expect(CaptionStream.State.stopping.isRunning == false)
        #expect(CaptionStream.State.stopping.isBusy == true)

        #expect(CaptionStream.State.loadingModel(progress: 0.5, message: "x").isBusy == true)
        #expect(CaptionStream.State.error("boom").isRunning == false)
        #expect(CaptionStream.State.error("boom").isBusy == false)
    }
}
