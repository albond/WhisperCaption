import Foundation
@testable import WhisperCaption

/// Mints `MockWebSocketTransport` instances for an engine under test.
///
/// Two configuration modes:
///   * Queued — preload the factory with one or more transports via
///     `enqueue(_:)`. Each call to `open(...)` pulls the next one in
///     FIFO order. Use for tests that simulate a fixed number of
///     (re)connects.
///   * Auto-build — set `autoBuild = true` so the factory mints a fresh
///     `MockWebSocketTransport` per call. Use for "let it run forever"
///     soak-style scenarios.
final class MockWebSocketFactory: WebSocketFactory, @unchecked Sendable {

    private let lock = NSLock()
    private var queue: [MockWebSocketTransport] = []
    private var _openHistory: [(url: URL, protocols: [String])] = []
    private var _nextID = 0
    private var _autoBuild = false
    private var _autoBuildSetup: (@Sendable (MockWebSocketTransport) -> Void)?

    /// When true, `open(...)` will mint a fresh transport whenever the
    /// preloaded queue is empty. When false (default), an empty queue
    /// triggers a `fatalError` so tests don't silently miss a missing
    /// preload step.
    var autoBuild: Bool {
        get { lock.withLock { _autoBuild } }
        set { lock.withLock { _autoBuild = newValue } }
    }

    init() {}

    // MARK: - Configuration

    /// Preload a transport. Returned by the next `open(...)` call.
    func enqueue(_ transport: MockWebSocketTransport) {
        lock.withLock { queue.append(transport) }
    }

    /// Convenience: build, enqueue, and return the same transport so the
    /// test can drive it via `enqueueReceive(...)`.
    @discardableResult
    func enqueueNew() -> MockWebSocketTransport {
        let t = lock.withLock { () -> MockWebSocketTransport in
            _nextID += 1
            return MockWebSocketTransport(id: _nextID)
        }
        enqueue(t)
        return t
    }

    /// Optional hook invoked on every auto-built transport. Lets a test
    /// pre-script behaviour for all future reconnects.
    func setAutoBuildSetup(_ setup: @escaping @Sendable (MockWebSocketTransport) -> Void) {
        lock.withLock { _autoBuildSetup = setup }
    }

    // MARK: - Inspection

    /// Every `(url, protocols)` pair the engine has handed to us, in order.
    var openHistory: [(url: URL, protocols: [String])] {
        lock.withLock { _openHistory }
    }

    /// Total number of `open(...)` calls so far.
    var openCount: Int { lock.withLock { _openHistory.count } }

    // MARK: - WebSocketFactory

    func open(url: URL, protocols: [String]) -> WebSocketTransport {
        let transport: MockWebSocketTransport
        let setup: (@Sendable (MockWebSocketTransport) -> Void)?
        lock.lock()
        _openHistory.append((url, protocols))
        if !queue.isEmpty {
            transport = queue.removeFirst()
            setup = nil
            lock.unlock()
        } else if _autoBuild {
            _nextID += 1
            let id = _nextID
            setup = _autoBuildSetup
            lock.unlock()
            transport = MockWebSocketTransport(id: id)
        } else {
            // No `fatalError` — a missing enqueue would otherwise crash the
            // whole test process and cascade-fail every parallel test. Mint
            // a self-erroring transport instead: any receive / send on it
            // fails with a clear message, so the offending test fails on
            // its own without taking the rest down.
            _nextID += 1
            let id = _nextID
            lock.unlock()
            transport = MockWebSocketTransport(id: id)
            let err = TestError("MockWebSocketFactory: open(\(url)) called with no transport queued and autoBuild=false. Did the test forget an enqueue(...) for this connect attempt?")
            transport.enqueueReceiveError(err)
            transport.setSendError(err)
            setup = nil
        }
        setup?(transport)
        return transport
    }
}
