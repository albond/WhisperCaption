import Foundation
@testable import WhisperCaption

/// Scriptable WebSocket fake used by engine reconnect / data-loss tests.
///
/// Tests drive the fake from two sides:
///   * Outbound: read `sentFrames` to verify what the engine sent (audio
///     replays after reconnect, control envelopes, etc.).
///   * Inbound:  call `enqueueReceive(_:)` to feed messages or
///     `enqueueReceiveError(_:)` to make the next `receive()` throw —
///     that's how a test simulates a dropped socket.
///
/// Mirrors `URLSessionWebSocketTransport`'s shape: `final class` with a
/// lock-guarded inner state. The actual WebSocketTransport protocol is
/// `nonisolated` + `Sendable`, and a `final class … @unchecked Sendable`
/// is the only way to satisfy the synchronous `cancel(...)` requirement
/// without leaking concurrency unsafety.
final class MockWebSocketTransport: WebSocketTransport, @unchecked Sendable {

    enum Frame: Sendable, Equatable {
        case data(Data)
        case text(String)
    }

    private let lock = NSLock()
    private var _sentFrames: [Frame] = []
    private var _receiveQueue: [WebSocketTransportMessage] = []
    private var _receiveErrors: [Error] = []
    private var _pendingReceives: [CheckedContinuation<WebSocketTransportMessage, Error>] = []
    private var _cancelled = false
    private var _cancelCount = 0
    private var _pingCount = 0
    private var _pongResult: Error? = nil
    private var _sendError: Error? = nil

    /// Identifier used by tests that need to distinguish transports across
    /// reconnects (assigned by the factory when it mints the instance).
    let id: Int

    init(id: Int = 0) {
        self.id = id
    }

    // MARK: - Test driver API (called from test code, not the engine)

    /// Read the frames the engine has sent to this socket so far.
    var sentFrames: [Frame] { lock.withLock { _sentFrames } }

    /// True after `cancel(...)` was called at least once.
    var cancelled: Bool { lock.withLock { _cancelled } }

    /// Exact count of `cancel(...)` calls — flag double-cancel bugs.
    var cancelCount: Int { lock.withLock { _cancelCount } }

    /// Number of `sendPing()` calls made by the engine's heartbeat loop.
    var pingCount: Int { lock.withLock { _pingCount } }

    /// Queue an inbound message. If a `receive()` is currently suspended
    /// waiting, hand the message to it directly; otherwise buffer it.
    func enqueueReceive(_ message: WebSocketTransportMessage) {
        lock.lock()
        if let cont = _pendingReceives.first {
            _pendingReceives.removeFirst()
            lock.unlock()
            cont.resume(returning: message)
            return
        }
        _receiveQueue.append(message)
        lock.unlock()
    }

    /// Convenience for the common text-message case.
    func enqueueReceiveText(_ text: String) {
        enqueueReceive(.string(text))
    }

    /// Convenience for the common binary-message case.
    func enqueueReceiveData(_ data: Data) {
        enqueueReceive(.data(data))
    }

    /// Cause the next `receive()` call to throw. Used to simulate a
    /// dropped socket — the engine reacts by transitioning into the
    /// reconnect loop.
    func enqueueReceiveError(_ error: Error) {
        lock.lock()
        if let cont = _pendingReceives.first {
            _pendingReceives.removeFirst()
            lock.unlock()
            cont.resume(throwing: error)
            return
        }
        _receiveErrors.append(error)
        lock.unlock()
    }

    /// Configure what `sendPing()` returns (nil = pong received,
    /// non-nil = ping failed → engine triggers reconnect).
    func setPongResult(_ result: Error?) {
        lock.withLock { _pongResult = result }
    }

    /// Make subsequent `send(...)` calls throw the given error.
    func setSendError(_ error: Error?) {
        lock.withLock { _sendError = error }
    }

    /// Count of audio data frames sent (excludes text envelopes).
    var sentDataByteCount: Int {
        lock.withLock {
            _sentFrames.reduce(0) { acc, frame in
                if case .data(let d) = frame { return acc + d.count }
                return acc
            }
        }
    }

    // MARK: - WebSocketTransport conformance

    func send(_ data: Data) async throws {
        let err: Error? = lock.withLock {
            _sentFrames.append(.data(data))
            return _sendError
        }
        if let err { throw err }
    }

    func send(_ text: String) async throws {
        let err: Error? = lock.withLock {
            _sentFrames.append(.text(text))
            return _sendError
        }
        if let err { throw err }
    }

    func receive() async throws -> WebSocketTransportMessage {
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !_receiveErrors.isEmpty {
                let err = _receiveErrors.removeFirst()
                lock.unlock()
                cont.resume(throwing: err)
                return
            }
            if !_receiveQueue.isEmpty {
                let msg = _receiveQueue.removeFirst()
                lock.unlock()
                cont.resume(returning: msg)
                return
            }
            _pendingReceives.append(cont)
            lock.unlock()
        }
    }

    func sendPing() async -> Error? {
        return lock.withLock {
            _pingCount += 1
            return _pongResult
        }
    }

    func cancel(closeCode: WebSocketTransportCloseCode, reason: Data?) {
        let pending: [CheckedContinuation<WebSocketTransportMessage, Error>] = lock.withLock {
            _cancelled = true
            _cancelCount += 1
            let p = _pendingReceives
            _pendingReceives.removeAll()
            return p
        }
        // Fail any in-flight receive() so the engine's loop exits.
        let cancelError = NSError(domain: "MockWebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "socket cancelled by test"])
        for cont in pending {
            cont.resume(throwing: cancelError)
        }
    }
}
