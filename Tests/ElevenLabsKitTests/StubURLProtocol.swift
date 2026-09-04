import Foundation

/// Intercepts URLSession traffic so the client can be tested without the
/// network and without a real API key.
final class StubURLProtocol: URLProtocol {

    struct Stub {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        static func json(_ string: String, status: Int = 200) -> Stub {
            Stub(status: status, body: Data(string.utf8),
                 headers: ["Content-Type": "application/json"])
        }

        static func audio(_ bytes: Int, status: Int = 200) -> Stub {
            Stub(status: status, body: Data(repeating: 0xFF, count: bytes),
                 headers: ["Content-Type": "audio/mpeg"])
        }
    }

    /// Called for every intercepted request; returns the stub to answer with.
    nonisolated(unsafe) static var handler: ((URLRequest) -> Stub)?

    /// Every request that reached the protocol, so tests can assert on headers
    /// and bodies rather than only on decoded output.
    nonisolated(unsafe) private(set) static var recorded: [URLRequest] = []

    static func reset() {
        handler = nil
        recorded = []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody into httpBodyStream. Read it back so
        // tests can assert on what was actually sent.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            captured.httpBody = data
        }
        Self.recorded.append(captured)

        let stub = Self.handler?(captured) ?? Stub(status: 500)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
