import Foundation

/// Same purpose as `WebSocketTransport`: a thin protocol around the bits of
/// `URLSession` the cloud STT engines use for non-WS calls (Deepgram
/// `/v1/projects` preflight, ElevenLabs single-use-token mint). Lets unit
/// tests serve canned 200/401/403/network-error responses without making
/// real HTTP calls or pinning a fake server up on a port.
nonisolated protocol HTTPClient: Sendable {
    /// Synchronous-style `URLSession.data(for:)`: send the request, return
    /// `(body, response)`. Throws on transport failure.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
