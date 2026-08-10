import Foundation

enum MediaAssetType: String, Codable, Hashable, Sendable {
    case image
}
struct MediaContentRevisions: Codable, Hashable, Sendable {
    let thumbnail: String
    let preview: String
    let fullsize: String
    let original: String

    func revision(for representation: RemoteRepresentation) -> String {
        switch representation {
        case .thumbnail: thumbnail
        case .preview: preview
        case .fullsize: fullsize
        case .original: original
        }
    }
}

struct MediaAssetDescriptor: Codable, Hashable, Identifiable, Sendable {
    let accountNamespace: UUID
    let id: UUID
    let type: MediaAssetType
    let thumbhash: String?
    let hasEdits: Bool
    let revisions: MediaContentRevisions
    let originalWidth: Int?
    let originalHeight: Int?
    let originalMimeType: String?
    let originalFilename: String?

    init(
        accountNamespace: UUID,
        id: UUID,
        type: MediaAssetType = .image,
        thumbhash: String? = nil,
        hasEdits: Bool = false,
        revisions: MediaContentRevisions,
        originalWidth: Int? = nil,
        originalHeight: Int? = nil,
        originalMimeType: String? = nil,
        originalFilename: String? = nil
    ) {
        self.accountNamespace = accountNamespace
        self.id = id
        self.type = type
        self.thumbhash = thumbhash
        self.hasEdits = hasEdits
        self.revisions = revisions
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.originalMimeType = originalMimeType
        self.originalFilename = originalFilename
    }
}
