import Foundation
import OSLog

/// Cloud transcription via Deepgram Nova-3 streaming over WebSocket.
/// One engine instance = one logical stream that survives any number of
/// WebSocket disconnects: socket dies → we open a new socket, replay
/// un-finalized audio, and keep going. The consumer sees a single
/// uninterrupted captions AsyncStream.
///
/// Auth: Deepgram supports `Sec-WebSocket-Protocol: token, <api_key>` as
/// an alternate auth method (plain `Authorization` headers are silently
/// stripped by URLSessionWebSocketTask during the handshake). We pass the
/// protocols to `webSocketTask(with:url:protocols:)`.
///
/// Wire format:
///   - We send 16 kHz mono Int16 PCM (linear16) as binary frames.
///   - Deepgram streams JSON text frames back. `is_final = true` is the
///     phrase boundary signal — we treat it as a "commit" and drop the
///     tail buffer at that point (same role as ElevenLabs's
///     committed_transcript).
///
/// Reconnect strategy: identical to ElevenLabsEngine — see that file's
/// header comment for the full rationale (tail buffer, heartbeat, backoff,
/// generation counter). Deepgram-specific differences:
///   - No token endpoint; auth is in the WS subprotocol header.
///   - Pre-flight `validateAPIKey` is run only on the very first prepare()
///     so the user gets a clear "wrong key" message. Reconnects skip it
///     (the key was already valid; if Deepgram revokes mid-session the
///     WS will refuse and we'll surface that on next ingest).
///   - Send is binary (`.data(pcm)`), not JSON.
actor DeepgramEngine: TranscriptionEngine {

    /// Union of Nova-3's multilingual real-time set and its monolingual
    /// coverage. Multilingual (single session, auto-detected code-switching):
    /// en, es, fr, de, hi, ru, pt, ja, it, nl — the engine pools these into
    /// one multilingual stream when ≥ 2 of them are selected. Anything else
    /// in the list below works monolingually only: pick exactly one and the
    /// engine locks to that language. Picking multiple including a
    /// non-multilingual entry forces a monolingual fallback (see the
    /// Ukrainian special-case warning in `SpeechRecognitionSection`).
    static let supportedLanguages: [Language] = [
        .bg, .ca, .cs, .da, .de, .el, .en, .es, .et, .fi,
        .fr, .hi, .hu, .id, .it, .ja, .ko, .lt, .lv, .ms,
        .nl, .no, .pl, .pt, .ro, .ru, .sk, .sv, .ta, .th,
        .tr, .uk, .vi, .zh
    ]

    private let log = Log.DeepgramEngine

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

    /// How long a heartbeat has to come back before we declare the socket
    /// dead. Injectable so soak/unit tests can shorten it.
    private let heartbeatPongTimeout: TimeInterval

    /// Cadence of outbound PINGs. Same rationale.
    private let heartbeatInterval: TimeInterval

    private var loadState: WhisperLoadState = .idle

    private var currentCaptionId: UUID?
    private var phraseStartedAt: Date?

    private enum ConnState {
        case idle
        case connected
        case reconnecting
        case closed
    }
    private var connState: ConnState = .idle
    private var generation: Int = 0

    /// Whether this connection talks to Nova-3 in single-language or
    /// multilingual mode. In monolingual mode Deepgram doesn't echo the
    /// language back on each result; we know it anyway because the user
    /// picked exactly one, so we tag every caption with it ourselves. In
    /// multilingual mode we read `languages[0]` off the alternative.
    private enum LanguageMode {
        case monolingual(Language)
        case multilingual
    }
    private var currentLanguageMode: LanguageMode = .multilingual

    /// Rolling buffer of un-finalized Int16-LE PCM. Cleared on `is_final`.
    /// Capped at 60s (~1.9MB) FIFO to defend against memory bloat if
    /// Deepgram stops finalizing for some reason.
    private var pendingAudio = Data()
    private static let pendingAudioCapBytes = 60 * 16_000 * 2

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
            loadState = .failed("Deepgram API key is not set. Open Settings → Speech Recognition and paste your key.")
            connState = .closed
            return
        }

        loadState = .loading(progress: 0, message: "Connecting to Deepgram…")

        // Pre-flight ONLY on the first prepare. The WebSocket layer hides
        // auth failures behind a generic "bad response" — without this
        // we'd dump useless error spam into reconnect loops with a wrong
        // key forever.
        if let problem = await validateAPIKey() {
            loadState = .failed(problem)
            connState = .closed
            return
        }

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
            log.error("deepgram initial connect transient: \(message, privacy: .public); reconnecting…")
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
            // Tell Deepgram to flush before we yank the socket. Fire-and-
            // forget — we don't await because close() is sync.
            Task {
                try? await task.send("{\"type\":\"CloseStream\"}")
                task.cancel(closeCode: .normalClosure, reason: nil)
            }
        }
        task = nil
        pendingAudio.removeAll(keepingCapacity: false)
        captionContinuation.finish()
    }

    // MARK: - Pre-flight

    private func validateAPIKey() async -> String? {
        guard let url = URL(string: "https://api.deepgram.com/v1/projects") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await httpClient.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Deepgram returned a non-HTTP response."
            }
            if http.statusCode == 401 {
                let body = String(data: data, encoding: .utf8) ?? ""
                log.error("deepgram preflight 401: \(body, privacy: .public)")
                return "Deepgram rejected the API key (HTTP 401). Open Settings → Speech Recognition and paste a fresh key from console.deepgram.com → API Keys."
            }
            if http.statusCode == 403 {
                return "Deepgram refused access (HTTP 403). Verify the key has streaming permissions on its project."
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                return "Deepgram preflight HTTP \(http.statusCode): \(body.prefix(200))"
            }
            return nil
        } catch {
            return "Network error reaching Deepgram: \(error.localizedDescription)"
        }
    }

    // MARK: - Connect

    private enum ConnectOutcome {
        case success
        case fatal(String)
        case transient(String)
    }

    private func connectOnce() async -> ConnectOutcome {
        let settingsRef = self.settings
        let selected: Set<Language> = await MainActor.run {
            settingsRef?.selectedLanguages ?? [.en]
        }
        let (langParam, mode) = Self.deepgramLanguage(for: selected)
        self.currentLanguageMode = mode

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model",            value: "nova-3"),
            URLQueryItem(name: "language",         value: langParam),
            URLQueryItem(name: "encoding",         value: "linear16"),
            URLQueryItem(name: "sample_rate",      value: "16000"),
            URLQueryItem(name: "channels",         value: "1"),
            URLQueryItem(name: "interim_results",  value: "true"),
            URLQueryItem(name: "smart_format",     value: "true"),
            URLQueryItem(name: "punctuate",        value: "true"),
            URLQueryItem(name: "endpointing",      value: "300"),
        ]
        let keyterms = Self.parseKeyterms(from: vocabularyHint, limit: 100)
        for term in keyterms {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items
        guard let url = components.url else {
            return .fatal("Internal: failed to build Deepgram URL")
        }

        generation &+= 1
        let myGen = generation

        // Subprotocol-based auth — Authorization headers are stripped by
        // URLSessionWebSocketTask during the handshake.
        let newTask = webSocketFactory.open(url: url, protocols: ["token", apiKey])
        self.task = newTask

        log.info("deepgram websocket opened: source=\(self.source.rawValue, privacy: .public) lang=\(langParam, privacy: .public) keyterms=\(keyterms.count) gen=\(myGen)")

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(generation: myGen)
        }

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
            if connState != .reconnecting { return }
            let delay = Self.backoffDelay(attempt: attempt)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if connState != .reconnecting { return }

            let outcome = await connectOnce()
            switch outcome {
            case .success:
                connState = .connected
                log.info("deepgram reconnected after attempt \(attempt + 1) (delay≈\(String(format: "%.1f", delay))s)")
                startHeartbeat()
                return
            case .fatal(let msg):
                log.error("deepgram reconnect fatal: \(msg, privacy: .public)")
                loadState = .failed(msg)
                connState = .closed
                return
            case .transient(let msg):
                attempt += 1
                if attempt == 1 || attempt % 5 == 0 {
                    log.error("deepgram reconnect attempt \(attempt) failed: \(msg, privacy: .public)")
                }
            }
        }
    }

    private nonisolated static func backoffDelay(attempt: Int) -> Double {
        let base = min(8.0, 0.5 * pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0.8...1.2)
        return base * jitter
    }

    private func triggerReconnect(reason: String) {
        guard connState == .connected else { return }
        log.error("deepgram disconnected: \(reason, privacy: .public); reconnecting…")
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

    // MARK: - Ingest

    func ingest(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        guard connState != .closed && connState != .idle else { return }

        let pcm = Self.float32ToInt16LE(samples)

        pendingAudio.append(pcm)
        if pendingAudio.count > Self.pendingAudioCapBytes {
            let excess = pendingAudio.count - Self.pendingAudioCapBytes
            pendingAudio.removeFirst(excess)
        }

        guard connState == .connected, let task else { return }
        do {
            try await task.send(pcm)
        } catch {
            let now = Date()
            if lastSendErrorLogAt.map({ now.timeIntervalSince($0) >= 1.0 }) ?? true {
                log.error("deepgram send failed: \(error.localizedDescription, privacy: .public)")
                lastSendErrorLogAt = now
            }
            triggerReconnect(reason: "send failed: \(error.localizedDescription)")
        }
    }

    private func flushPendingAudio(generation g: Int) async {
        guard g == generation, let task else { return }
        guard !pendingAudio.isEmpty else { return }
        let bytes = pendingAudio.count
        do {
            try await task.send(pendingAudio)
            log.info("deepgram replayed \(bytes) bytes of pending audio after reconnect")
        } catch {
            log.error("deepgram replay failed: \(error.localizedDescription, privacy: .public)")
        }
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

    private func taskIfCurrent(generation g: Int) -> WebSocketTransport? {
        guard g == generation else { return nil }
        return task
    }

    private func onReceiveError(_ error: Error, generation g: Int) {
        guard g == generation else { return }
        triggerReconnect(reason: "recv failed: \(error.localizedDescription)")
    }

    // MARK: - JSON → Caption

    private struct DGResults: Decodable {
        let type: String?
        let isFinal: Bool?
        let channel: DGChannel?
        enum CodingKeys: String, CodingKey {
            case type, channel
            case isFinal = "is_final"
        }
    }
    private struct DGChannel: Decodable {
        let alternatives: [DGAlt]?
    }
    private struct DGAlt: Decodable {
        let transcript: String?
        let confidence: Double?
        let languages: [String]?
    }

    private func parseAndEmit(json: String) async {
        guard let data = json.data(using: .utf8) else { return }
        let decoded: DGResults
        do {
            decoded = try JSONDecoder().decode(DGResults.self, from: data)
        } catch {
            return
        }
        guard decoded.type == "Results" else { return }
        guard let alt = decoded.channel?.alternatives?.first else { return }
        let text = (alt.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let detected: Language? = {
            switch currentLanguageMode {
            case .monolingual(let lang):
                // The server doesn't echo the language in single-language
                // mode, but we know what it is — that's what we requested.
                return lang
            case .multilingual:
                guard let first = alt.languages?.first else { return nil }
                return Language(rawValue: first)
            }
        }()

        let settingsRef = self.settings
        let accepted: Bool = await MainActor.run {
            settingsRef?.accepts(detected) ?? true
        }
        if !accepted { return }

        let isFinal = decoded.isFinal ?? false
        if isFinal {
            // Server has finalized the phrase — drop tail buffer so the
            // next reconnect doesn't replay already-transcribed audio.
            pendingAudio.removeAll(keepingCapacity: true)
        }

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
            if connState == .connected, g == generation {
                triggerReconnect(reason: "heartbeat timeout")
            }
        }
    }

    // MARK: - Helpers

    /// Nova-3 multilingual covers en/es/fr/de/hi/ru/pt/ja/it/nl but NOT
    /// Ukrainian. If `uk` is in the selection, fall back to monolingual
    /// `uk` even when other languages are also selected — we lose
    /// code-switching, but there is no Deepgram code that honours
    /// `uk + anything else`.
    ///
    /// Returns both the query-string parameter for `language=…` and the
    /// matching `LanguageMode` so the receive path knows whether to take
    /// the language from the API (`multi`) or pin it locally to the only
    /// possible value (`monolingual`).
    private nonisolated static func deepgramLanguage(
        for selected: Set<Language>
    ) -> (param: String, mode: LanguageMode) {
        if selected.count == 1, let only = selected.first {
            return (only.rawValue, .monolingual(only))
        }
        if selected.contains(.uk) {
            return ("uk", .monolingual(.uk))
        }
        return ("multi", .multilingual)
    }

    private nonisolated static func parseKeyterms(from raw: String, limit: Int) -> [String] {
        let parts = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
                let i16 = Int16(clamped * 32767)
                dst[i] = i16.littleEndian
            }
        }
        return out
    }
}
