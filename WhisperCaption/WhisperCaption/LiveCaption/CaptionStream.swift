import AppKit
import Foundation
import OSLog

/// Coordinator: spins up two capture sources, two `TranscriptionEngine`s,
/// and merges their caption updates into a single observable timeline the
/// UI binds to. Nothing is recorded to disk; chat history is the only
/// persistence layer.
@MainActor
@Observable
final class CaptionStream {

    enum State: Equatable, Sendable {
        case idle
        case checkingPermissions
        case loadingModel(progress: Double, message: String)
        case starting
        case running
        case stopping
        case error(String)

        var isRunning: Bool {
            if case .running = self { true } else { false }
        }
        var isBusy: Bool {
            switch self {
            case .checkingPermissions, .loadingModel, .starting, .stopping: true
            default: false
            }
        }
    }

    /// SettingsStore is injected after init so we can read the user's
    /// chosen engine + model folder + per-engine API keys at start time.
    private weak var settingsStore: SettingsStore?

    /// History store is also injected post-init; until `attach(...)` runs,
    /// `captions` lives only in memory and no autosave happens. The first
    /// attach also restores `activeSession` from the persisted active id
    /// (or creates a fresh session if none is recorded yet).
    private weak var history: ChatHistoryStore?

    /// Currently-active chat session — receives every caption emitted by
    /// the running engines. Switching sessions via `activate(id:)` or
    /// `newSession()` flushes the previous one to disk first.
    private(set) var activeSession: ChatSession = ChatSession(id: ChatSession.idFormatter.string(from: Date()))

    func attach(settings: SettingsStore, history: ChatHistoryStore) {
        self.settingsStore = settings
        self.history = history
        bootstrapActiveSession()
        // Engines pre-load now if Whisper is the chosen provider. Cloud
        // engines (Deepgram / ElevenLabs) skip this branch entirely.
        preloadWhisperIfNeeded()
        observeEngineSettingChanges()
    }

    // MARK: - Observable state

    private(set) var state: State = .idle
    private(set) var captions: [Caption] = []
    private(set) var elapsedSeconds: TimeInterval = 0
    /// Live RMS levels per source (peak-hold with decay), 0...~1.
    /// Used by the UI VU meters to confirm audio is actually flowing.
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    let languages: LanguageSettings
    let routing: AudioRoutingSettings

    // MARK: - Internals

    private let log = Log.CaptionStream

    private var micCapture: MicCapture?
    private var systemCapture: SystemCapture?
    private var micEngine: (any TranscriptionEngine)?
    private var systemEngine: (any TranscriptionEngine)?

    private var micPump: Task<Void, Never>?
    private var systemPump: Task<Void, Never>?
    private var micCaptionPump: Task<Void, Never>?
    private var systemCaptionPump: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var bubbleSilenceTask: Task<Void, Never>?

    /// Normaliser between engine output and `applyCaption`. Reset on stop.
    private let bubbleSplitter = BubbleSplitter()

    private var startedAt: Date?

    /// Image store for the currently-active session. Replaced whenever the
    /// session id changes; screenshot bubbles write PNGs through this.
    private var imageStore: ChatImageStore?

    // MARK: Whisper preload
    //
    // Whisper model loading takes seconds (small) to ~10 s (medium) on first
    // launch — too slow if we wait until the user clicks Start. Preload
    // happens in the background as soon as we know the engine setting
    // points at Whisper, so a click is instant. If the user has a cloud
    // engine selected (Deepgram / ElevenLabs), `preloadedMicEngine` and
    // `preloadedSystemEngine` stay nil — zero Whisper memory used.
    private var preloadedMicEngine: WhisperEngine?
    private var preloadedSystemEngine: WhisperEngine?
    private var preloadTask: Task<Void, Never>?
    /// Snapshot of the settings the live preloaded engines were built for.
    /// Lets us detect "settings changed → preload is stale → discard".
    private var preloadedConfigKey: WhisperConfigKey?

