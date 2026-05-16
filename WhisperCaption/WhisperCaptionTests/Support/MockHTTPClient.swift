import Foundation
@testable import WhisperCaption

/// Scriptable HTTPClient stand-in for the cloud-engine preflight checks
/// (Deepgram `/v1/projects`, ElevenLabs `/v1/single-use-token/realtime_scribe`).
///
/// Each test queues responses in the order the engine will consume them;
/// each `data(for:)` call pops the head of the queue and either returns
/// the canned `(body, response)` or throws the canned error.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {

    enum Response: Sendable {
        /// HTTP response with explicit status + optional body.
        case status(Int, body: Data = Data())
        /// Transport error — equivalent to `URLSession.data(for:)` throwing.
        case transportError(Error)
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private var _requestHistory: [URLRequest] = []

    init() {}

    // MARK: - Configuration

    /// Queue a single response for the next request.
    func enqueue(_ response: Response) {
        lock.withLock { responses.append(response) }
    }

    /// Convenience: a 200 OK with a JSON body.
    func enqueueJSON(_ json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        enqueue(.status(200, body: data))
    }

    /// Convenience: a single-use-token response that ElevenLabs returns.
    func enqueueElevenLabsToken(_ token: String) {
        enqueueJSON(["token": token])
    }

    // MARK: - Inspection

    /// Every request the system under test has issued, in order.
    var requestHistory: [URLRequest] {
        lock.withLock { _requestHistory }
    }

    var requestCount: Int { lock.withLock { _requestHistory.count } }

    // MARK: - HTTPClient

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response: Response? = lock.withLock {
            _requestHistory.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let response else {
            // Throw rather than fatalError so a missing-enqueue mistake
            // surfaces as a test failure on the offending case, not as a
            // process crash that cascades into every other parallel test.
            throw TestError("MockHTTPClient: no response queued for \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "<no url>")")
        }
        switch response {
        case .status(let code, let body):
            let resp = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, resp)
        case .transportError(let err):
            throw err
        }
    }
}
