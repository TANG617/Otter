import Foundation

protocol MediaRequestBuilding: Sendable {
    func urlRequest(
        for asset: MediaAssetDescriptor,
        variant: AssetVariant,
        representation: RemoteRepresentation
    ) throws -> URLRequest
}

struct TransportedMediaFile: Sendable {
    let fileURL: URL
    let mimeType: String?
    let byteCount: Int64?
    let statusCode: Int
}

protocol MediaTransporting: Sendable {
    func download(_ request: URLRequest) async throws -> TransportedMediaFile
}

final class URLSessionMediaTransport: NSObject, MediaTransporting, @unchecked Sendable {
    private let session: URLSession
    private let stagingDirectory: URL
    private let fileManager: FileManager

    init(
        configuration: URLSessionConfiguration = URLSessionMediaTransport.mediaConfiguration(),
        stagingDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        self.stagingDirectory = stagingDirectory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        session = URLSession(configuration: configuration)
        super.init()
    }

    func download(_ request: URLRequest) async throws -> TransportedMediaFile {
        try Task.checkCancellation()
        let redirectGuard = CrossOriginRedirectGuard()
        let (temporaryURL, response) = try await session.download(for: request, delegate: redirectGuard)
        guard let http = response as? HTTPURLResponse else { throw MediaError.invalidHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaError.httpStatus(
                http.statusCode,
                retryAfter: Self.retryAfter(from: http.value(forHTTPHeaderField: "Retry-After"))
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
            statusCode: http.statusCode
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

private final class CrossOriginRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard Self.sameOrigin(task.originalRequest?.url, request.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
