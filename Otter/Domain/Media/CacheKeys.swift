import CryptoKit
import Foundation

struct ByteCacheKey: Codable, Hashable, Sendable {
    let accountNamespace: UUID
    let assetID: UUID
    let variant: AssetVariant
    let representation: RemoteRepresentation
    let contentRevision: String

    init(
        accountNamespace: UUID,
        assetID: UUID,
        variant: AssetVariant,
        representation: RemoteRepresentation,
        contentRevision: String
    ) throws {
        guard representation.isValid(for: variant) else {
            throw MediaError.invalidVariantRepresentation(variant, representation)
        }
        self.accountNamespace = accountNamespace
        self.assetID = assetID
        self.variant = variant
        self.representation = representation
        self.contentRevision = contentRevision
    }

    init(asset: MediaAssetDescriptor, variant: AssetVariant, representation: RemoteRepresentation) throws {
        try self.init(
            accountNamespace: asset.accountNamespace,
            assetID: asset.id,
            variant: variant,
            representation: representation,
            contentRevision: asset.revisions.revision(for: representation)
        )
    }

    var canonicalIdentity: String {
        [
            accountNamespace.uuidString.lowercased(),
            assetID.uuidString.lowercased(),
            variant.rawValue,
            representation.rawValue,
            contentRevision,
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined(separator: "|")
    }

    var digest: String {
        SHA256.hash(data: Data(canonicalIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
struct RenderCacheKey: Hashable, Sendable {
    let byteKey: ByteCacheKey
    let specification: RenderSpecification
    let transformVersion: Int
}

enum MediaError: Error, Equatable, Sendable {
    case invalidVariantRepresentation(AssetVariant, RemoteRepresentation)
    case timelineOriginalForbidden
    case unavailableRepresentation(RemoteRepresentation)
    case invalidHTTPResponse
    case httpStatus(Int, retryAfter: TimeInterval?)
    case corruptMedia
    case cancelled
    case cacheEntryMissing
    case ioFailure(String)
}