    /// Everything that, if changed, invalidates a preloaded WhisperEngine.
    private struct WhisperConfigKey: Equatable {
        let model: WhisperModel
        let modelFolderPath: String
        let tokenizerFolderPath: String?
        let vocabularyHint: String
        let captureMic: Bool
    }

    init() {
        self.languages = LanguageSettings()
        self.routing = AudioRoutingSettings()
    }

    // MARK: - Public API

    func toggle() async {
        if state.isRunning {
            await stop()
        } else if !state.isBusy {
            await start()
        }
    }

    func start() async {
        guard !state.isRunning, !state.isBusy else { return }
        // Captions are PRESERVED across Stop/Start cycles — the user wipes
        // them explicitly. Auto-wiping on Start was surprising in practice
        // (user pauses to re-read, then resumes and loses context).
        // Snapshot the mic flag at start time so toggling the setting
        // mid-session doesn't half-tear-down the running pipeline.
        let captureMic = settingsStore?.captureMicrophone ?? true
        // Reset the unused side of the UI to a clean zero so the meter
        // doesn't show a stale level from a previous session.
        if !captureMic { micLevel = 0 }

        // 1) Permissions
        state = .checkingPermissions

        if captureMic {
            let micStatus = await PermissionsCoordinator.requestMic()
            guard micStatus == .granted else {
                state = .error("Microphone access denied. Open System Settings → Privacy & Security → Microphone, or turn off ‘Capture microphone’ in Settings.")
                return
            }
        }

        let screenProbe = await PermissionsCoordinator.requestScreenRecording()
        guard screenProbe.status == .granted else {
            var lines = [
                "Screen Recording access denied even though the toggle in System Settings may be on.",
                "On macOS this can mean TCC has a stale entry for an older build of WhisperCaption.",
                "",
                "Fix it from Terminal (one line):",
                "    tccutil reset ScreenCapture albond.WhisperCaption && tccutil reset Microphone albond.WhisperCaption",
                "",
                "Then quit WhisperCaption (⌘Q), relaunch, press Start, accept the fresh prompt, quit again, relaunch."
            ]
            if let detail = screenProbe.underlyingError {
                lines.append("")
                lines.append("Underlying error: \(detail)")
            }
            state = .error(lines.joined(separator: "\n"))
            return
        }

        // 2) Engine load. Skip the mic engine entirely when mic is disabled.
        let engineKind = settingsStore?.transcriptionEngine ?? .whisper
        let model = settingsStore?.whisperModel ?? .small
        let hint = settingsStore?.whisperVocabularyHint ?? ""
        let dgKey = settingsStore?.deepgramAPIKey ?? ""
        let elKey = settingsStore?.elevenLabsAPIKey ?? ""

        let modelFolder: URL? = settingsStore?.whisperModelFolderURL
        let tokenizerFolder: URL? = settingsStore?.whisperTokenizerFolderURL

        if engineKind == .whisper {
            guard let folder = modelFolder else {
                state = .error("WhisperKit is selected but no model folder is configured. Open Settings → Speech Recognition and choose a model folder.")
                return
            }
            _ = folder
        }

        // Before building anything fresh: if the preload pool has engines
        // that match the current configuration, adopt them and return —
        // their `prepare()` may already be done, so we'll skip the model
        // load entirely below.
        let preloadKey = currentWhisperConfigKey(captureMic: captureMic)
        let adoptedPreload: (mic: WhisperEngine?, system: WhisperEngine?)? = {
            guard engineKind == .whisper,
                  let key = preloadKey,
                  preloadedConfigKey == key,
                  let systemEng = preloadedSystemEngine else { return nil }
            let micEng = captureMic ? preloadedMicEngine : nil
            return (micEng, systemEng)
        }()

        let makeEngine: (CaptionSource) -> (any TranscriptionEngine)? = { source in
            switch engineKind {
            case .whisper:
                guard let folder = modelFolder else { return nil }
                return WhisperEngine(
                    source: source,
                    model: model,
                    vocabularyHint: hint,
                    modelFolder: folder,
                    tokenizerFolder: tokenizerFolder,
                    settings: self.languages
                )
            case .deepgram:
                return DeepgramEngine(source: source, apiKey: dgKey, vocabularyHint: hint, settings: self.languages)
            case .elevenlabs:
                return ElevenLabsEngine(source: source, apiKey: elKey, vocabularyHint: hint, settings: self.languages)
            }
        }

        let micEngine: (any TranscriptionEngine)? = {
            if let adopted = adoptedPreload?.mic { return adopted }
            return captureMic ? makeEngine(.microphone) : nil
        }()
        let systemEngineMaybe: (any TranscriptionEngine)? = {
            if let adopted = adoptedPreload?.system { return adopted }
            return makeEngine(.system)
        }()
        guard let systemEngine: any TranscriptionEngine = systemEngineMaybe else {
            state = .error("Could not initialise the chosen transcription engine. Check Settings → Speech Recognition.")
            return
        }
        if adoptedPreload != nil {
            // Caller owns these now; preload pool is empty until stop().
            preloadedMicEngine = nil
            preloadedSystemEngine = nil
            preloadedConfigKey = nil
            preloadTask?.cancel()
            preloadTask = nil
        }
        self.micEngine = micEngine
        self.systemEngine = systemEngine

        let loadingMessage: String = {
            switch engineKind {
            case .whisper:    return "Loading \(model.displayName)…"
            case .deepgram:   return "Connecting to Deepgram…"
            case .elevenlabs: return "Connecting to ElevenLabs…"
            }
        }()
        state = .loadingModel(progress: 0, message: loadingMessage)

        if let micEngine {
            async let micLoad: Void = micEngine.prepare()
            async let systemLoad: Void = systemEngine.prepare()
            _ = await (micLoad, systemLoad)
            if case .failed(let m) = await micEngine.loadStateSnapshot() {
                state = .error(m)
                return
            }
        } else {
            await systemEngine.prepare()
        }
        if case .failed(let m) = await systemEngine.loadStateSnapshot() {
            state = .error(m)
            return
        }

        // 3) Capture
        state = .starting
        let mic: MicCapture? = captureMic ? MicCapture() : nil
        let system = SystemCapture()
        mic?.setPreferredInput(uid: routing.preferredMicUID)
        system.setPreferredOutput(uid: routing.preferredOutputUID)
        self.micCapture = mic
        self.systemCapture = system

        if let mic {
            do {
                try mic.start()
            } catch {
                await teardown()
                state = .error("Microphone capture failed: \(String(describing: error))")
                return
            }
        }

        do {
            try await system.start()
        } catch {
            await teardown()
            state = .error("System audio capture failed: \(String(describing: error)). Did you grant Screen Recording and relaunch?")
            return
        }

        startPumps(mic: mic, system: system, micEngine: micEngine, systemEngine: systemEngine)

        let now = Date()
        startedAt = now
        startElapsedTimer(from: now)

        state = .running
        log.info("caption stream started (engine=\(engineKind.rawValue, privacy: .public) mic=\(captureMic, privacy: .public))")
    }

