import Foundation

/// Thin protocol around what the cloud STT engines (Deepgram, ElevenLabs)
/// need from `URLSessionWebSocketTask`. Lets unit tests drop in a fake
/// socket that never touches the network and lets us simulate disconnects,
/// silent peers, and replay scenarios without paying for real provider
/// traffic during a long soak test.
///
/// Production code keeps using the URLSession-backed implementation through
/// the default-parameter init on each engine — no callsite change required.
///
/// Note: an *engine* is one logical stream that survives many reconnects.
/// A *transport* is a single physical socket. The engine asks the factory
/// to mint a fresh transport on each (re)connect via `WebSocketFactory`.

// MARK: - Transport

/// One open WebSocket. Closed exactly once by the engine via `cancel(...)`.
/// Methods are async to mirror `URLSessionWebSocketTask`'s callback API.
///
/// `nonisolated`: engines are actors and call into this from non-MainActor
/// contexts. URLSession's own methods are themselves nonisolated under the
/// hood — this protocol mirrors that.
nonisolated protocol WebSocketTransport: Sendable {
    /// Send a binary frame. Throws on transport failure (broken pipe, etc.).
    func send(_ data: Data) async throws

    /// Send a text frame. Used by ElevenLabs JSON envelopes; Deepgram
    /// only sends binary but exposes a "CloseStream" string at teardown.
    func send(_ text: String) async throws

    /// Receive the next frame. Throws on transport failure or remote close.
    func receive() async throws -> WebSocketTransportMessage

    /// Send a WebSocket PING. Calls back with `nil` on pong, error otherwise.
    /// Mirrors `URLSessionWebSocketTask.sendPing(pongReceiveHandler:)`.
    func sendPing() async -> Error?

    /// Close the socket. After this call no further methods should be
    /// invoked on this instance.
    func cancel(closeCode: WebSocketTransportCloseCode, reason: Data?)
}

nonisolated enum WebSocketTransportMessage: Sendable {
    case data(Data)
    case string(String)
}

nonisolated enum WebSocketTransportCloseCode: Sendable {
    case normalClosure
    case abnormalClosure
}

// MARK: - Factory

/// Mints a fresh transport on each (re)connect. Engines hold a factory,
/// not a transport, so reconnect logic stays the same regardless of
/// whether the socket is real or mocked.
nonisolated protocol WebSocketFactory: Sendable {
    /// `protocols` becomes `Sec-WebSocket-Protocol` in the upgrade
    /// handshake — Deepgram uses this for token auth.
    func open(url: URL, protocols: [String]) -> WebSocketTransport
}

// MARK: - URLSession default implementations

/// Default URLSession-backed factory. Used everywhere in production.
nonisolated struct URLSessionWebSocketFactory: WebSocketFactory {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func open(url: URL, protocols: [String]) -> WebSocketTransport {
        let task: URLSessionWebSocketTask
        if protocols.isEmpty {
            task = session.webSocketTask(with: url)
        } else {
            task = session.webSocketTask(with: url, protocols: protocols)
        }
        task.resume()
        return URLSessionWebSocketTransport(task: task)
    }
}

nonisolated final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> WebSocketTransportMessage {
        let msg = try await task.receive()
        switch msg {
        case .data(let d):   return .data(d)
        case .string(let s): return .string(s)
        @unknown default:    return .data(Data())
        }
    }

    func sendPing() async -> Error? {
        await withCheckedContinuation { (cont: CheckedContinuation<Error?, Never>) in
            task.sendPing { err in
                cont.resume(returning: err)
            }
        }
    }

    func cancel(closeCode: WebSocketTransportCloseCode, reason: Data?) {
        let code: URLSessionWebSocketTask.CloseCode = {
            switch closeCode {
            case .normalClosure:   return .normalClosure
            case .abnormalClosure: return .abnormalClosure
            }
        }()
        task.cancel(with: code, reason: reason)
    }
}
