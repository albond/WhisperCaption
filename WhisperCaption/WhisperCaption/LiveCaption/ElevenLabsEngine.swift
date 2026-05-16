import Foundation
import OSLog

/// Cloud transcription via ElevenLabs Scribe v2 Realtime over WebSocket.
/// One engine instance = one logical stream that survives any number of
/// WebSocket disconnects: socket dies → we mint a new token, open a new
/// socket, replay un-committed audio, and keep going. The consumer
/// (CaptionStream) sees a single uninterrupted captions AsyncStream.
///
/// Auth flow:
///   1. POST /v1/single-use-token/realtime_scribe with `xi-api-key`.
///      URLSession's HTTP client honors custom headers fine.
///   2. Server returns a short-lived token.
///   3. Open the WebSocket with the token in the URL query string
///      (`?token=…`). URLSession passes URL components through verbatim,
///      so this avoids the WS-handshake-header-strip behaviour where
///      custom `Authorization` headers are silently dropped.
///
/// Wire format:
///   - We send 16 kHz mono Int16 PCM as JSON `input_audio_chunk` messages
///     with the audio base64-encoded in `audio_base_64`.
///   - Server replies with JSON tagged by `message_type`:
///       * "partial_transcript" → interim, keep updating same bubble.
///       * "committed_transcript" / "committed_transcript_with_timestamps"
///         → finalize the current bubble. We use this signal to drop the
///         tail buffer (server has acknowledged everything before this).
///
/// Reconnect strategy (designed for multi-hour sessions):
///   - Tail buffer: every ingested PCM chunk is also appended to a rolling
///     buffer (cap 60s). On `committed_transcript` we clear it. On
///     reconnect we replay the remaining un-committed audio into the new
///     socket so transcription resumes mid-phrase without losing words.
///   - Heartbeat: every 20s we send a WS PING. If the pong doesn't arrive
///     in 10s the socket is dead — trigger reconnect.
///   - Backoff: 0.5s → 1 → 2 → 4 → max 8s with ±20% jitter, infinite
///     retries (until close() is called).
///   - Fatal vs transient: HTTP 401/403 from the token endpoint stops
///     retries (the API key is bad — retrying won't help). Anything else
///     is treated as transient.
actor ElevenLabsEngine: TranscriptionEngine {

    /// Scribe v2 supports 90+ languages. We expose the user-pickable set
    /// here; the full set is available via omitted `language_code` (auto-detect).
    static let supportedLanguages: [Language] = Language.allCases

    private let log = Log.ElevenLabsEngine

    private let source: CaptionSource
    private let apiKey: String
    private let vocabularyHint: String
    private weak var settings: LanguageSettings?

    nonisolated let captions: AsyncStream<Caption>
    private let captionContinuation: AsyncStream<Caption>.Continuation

    private let webSocketFactory: WebSocketFactory
    private let httpClient: HTTPClient
    private var task: WebSocketTransport?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// Heartbeat tuning. Injectable so tests can run subsecond.
    private let heartbeatInterval: TimeInterval
    private let heartbeatPongTimeout: TimeInterval

    private var loadState: WhisperLoadState = .idle

    private var currentCaptionId: UUID?
    private var phraseStartedAt: Date?

    /// Connection lifecycle. `idle` before prepare, `connected` while a
    /// socket is healthy, `reconnecting` during backoff/handshake, `closed`
    /// after explicit close() (no more reconnect attempts).
    private enum ConnState {
        case idle
        case connected
        case reconnecting
        case closed
    }
    private var connState: ConnState = .idle

    /// Bumped on every (re)connect. Receive/heartbeat tasks capture the
    /// generation they were spawned for and exit silently if it changes —
    /// guards against zombie tasks holding references to a cancelled WS.
    private var generation: Int = 0

    /// Whether this session pins a single language (`language_code` set) or
    /// runs auto-detect (`language_code` omitted). In monolingual mode the
    /// per-message responses don't include `language_code` at all, so we
    /// tag every caption with the only language it could be — the one we
    /// requested. In multilingual mode we ask the server for language
    /// detection (`include_language_detection=true`) and read it off
    /// `committed_transcript_with_timestamps` messages — but partial
    /// transcripts never carry `language_code`, so we tag them with a
    /// best-effort fallback (the first selected language by sorted
    /// raw value) so `CaptionTranslator` can produce realtime translations
    /// instead of waiting for the final commit. The first commit overwrites
    /// the caption with the real detected language.
    private enum LanguageMode {
        case monolingual(Language)
        case multilingual(fallback: Language?)
    }
    private var currentLanguageMode: LanguageMode = .multilingual(fallback: nil)

    /// Rolling buffer of un-committed Int16-LE PCM. Grows on every ingest,
    /// truncated to 0 on every committed_transcript message, capped at
    /// 60s of audio (~1.9MB) FIFO-style if the server stops committing.
    private var pendingAudio = Data()
    private static let pendingAudioCapBytes = 60 * 16_000 * 2  // 60s @ 16kHz Int16

    /// Throttle for "send failed" log spam during the moment between socket
    /// death and the reconnect kicking in.
    private var lastSendErrorLogAt: Date?

    init(
        source: CaptionSource,
        apiKey: String,
        vocabularyHint: String = "",
        settings: LanguageSettings,
        webSocketFactory: WebSocketFactory? = nil,
        httpClient: HTTPClient? = nil,
        heartbeatInterval: TimeInterval = 20,
        heartbeatPongTimeout: TimeInterval = 10
    ) {
        self.source = source
        self.apiKey = apiKey
        self.vocabularyHint = vocabularyHint
        self.settings = settings
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatPongTimeout = heartbeatPongTimeout

        if let webSocketFactory, let httpClient {
            self.webSocketFactory = webSocketFactory
            self.httpClient = httpClient
        } else {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: config)
            self.webSocketFactory = webSocketFactory ?? URLSessionWebSocketFactory(session: session)
            self.httpClient = httpClient ?? URLSessionHTTPClient(session: session)
        }

        var localContinuation: AsyncStream<Caption>.Continuation!
        self.captions = AsyncStream(Caption.self, bufferingPolicy: .unbounded) { c in
            localContinuation = c
        }
        self.captionContinuation = localContinuation
    }

    func loadStateSnapshot() -> WhisperLoadState { loadState }

    // MARK: - Lifecycle

    func prepare() async {
        guard connState == .idle else { return }
        guard !apiKey.isEmpty else {
            loadState = .failed("ElevenLabs API key is not set. Open Settings → Speech Recognition and paste your key.")
            connState = .closed
            return
        }

        loadState = .loading(progress: 0, message: "Connecting to ElevenLabs…")

        let outcome = await connectOnce()
        switch outcome {
        case .success:
            connState = .connected
            loadState = .ready
            startHeartbeat()
        case .fatal(let message):
            loadState = .failed(message)
            connState = .closed
        case .transient(let message):
            // First connect failed but the error class is recoverable
            // (network, server hiccup). Don't surface as failed — kick
            // off the reconnect loop and let the user see captions appear
            // as soon as the network returns.
            log.error("elevenlabs initial connect transient: \(message, privacy: .public); reconnecting…")
            loadState = .ready
            connState = .reconnecting
            startReconnectLoop()
        }
    }

    func reset() {
        currentCaptionId = nil
        phraseStartedAt = nil
        pendingAudio.removeAll(keepingCapacity: true)
    }

    func close() {
        connState = .closed
        receiveLoop?.cancel()
        receiveLoop = nil
        heartbeatLoop?.cancel()
        heartbeatLoop = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        if let task {
            task.cancel(closeCode: .normalClosure, reason: nil)
        }
        task = nil
        pendingAudio.removeAll(keepingCapacity: false)
        // ONLY place that closes the captions stream — receive errors
        // trigger reconnect, not stream termination.
        captionContinuation.finish()
    }

    // MARK: - Connect

    private enum ConnectOutcome {
        case success
        /// Don't retry — API key is rejected etc.
        case fatal(String)
        /// Retry with backoff — network down, WS open failure, server 5xx.
        case transient(String)
    }

    /// One-shot: token → WebSocket → start receive loop. Caller decides
    /// what to do with the outcome (mark connected / start reconnect loop).
    private func connectOnce() async -> ConnectOutcome {
        // Step 1: mint a fresh single-use token. Each WS handshake needs
        // its own — the previous one is consumed.
        let tokenResult = await fetchSingleUseToken()
        let token: String
        switch tokenResult {
        case .success(let t):
            token = t
        case .failure(let problem):
            return problem.fatal ? .fatal(problem.message) : .transient(problem.message)
        }

        // Step 2: read the language chips (MainActor hop) and map.
        let settingsRef = self.settings
        let selected: Set<Language> = await MainActor.run {
            settingsRef?.selectedLanguages ?? [.en]
        }
        let (langCode, mode) = Self.elevenlabsLanguage(for: selected)
        self.currentLanguageMode = mode

        // Step 3: build the WebSocket URL.
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "token",            value: token),
            URLQueryItem(name: "model_id",         value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format",     value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy",  value: "vad"),
            URLQueryItem(name: "no_verbatim",      value: "true"),
        ]
        if let langCode {
            items.append(URLQueryItem(name: "language_code", value: langCode))
        }
        if case .multilingual = mode {
            // Without this flag the server never includes language_code in
            // transcript messages, so we'd have no way to tell which language
            // each caption is. Only meaningful when we let the server detect.
            items.append(URLQueryItem(name: "include_language_detection", value: "true"))
        }
        let keyterms = Self.parseKeyterms(from: vocabularyHint, limit: 50, maxLen: 20)
        for term in keyterms {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        components.queryItems = items
        guard let url = components.url else {
            return .fatal("Internal: failed to build ElevenLabs URL")
        }

        // Bump generation BEFORE installing the new task, so any straggler
        // task from the previous socket sees a stale generation and exits.
        generation &+= 1
        let myGen = generation

        let newTask = webSocketFactory.open(url: url, protocols: [])
        self.task = newTask

        log.info("elevenlabs websocket opened: source=\(self.source.rawValue, privacy: .public) lang=\(langCode ?? "auto", privacy: .public) keyterms=\(keyterms.count) gen=\(myGen)")

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(generation: myGen)
        }

        // Step 4: replay anything we held back during the disconnect.
        // Done BEFORE returning .success so the caller can flip to
        // .connected and ingest() can immediately start streaming new
        // audio without races.
        await flushPendingAudio(generation: myGen)

        return .success
    }

    // MARK: - Reconnect

    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    private func runReconnectLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            // Bail if state moved to .closed (user pressed Stop) or
            // somehow back to .connected (impossible from here, but defensive).
            if connState != .reconnecting { return }

            let delay = Self.backoffDelay(attempt: attempt)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if connState != .reconnecting { return }

            let outcome = await connectOnce()
            switch outcome {
            case .success:
                connState = .connected
                log.info("elevenlabs reconnected after attempt \(attempt + 1) (delay≈\(String(format: "%.1f", delay))s)")
                startHeartbeat()
                return
            case .fatal(let msg):
                log.error("elevenlabs reconnect fatal: \(msg, privacy: .public)")
                loadState = .failed(msg)
                connState = .closed
                return
            case .transient(let msg):
                attempt += 1
                if attempt == 1 || attempt % 5 == 0 {
                    log.error("elevenlabs reconnect attempt \(attempt) failed: \(msg, privacy: .public)")
                }
            }
        }
    }

    /// 0.5 → 1 → 2 → 4 → 8 (capped) with ±20% jitter.
    private nonisolated static func backoffDelay(attempt: Int) -> Double {
        let base = min(8.0, 0.5 * pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0.8...1.2)
        return base * jitter
    }

    /// Idempotent: triggers a reconnect if we're currently .connected.
    /// Calls from .reconnecting / .closed are no-ops.
    private func triggerReconnect(reason: String) {
        guard connState == .connected else { return }
        log.error("elevenlabs disconnected: \(reason, privacy: .public); reconnecting…")
        connState = .reconnecting
        receiveLoop?.cancel()
        receiveLoop = nil
        heartbeatLoop?.cancel()
        heartbeatLoop = nil
        if let t = task {
            t.cancel(closeCode: .abnormalClosure, reason: nil)
        }
        task = nil
        startReconnectLoop()
    }

    // MARK: - Token

    private struct TokenResponse: Decodable {
        let token: String?
        let access_token: String?
        var value: String? { token ?? access_token }
    }

    private struct TokenError: Error {
        let message: String
        let fatal: Bool
    }

    private func fetchSingleUseToken() async -> Result<String, TokenError> {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe") else {
            return .failure(TokenError(message: "Internal: failed to build token URL", fatal: true))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = "{}".data(using: .utf8)

        do {
            let (data, response) = try await httpClient.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(TokenError(message: "ElevenLabs returned a non-HTTP response.", fatal: false))
            }
            if http.statusCode == 401 {
                return .failure(TokenError(message: "ElevenLabs rejected the API key (HTTP 401). Open Settings → Speech Recognition and paste a fresh key from elevenlabs.io → API Keys.", fatal: true))
            }
            if http.statusCode == 403 {
                return .failure(TokenError(message: "ElevenLabs refused access (HTTP 403). Check key permissions / workspace.", fatal: true))
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                // 5xx and other unknowns: treat as transient.
                return .failure(TokenError(message: "ElevenLabs token endpoint HTTP \(http.statusCode): \(body.prefix(200))", fatal: false))
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard let token = decoded.value, !token.isEmpty else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(TokenError(message: "ElevenLabs token response missing `token` field. Body: \(body.prefix(200))", fatal: true))
            }
            return .success(token)
        } catch {
            return .failure(TokenError(message: "Network error talking to ElevenLabs: \(error.localizedDescription)", fatal: false))
        }
    }

    // MARK: - Ingest

    func ingest(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        guard connState != .closed && connState != .idle else { return }

        let pcm = Self.float32ToInt16LE(samples)

        // ALWAYS append to pending buffer first. If the socket is mid-flap
        // we'll replay this from flushPendingAudio on reconnect.
        pendingAudio.append(pcm)
        if pendingAudio.count > Self.pendingAudioCapBytes {
            let excess = pendingAudio.count - Self.pendingAudioCapBytes
            pendingAudio.removeFirst(excess)
        }

        // Only attempt to send when we believe the socket is alive.
        guard connState == .connected, let task else { return }

        guard let payload = Self.makeChunkEnvelope(pcm: pcm) else { return }
        do {
            try await task.send(payload)
        } catch {
            // Throttle log: one line per second max during a flap.
            let now = Date()
            if lastSendErrorLogAt.map({ now.timeIntervalSince($0) >= 1.0 }) ?? true {
                log.error("elevenlabs send failed: \(error.localizedDescription, privacy: .public)")
                lastSendErrorLogAt = now
            }
            triggerReconnect(reason: "send failed: \(error.localizedDescription)")
        }
    }

    /// Replay un-committed audio after a fresh socket is open. Sends the
    /// whole tail buffer as one envelope — the 60s cap of ~1.9MB fits well
    /// under any reasonable WS frame limit.
    private func flushPendingAudio(generation g: Int) async {
        guard g == generation, let task else { return }
        guard !pendingAudio.isEmpty else { return }
        let bytes = pendingAudio.count
        guard let payload = Self.makeChunkEnvelope(pcm: pendingAudio) else { return }
        do {
            try await task.send(payload)
            log.info("elevenlabs replayed \(bytes) bytes of pending audio after reconnect")
        } catch {
            log.error("elevenlabs replay failed: \(error.localizedDescription, privacy: .public)")
            // Don't clear pendingAudio — next reconnect will try again.
        }
    }

    private nonisolated static func makeChunkEnvelope(pcm: Data) -> String? {
        let b64 = pcm.base64EncodedString()
        let envelope: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": b64,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Receive

    private func runReceiveLoop(generation g: Int) async {
        while !Task.isCancelled {
            guard let t = self.taskIfCurrent(generation: g) else { return }
            do {
                let message = try await t.receive()
                await self.handle(message: message, generation: g)
            } catch {
                self.onReceiveError(error, generation: g)
                return
            }
        }
    }

    private func taskIfCurrent(generation g: Int) -> WebSocketTransport? {
        guard g == generation else { return nil }
        return task
    }

    private func onReceiveError(_ error: Error, generation g: Int) {
        // Stale generation means a newer socket already took over; this
        // task is just shutting down. Don't trigger another reconnect.
        guard g == generation else { return }
        triggerReconnect(reason: "recv failed: \(error.localizedDescription)")
    }

    private func handle(message: WebSocketTransportMessage, generation g: Int) async {
        guard g == generation else { return }
        switch message {
        case .string(let text):
            await parseAndEmit(json: text)
        case .data(let data):
            if let s = String(data: data, encoding: .utf8) {
                await parseAndEmit(json: s)
            }
        }
    }

    private struct ELMessage: Decodable {
        let message_type: String?
        let text: String?
        let language_code: String?
    }

    private func parseAndEmit(json: String) async {
        guard let data = json.data(using: .utf8) else { return }
        let decoded: ELMessage
        do {
            decoded = try JSONDecoder().decode(ELMessage.self, from: data)
        } catch {
            return
        }
        let type = decoded.message_type ?? ""
        let text = (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let isFinal: Bool
        switch type {
        case "partial_transcript":
            isFinal = false
        case "committed_transcript", "committed_transcript_with_timestamps":
            isFinal = true
            // Server has acknowledged everything up to this point. Drop
            // the tail buffer so we don't replay already-transcribed audio
            // on the next reconnect.
            pendingAudio.removeAll(keepingCapacity: true)
        default:
            return
        }

        let detected: Language? = {
            switch currentLanguageMode {
            case .monolingual(let lang):
                // Server omits language_code in single-language sessions.
                // We requested exactly this language — every caption is it.
                return lang
            case .multilingual(let fallback):
                // Only `committed_transcript_with_timestamps` carries
                // `language_code` (and only when include_language_detection
                // is on). For partials we use the configured fallback so
                // the translator can produce realtime translations; the
                // first commit overwrites caption.language with the real
                // detection result.
                if let lc = decoded.language_code?.lowercased() {
                    return Self.captionLanguage(fromIsoCode: lc)
                }
                return fallback
            }
        }()

        let settingsRef = self.settings
        let accepted: Bool = await MainActor.run {
            settingsRef?.accepts(detected) ?? true
        }
        if !accepted { return }

        let id = currentCaptionId ?? UUID()
        if currentCaptionId == nil {
            currentCaptionId = id
            phraseStartedAt = Date()
        }
        let started = phraseStartedAt ?? Date()

        let caption = Caption(
            id: id,
            source: source,
            text: text,
            language: detected,
            isFinal: isFinal,
            startedAt: started,
            updatedAt: Date()
        )
        captionContinuation.yield(caption)

        if isFinal {
            currentCaptionId = nil
            phraseStartedAt = nil
        }
    }

    // MARK: - Heartbeat

    /// Active probing: send a WS PING every 20s and treat a missing pong
    /// (or a send error on the ping itself) as a dead socket. Without this,
    /// home/corporate routers that drop idle TCP after ~60-120s of silence
    /// stay "successfully open" on our side until the user speaks again,
    /// at which point we'd lose those words.
    private func startHeartbeat() {
        heartbeatLoop?.cancel()
        let myGen = generation
        let interval = heartbeatInterval
        heartbeatLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.sendHeartbeat(generation: myGen)
            }
        }
    }

    private func sendHeartbeat(generation g: Int) async {
        guard g == generation, connState == .connected, let task else { return }
        let timeout = heartbeatPongTimeout

        // Race the ping completion against a heartbeat-timeout. We use a
        // TaskGroup of Bool returns so a single first-result wins; the
        // loser is cancelled.
        let alive = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                let err = await task.sendPing()
                return err == nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !alive {
            // Don't double-trigger if a recv error already moved us out
            // of .connected during the 10s race.
            if connState == .connected, g == generation {
                triggerReconnect(reason: "heartbeat timeout")
            }
        }
    }

    // MARK: - Helpers

    /// Scribe v2 uses ISO 639-3 codes. When exactly one language is selected,
    /// lock decoding to it; with 0/2+ selected, omit the parameter and let
    /// the server auto-detect across its full 90+ supported languages.
    ///
    /// Returns the wire-format `language_code` (or nil when auto-detect) and
    /// the matching `LanguageMode`. For multilingual mode we also pick a
    /// best-effort fallback language (first sorted entry of the selection)
    /// so partial transcripts — which never carry `language_code` — still
    /// arrive with a guess the translator can act on.
    private nonisolated static func elevenlabsLanguage(
        for selected: Set<Language>
    ) -> (code: String?, mode: LanguageMode) {
        if selected.count == 1, let only = selected.first {
            return (only.iso639_3, .monolingual(only))
        }
        let fallback = selected.sorted { $0.rawValue < $1.rawValue }.first
        return (nil, .multilingual(fallback: fallback))
    }

    private nonisolated static func captionLanguage(fromIsoCode code: String) -> Language? {
        // Try ISO 639-1 first; fall back to matching against ISO 639-3.
        if let lang = Language(rawValue: code) { return lang }
        return Language.allCases.first { $0.iso639_3 == code }
    }

    private nonisolated static func parseKeyterms(from raw: String, limit: Int, maxLen: Int) -> [String] {
        let parts = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxLen }
        var seen = Set<String>()
        var out: [String] = []
        for term in parts {
            let key = term.lowercased()
            if seen.insert(key).inserted {
                out.append(term)
                if out.count >= limit { break }
            }
        }
        return out
    }

    private nonisolated static func float32ToInt16LE(_ samples: [Float]) -> Data {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                let clamped = max(-1.0, min(1.0, samples[i]))
                dst[i] = Int16(clamped * 32767).littleEndian
            }
        }
        return out
    }
}
