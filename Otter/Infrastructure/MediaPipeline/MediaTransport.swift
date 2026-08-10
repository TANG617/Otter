import Foundation

protocol MediaRequestBuilding: Sendable {
    func urlRequest(
        for asset: MediaAssetDescriptor,
        variant: AssetVariant,
        representation: RemoteRepresentation
    ) throws -> URLRequest
}

enum MediaRedirectDisposition: String, Equatable, Sendable {
    case followed
    case rejectedCrossOrigin
    case rejectedOriginalSubstitution
}

struct MediaRedirectHop: Equatable, Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let statusCode: Int
    let disposition: MediaRedirectDisposition
}

struct MediaResponseMetadata: Equatable, Sendable {
    let initialURL: URL
    let finalURL: URL
    let redirects: [MediaRedirectHop]

    var wasRedirected: Bool {
        !redirects.isEmpty || initialURL != finalURL
    }

    var nominalFullsizeResolvedToOriginal: Bool {
        guard MediaRedirectPolicy.isFullsizeThumbnailURL(initialURL) else { return false }
        if redirects.contains(where: {
            MediaRedirectPolicy.sameOrigin(initialURL, $0.destinationURL)
                && MediaRedirectPolicy.isOriginalURL($0.destinationURL)
        }) {
            return true
        }
        return wasRedirected
            && MediaRedirectPolicy.sameOrigin(initialURL, finalURL)
            && MediaRedirectPolicy.isOriginalURL(finalURL)
    }
}

struct MediaTransportHTTPError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let statusCode: Int
    let retryAfter: TimeInterval?
    let responseMetadata: MediaResponseMetadata

    var description: String {
        "MediaTransportHTTPError(statusCode: \(statusCode), response: <redacted>)"
    }

    var debugDescription: String { description }
}

struct TransportedMediaFile: Sendable {
    let fileURL: URL
    let mimeType: String?
    let byteCount: Int64?
    let statusCode: Int
    let responseMetadata: MediaResponseMetadata?

    init(
        fileURL: URL,
        mimeType: String?,
        byteCount: Int64?,
        statusCode: Int,
        responseMetadata: MediaResponseMetadata? = nil
    ) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.statusCode = statusCode
        self.responseMetadata = responseMetadata
    }
}

protocol MediaTransporting: Sendable {
    func download(_ request: URLRequest) async throws -> TransportedMediaFile
}

final class URLSessionMediaTransport: NSObject, MediaTransporting, @unchecked Sendable {
    private let session: URLSession
    private let stagingDirectory: URL
    private let fileManager: FileManager
    private let onAuthenticationInvalid: @Sendable () -> Void

    init(
        configuration: URLSessionConfiguration = URLSessionMediaTransport.mediaConfiguration(),
        stagingDirectory: URL,
        fileManager: FileManager = .default,
        onAuthenticationInvalid: @escaping @Sendable () -> Void = { }
    ) throws {
        self.stagingDirectory = stagingDirectory
        self.fileManager = fileManager
        self.onAuthenticationInvalid = onAuthenticationInvalid
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        session = URLSession(configuration: configuration)
        super.init()
    }

    func download(_ request: URLRequest) async throws -> TransportedMediaFile {
        try Task.checkCancellation()
        guard let initialURL = request.url else { throw MediaError.invalidHTTPResponse }
        let redirectGuard = SafeMediaRedirectDelegate(initialURL: initialURL)
        let (temporaryURL, response) = try await session.download(for: request, delegate: redirectGuard)
        guard let http = response as? HTTPURLResponse else { throw MediaError.invalidHTTPResponse }
        let responseMetadata = redirectGuard.responseMetadata(finalURL: http.url ?? initialURL)
        if http.statusCode == 401 { onAuthenticationInvalid() }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaTransportHTTPError(
                statusCode: http.statusCode,
                retryAfter: Self.retryAfter(from: http.value(forHTTPHeaderField: "Retry-After")),
                responseMetadata: responseMetadata
            )
        }
        let destination = stagingDirectory.appendingPathComponent("\(UUID().uuidString).download")
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        guard size != 0 else {
            try? fileManager.removeItem(at: destination)
            throw MediaError.corruptMedia
        }
        return .init(
            fileURL: destination,
            mimeType: http.mimeType,
            byteCount: size,
            statusCode: http.statusCode,
            responseMetadata: responseMetadata
        )
    }

    static func mediaConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return configuration
    }

    private static func retryAfter(from value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(date.timeIntervalSinceNow, 0)
    }
}

enum MediaRedirectPolicy {
    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    static func isFullsizeThumbnailURL(_ url: URL) -> Bool {
        guard url.lastPathComponent == "thumbnail",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.queryItems?.contains(URLQueryItem(name: "size", value: "fullsize")) == true
    }

    static func isOriginalURL(_ url: URL) -> Bool {
        url.lastPathComponent == "original"
    }

    static func shouldRejectOriginalSubstitution(initialURL: URL, destinationURL: URL) -> Bool {
        isFullsizeThumbnailURL(initialURL) && isOriginalURL(destinationURL)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

private final class SafeMediaRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let initialURL: URL
    private let lock = NSLock()
    private var redirects: [MediaRedirectHop] = []

    init(initialURL: URL) {
        self.initialURL = initialURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let sourceURL = response.url ?? task.currentRequest?.url ?? initialURL
        guard let destinationURL = request.url else {
            completionHandler(nil)
            return
        }
        let sameOrigin = MediaRedirectPolicy.sameOrigin(initialURL, destinationURL)
        let rejectsOriginal = sameOrigin && MediaRedirectPolicy.shouldRejectOriginalSubstitution(
            initialURL: initialURL,
            destinationURL: destinationURL
        )
        let disposition: MediaRedirectDisposition = if !sameOrigin {
            .rejectedCrossOrigin
        } else if rejectsOriginal {
            .rejectedOriginalSubstitution
        } else {
            .followed
        }
        lock.withLock {
            redirects.append(
                MediaRedirectHop(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    statusCode: response.statusCode,
                    disposition: disposition
                )
            )
        }
        guard disposition == .followed else {
            completionHandler(nil)
            return
        }
        var authorizedRequest = request
        if authorizedRequest.value(forHTTPHeaderField: "x-api-key") == nil,
           let apiKey = task.originalRequest?.value(forHTTPHeaderField: "x-api-key") {
            authorizedRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        completionHandler(authorizedRequest)
    }

    func responseMetadata(finalURL: URL) -> MediaResponseMetadata {
        MediaResponseMetadata(
            initialURL: initialURL,
            finalURL: finalURL,
            redirects: lock.withLock { redirects }
        )
    }
}