    func stop() async {
        guard state.isRunning else { return }
        state = .stopping

        elapsedTask?.cancel()
        elapsedTask = nil

        bubbleSilenceTask?.cancel()
        bubbleSilenceTask = nil
        bubbleSplitter.resetAll()

        micCapture?.stop()
        await systemCapture?.stop()

        await micPump?.value
        await systemPump?.value
        micPump = nil
        systemPump = nil

        await micEngine?.close()
        await systemEngine?.close()

        await micCaptionPump?.value
        await systemCaptionPump?.value
        micCaptionPump = nil
        systemCaptionPump = nil

        micCapture = nil
        systemCapture = nil
        micEngine = nil
        systemEngine = nil

        startedAt = nil
        state = .idle
        log.info("caption stream stopped")

        // Re-prime the Whisper engines (if still configured) so the next
        // Start is instant. No-op when the user is on a cloud engine.
        preloadWhisperIfNeeded()
    }

    /// Saves the current session to history and starts a fresh one.
    /// Pre-creates the session folder so it shows up in the picker even
    /// if the user never adds a caption.
    func newSession() {
        flushNow()
        let now = Date()
        if let history {
            let newID = history.newSessionID(at: now)
            activeSession = ChatSession(id: newID, createdAt: now)
            captions.removeAll()
            settingsStore?.activeChatID = newID
            history.save(activeSession)
            imageStore = history.imageStore(forSessionID: newID)
        } else {
            activeSession = ChatSession(id: ChatSession.idFormatter.string(from: now), createdAt: now)
            captions.removeAll()
            imageStore = nil
        }
    }

