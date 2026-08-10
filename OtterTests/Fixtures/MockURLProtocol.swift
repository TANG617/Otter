import Foundation

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Sendable, CustomDebugStringConvertible {
        let sequenceNumber: Int
        let request: URLRequest

        var debugDescription: String {
            var components = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            }
            components?.query = nil
            components?.fragment = nil
            let endpoint = components?.url?.absoluteString ?? "<invalid-url>"
            return "RecordedRequest(sequence: \(sequenceNumber), method: \(request.httpMethod ?? "unset"), endpoint: \(endpoint), headers: <redacted>)"
        }
    }

    struct HTTPResponse: Equatable, Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        init(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data()
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    enum Outcome: Equatable, Sendable {
        case response(HTTPResponse)
        case failure(URLError.Code)
    }

    typealias Responder = @Sendable (_ request: URLRequest, _ sequenceNumber: Int) -> Outcome

    private static let storage = Storage()

    static var recordedRequests: [RecordedRequest] {
        storage.recordedRequests
    }

    static func install(responder: @escaping Responder) {
        storage.install(responder: responder)
    }

    static func install(
        outcomes: [Outcome],
        fallback: Outcome = .failure(.resourceUnavailable)
    ) {
        let sequence = OutcomeSequence(outcomes: outcomes, fallback: fallback)
        install { _, _ in sequence.next() }
    }

    static func reset() {
        storage.reset()
    }

    static func ephemeralSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let outcome = Self.storage.recordAndRespond(to: request)

        switch outcome {
        case let .response(stub):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: stub.statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: stub.headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !stub.body.isEmpty {
                client?.urlProtocol(self, didLoad: stub.body)
            }
            client?.urlProtocolDidFinishLoading(self)

        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

private extension MockURLProtocol {
    final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [RecordedRequest] = []
        private var responder: Responder = { _, _ in .failure(.unsupportedURL) }

        var recordedRequests: [RecordedRequest] {
            lock.withLock { requests }
        }

        func install(responder: @escaping Responder) {
            lock.withLock {
                requests.removeAll(keepingCapacity: true)
                self.responder = responder
            }
        }

        func reset() {
            lock.withLock {
                requests.removeAll(keepingCapacity: false)
                responder = { _, _ in .failure(.unsupportedURL) }
            }
        }

        func recordAndRespond(to request: URLRequest) -> Outcome {
            let context: (sequenceNumber: Int, responder: Responder) = lock.withLock {
                let sequenceNumber = requests.count
                requests.append(RecordedRequest(sequenceNumber: sequenceNumber, request: request))
                return (sequenceNumber, responder)
            }
            return context.responder(request, context.sequenceNumber)
        }
    }

    final class OutcomeSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Outcome]
        private let fallback: Outcome

        init(outcomes: [Outcome], fallback: Outcome) {
            self.outcomes = outcomes
            self.fallback = fallback
        }

        func next() -> Outcome {
            lock.withLock {
                guard !outcomes.isEmpty else { return fallback }
                return outcomes.removeFirst()
            }
        }
    }
}