    /// Persists the current session and switches to the one with the
    /// given id. No-op if the id is already active or unknown.
    func activate(sessionID: String) {
        guard sessionID != activeSession.id else { return }
        flushNow()
        guard let history, let loaded = history.load(id: sessionID) else { return }
        activeSession = loaded
        captions = loaded.captions
        settingsStore?.activeChatID = sessionID
        imageStore = history.imageStore(forSessionID: sessionID)
    }

    /// Insert a screenshot bubble into the System column. PNG bytes are
    /// written through `ChatImageStore`; the caption keeps the resulting
    /// filename for re-loading from disk.
    ///
    /// Before inserting, any in-flight live bubble (mic or system) is
    /// finalised at its current text. Without that step the live bubble
    /// would carry a `startedAt` from the start of its phrase — earlier
    /// than the screenshot's own `startedAt` — and the timeline sort in
    /// the Main HUD would render the bubble ABOVE the screenshot.
    /// Worse, subsequent interim updates for the same phrase would keep
    /// extending that same bubble above the screenshot until the
    /// splitter's `maxChars` finally cut it. Treating a screenshot as a
    /// punctuation mark in the conversation gives a clean
    /// "before / image / after" timeline.
    func appendScreenshot(pngData: Data, label: String) {
        finalizeLiveBubbles()

        // Tell the running engines to drop their pending-audio buffer
        // and reset the current phrase. Why: the cloud engines keep a
        // rolling tail of un-committed audio (~60 s). If a network
        // reconnect lands AFTER the screenshot, that buffer is replayed
        // on the new socket and the server retranscribes it — the same
        // words we just finalised reappear as fresh bubbles below the
        // image. By cutting the buffer at the screenshot we treat the
        // already-shown text as authoritative and let the engine start
        // a clean phrase from this point. The mic engine gets the same
        // treatment for symmetry (and because the user could conceivably
        // be speaking while the screenshot is taken).
        if let mic = micEngine {
            Task { await mic.reset() }
        }
        if let sys = systemEngine {
            Task { await sys.reset() }
        }

        var filename: String?
        if let imageStore {
            do {
                filename = try imageStore.save(pngData: pngData)
            } catch {
                log.error("save screenshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let cap = Caption(
            source: .system,
            text: label,
            isFinal: true,
            imageFilename: filename
        )
        captions.append(cap)
        markDirty()
    }

    /// Close any in-flight live bubble for each audio source. Marks the
    /// bubble final at its current text, then asks the splitter to
    /// `finalize(source:)` — that bumps the splitter's `engineConsumed`
    /// to the current length AND mints a fresh `ourId` +
    /// `bubbleStartedAt`, so the next engine interim (even within the
    /// same phrase) opens a NEW bubble showing only the new content
    /// past the cutoff. Without this, a screenshot mid-phrase would
    /// "duplicate" the pre-screenshot text into the next bubble.
    private func finalizeLiveBubbles() {
        let now = Date()
        for source in [CaptionSource.microphone, CaptionSource.system] {
            guard let live = bubbleSplitter.liveBubble(for: source) else { continue }
            if let idx = captions.firstIndex(where: { $0.id == live.id }),
               !captions[idx].isFinal {
                captions[idx].isFinal = true
                captions[idx].updatedAt = now
            }
            bubbleSplitter.finalize(source: source)
        }
    }

    /// In-place set the translation on a caption identified by `id`.
    /// Used by `CaptionTranslator` once an Apple Translation session
    /// returns. No-op if the caption is no longer in the active session
    /// (chat switched between enqueue and completion). Triggers
    /// autosave so the translation persists with the chat history.
    ///
    /// `sourceText` is the bubble's text at the moment the translator
    /// kicked off this request. While Apple Translation runs (an
    /// `await` away) the bubble's text can change underneath us —
    /// engine emits more partials, BubbleSplitter cuts and shortens
    /// the head, etc. When that happens the returned translation
    /// reflects the OLD source text and is now misaligned with what
    /// the user sees. Drop it; CaptionTranslator will pick the bubble
    /// up again on its next poll, with the new source text.
    func setTranslation(_ text: String, sourceText: String, language: Language, forCaptionID id: UUID) {
        guard let idx = captions.firstIndex(where: { $0.id == id }) else { return }
        guard captions[idx].text == sourceText else { return }
        captions[idx].translation = text
        captions[idx].translationLanguage = language
        markDirty()
    }

    /// Clears the translation fields on a caption. Used by the Main HUD
    /// "Remove translation" context-menu item. The auto-translator may
    /// re-translate the caption afterwards if Translation is on and the
    /// caption matches the active selection — that's intentional, the
    /// menu only undoes the persisted result, not the auto pipeline's
    /// future behaviour.
    func clearTranslation(forCaptionID id: UUID) {
        guard let idx = captions.firstIndex(where: { $0.id == id }) else { return }
        captions[idx].translation = nil
        captions[idx].translationLanguage = nil
        markDirty()
    }

    /// Removes a caption from the active session. If it carries a
    /// screenshot the PNG file is dropped from `<session>/images/` too —
    /// the user explicitly chose "delete = forget". Best-effort on the
    /// file system: a missing PNG is silently ignored, an I/O error is
    /// logged but does not abort the in-memory removal (otherwise the
    /// caption would resurrect on the next render).
    func deleteCaption(_ id: UUID) {
        guard let idx = captions.firstIndex(where: { $0.id == id }) else { return }
        let cap = captions[idx]
        if let filename = cap.imageFilename, let imageStore {
            do {
                try imageStore.delete(filename: filename)
            } catch {
                log.warning("delete screenshot \(filename, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        captions.remove(at: idx)
        markDirty()
    }

    func dismissError() {
        if case .error = state { state = .idle }
    }

    // MARK: - History bridge

    private var autosaveTask: Task<Void, Never>?
    private var willTerminateObserver: NSObjectProtocol?

    /// Pending interval between the last caption change and the disk
    /// write. Whisper emits interim updates roughly every 1.2 s on the
    /// `small` model — 1.5 s lets a phrase finalize before the file is
    /// rewritten without losing a long pause halfway through.
    private let autosaveDebounce: TimeInterval = 1.5

    /// Restores the previously-active chat (if any) and registers a
    /// terminate observer so the in-flight session lands on disk when
    /// the user quits the app. Called from `attach(...)` once both the
    /// settings and history stores are wired up.
    private func bootstrapActiveSession() {
        guard let history else { return }

        if let prior = settingsStore?.activeChatID,
           !prior.isEmpty,
           let session = history.load(id: prior) {
            activeSession = session
            captions = session.captions
            imageStore = history.imageStore(forSessionID: session.id)
        } else {
            // No prior id or it points at a deleted file — open a fresh
            // session and write it through so the picker has something
            // to show on first launch.
            let now = Date()
            let newID = history.newSessionID(at: now)
            activeSession = ChatSession(id: newID, createdAt: now)
            captions.removeAll()
            settingsStore?.activeChatID = newID
            history.save(activeSession)
            imageStore = history.imageStore(forSessionID: newID)
        }

        if willTerminateObserver == nil {
            willTerminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushNow() }
            }
        }
    }

    /// Schedule a debounced disk write. Multiple calls inside the
    /// debounce window coalesce into a single save — protects the SSD
    /// from one write per Whisper tick during a long monologue.
    private func markDirty() {
        guard history != nil else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            let nanos = UInt64((self?.autosaveDebounce ?? 1.5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushNow() }
        }
    }

    /// Synchronous flush — used by `newSession()`, `activate(_:)`, and
    /// `NSApplication.willTerminateNotification`. Cancels any pending
    /// debounce since this call already wrote the latest state.
    func flushNow() {
        guard let history else { return }
        activeSession.captions = captions
        activeSession.updatedAt = Date()
        history.save(activeSession)
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    // MARK: - Pumps

    private func startPumps(
        mic: MicCapture?,
        system: SystemCapture,
        micEngine: (any TranscriptionEngine)?,
        systemEngine: any TranscriptionEngine
    ) {
        if let mic, let micEngine {
            micPump = Task {
                for await event in mic.events {
                    switch event {
                    case .samples(let s, let rms):
                        self.updateMicLevel(rms)
                        await micEngine.ingest(s)
                    case .error(let e):
                        self.flagError("Microphone error: \(e)")
                        return
                    }
                }
            }
            micCaptionPump = Task { [weak self] in
                for await caption in micEngine.captions {
                    guard let self else { return }
                    let config = self.currentSplitterConfig()
                    let outputs = self.bubbleSplitter.process(caption, config: config)
                    for c in outputs {
                        self.applyCaption(c)
                    }
                }
            }
        }
        systemPump = Task {
            for await event in system.events {
                switch event {
                case .samples(let s, let rms):
                    self.updateSystemLevel(rms)
                    await systemEngine.ingest(s)
                case .error(let e):
                    self.flagError("System audio error: \(e)")
                    return
                }
            }
        }
        systemCaptionPump = Task { [weak self] in
            for await caption in systemEngine.captions {
                guard let self else { return }
                let config = self.currentSplitterConfig()
                let outputs = self.bubbleSplitter.process(caption, config: config)
                for c in outputs {
                    self.applyCaption(c)
                }
            }
        }

        startBubbleSilenceTask()
    }

    private func currentSplitterConfig() -> BubbleSplitter.Config {
        BubbleSplitter.Config(
            maxChars: settingsStore?.bubbleMaxChars ?? SettingsStore.defaultBubbleMaxChars,
            sentenceAware: settingsStore?.bubbleSentenceAware ?? SettingsStore.defaultBubbleSentenceAware
        )
    }

    /// Background loop that finalises an in-flight bubble after
    /// `bubbleSilenceBreakSec` of inactivity. Picks up the slack when an
    /// engine doesn't emit a final fast enough on its own (Whisper waiting
    /// on internal silence detect, ElevenLabs sitting on a long-running
    /// utterance, etc.). Polls once a second — coarse enough to be cheap,
    /// fine enough that the perceived delay is bounded.
    private func startBubbleSilenceTask() {
        bubbleSilenceTask?.cancel()
        bubbleSilenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                self.checkBubbleSilence()
            }
        }
    }

    private func checkBubbleSilence() {
        let threshold = settingsStore?.bubbleSilenceBreakSec ?? SettingsStore.defaultBubbleSilenceBreakSec
        let now = Date()

        for source in [CaptionSource.microphone, CaptionSource.system] {
            guard let live = bubbleSplitter.liveBubble(for: source) else { continue }
            guard now.timeIntervalSince(live.lastUpdatedAt) >= threshold else { continue }
            // Find the live bubble in the array and mark it final. Engine
            // will keep emitting partials under its own id; the splitter
            // forgets the live id so subsequent emits land in a fresh bubble.
            if let idx = captions.firstIndex(where: { $0.id == live.id }), !captions[idx].isFinal {
                captions[idx].isFinal = true
                captions[idx].updatedAt = now
                bubbleSplitter.finalize(source: source)
                markDirty()
            }
        }
    }

    private func applyCaption(_ caption: Caption) {
        if let idx = captions.firstIndex(where: { $0.id == caption.id }) {
            var merged = caption
            // Carry-forward translation ONLY for ongoing (non-final)
            // interim updates. Without that, every interim wipes the
            // translation to nil and the CC HUD strobes between
            // translated / untranslated state. Final captions DON'T
            // carry forward: when the splitter cuts, the head bubble's
            // text shrinks but its previously-translated long version
            // would otherwise survive, leaving a short English bubble
            // with a much longer mismatched Russian translation. By
            // clearing the translation on the final emit we let
            // `CaptionTranslator` re-translate against the
            // authoritative final text.
            if !merged.isFinal,
               merged.translation == nil,
               captions[idx].translation != nil {
                merged.translation         = captions[idx].translation
                merged.translationLanguage = captions[idx].translationLanguage
            }
            captions[idx] = merged
        } else {
            captions.append(caption)
        }
        markDirty()
    }

    /// Peak-hold update: if a louder sample arrives, jump to it; otherwise
    /// the level decays in `decayLevels()` below. Decoupling decay from
    /// ingest lets the meter look smooth even between bursts.
    private func updateMicLevel(_ rms: Float) {
        if rms > micLevel { micLevel = rms }
    }

    private func updateSystemLevel(_ rms: Float) {
        if rms > systemLevel { systemLevel = rms }
    }

    private func decayLevels() {
        // Decays roughly from 1.0 → 0 over ~1 s when no new audio arrives.
        let factor: Float = 0.85
        micLevel *= factor
        systemLevel *= factor
        if micLevel < 0.0001 { micLevel = 0 }
        if systemLevel < 0.0001 { systemLevel = 0 }
    }

    private func flagError(_ message: String) {
        log.error("\(message, privacy: .public)")
    }

    private func startElapsedTimer(from start: Date) {
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.elapsedSeconds = Date().timeIntervalSince(start)
                self?.decayLevels()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func teardown() async {
        bubbleSilenceTask?.cancel()
        bubbleSilenceTask = nil
        bubbleSplitter.resetAll()
        micCapture?.stop()
        await systemCapture?.stop()
        micCapture = nil
        systemCapture = nil
        await micEngine?.close()
        await systemEngine?.close()
        micEngine = nil
        systemEngine = nil
    }

    // MARK: - Whisper preload

    /// Builds the snapshot of Whisper-relevant settings that drives the
    /// "is the preload still valid?" comparison. Returns nil if the user
    /// hasn't picked Whisper or hasn't pointed at a model folder yet
    /// (no preload to do).
    private func currentWhisperConfigKey(captureMic: Bool) -> WhisperConfigKey? {
        guard let s = settingsStore,
              s.transcriptionEngine == .whisper,
              let folder = s.whisperModelFolderURL else { return nil }
        return WhisperConfigKey(
            model: s.whisperModel,
            modelFolderPath: folder.path,
            tokenizerFolderPath: s.whisperTokenizerFolderURL?.path,
            vocabularyHint: s.whisperVocabularyHint,
            captureMic: captureMic
        )
    }

    /// Build (or rebuild) the preloaded WhisperEngines in the background.
    /// Idempotent: if a preload matching the current settings already
    /// exists, no work happens. If settings changed, the old preload is
    /// discarded (its model is released by ARC) and a fresh pair is
    /// prepared.
    private func preloadWhisperIfNeeded() {
        // Don't preload while a stream is running — the running engines
        // already hold the model; the preload would double the footprint.
        guard !state.isRunning, !state.isBusy else { return }

        let captureMic = settingsStore?.captureMicrophone ?? true
        let newKey = currentWhisperConfigKey(captureMic: captureMic)

        if newKey == nil {
            // User is on a cloud engine — make sure nothing is held.
            preloadTask?.cancel()
            preloadTask = nil
            if preloadedMicEngine != nil || preloadedSystemEngine != nil {
                let mic = preloadedMicEngine
                let system = preloadedSystemEngine
                preloadedMicEngine = nil
                preloadedSystemEngine = nil
                preloadedConfigKey = nil
                Task {
                    await mic?.close()
                    await system?.close()
                }
                log.info("whisper preload released (engine != whisper)")
            }
            return
        }

        if preloadedConfigKey == newKey {
            // Already preloaded for this exact config.
            return
        }

        // Configuration changed — drop old, build new.
        let oldMic = preloadedMicEngine
        let oldSystem = preloadedSystemEngine
        preloadedMicEngine = nil
        preloadedSystemEngine = nil
        preloadTask?.cancel()
        if oldMic != nil || oldSystem != nil {
            Task {
                await oldMic?.close()
                await oldSystem?.close()
            }
        }

        guard let s = settingsStore, let folder = s.whisperModelFolderURL else { return }
        let model = s.whisperModel
        let hint = s.whisperVocabularyHint
        let tokenizerFolder = s.whisperTokenizerFolderURL
        let willCaptureMic = captureMic

        let mic: WhisperEngine? = willCaptureMic ? WhisperEngine(
            source: .microphone,
            model: model,
            vocabularyHint: hint,
            modelFolder: folder,
            tokenizerFolder: tokenizerFolder,
            settings: languages
        ) : nil
        let system = WhisperEngine(
            source: .system,
            model: model,
            vocabularyHint: hint,
            modelFolder: folder,
            tokenizerFolder: tokenizerFolder,
            settings: languages
        )

        preloadedMicEngine = mic
        preloadedSystemEngine = system
        preloadedConfigKey = newKey

        let preloadKey = newKey
        log.info("whisper preload starting (model=\(model.rawValue, privacy: .public), mic=\(willCaptureMic, privacy: .public))")
        preloadTask = Task { [weak self] in
            // Both `prepare()` calls run concurrently — the model files
            // are the same so disk cache warms once.
            if let mic {
                async let micLoad: Void = mic.prepare()
                async let systemLoad: Void = system.prepare()
                _ = await (micLoad, systemLoad)
            } else {
                await system.prepare()
            }
            guard let self else { return }
            // Sanity: if settings flipped while we were preparing, our
            // result is stale — drop it. `preloadedConfigKey == nil` means
            // someone discarded us mid-flight too.
            if self.preloadedConfigKey != preloadKey {
                Task {
                    await mic?.close()
                    await system.close()
                }
            } else {
                self.log.info("whisper preload ready")
            }
        }
    }

    /// Re-runs `preloadWhisperIfNeeded()` whenever any Whisper-relevant
    /// setting changes (engine kind, model, model folder, etc.). Re-arms
    /// itself after each fire to keep listening.
    private func observeEngineSettingChanges() {
        withObservationTracking { [weak self] in
            guard let self, let s = self.settingsStore else { return }
            _ = s.transcriptionEngine
            _ = s.whisperModel
            _ = s.whisperModelFolderPath
            _ = s.whisperTokenizerFolderPath
            _ = s.whisperVocabularyHint
            _ = s.captureMicrophone
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.preloadWhisperIfNeeded()
                self?.observeEngineSettingChanges()
            }
        }
    }
}
