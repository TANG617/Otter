import Foundation
@testable import Otter

enum TestAssetFactory {
    static let accountNamespace = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    static func asset(
        id: UUID = UUID(),
        accountNamespace: UUID = accountNamespace,
        localDateTime: Date? = nil,
        fileCreatedAt: Date? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
        rating: AssetRating? = nil,
        isArchived: Bool = false,
        isTrashed: Bool = false,
        visibility: String? = "timeline"
    ) -> TimelineAsset {
        TimelineAsset(
            accountNamespace: accountNamespace,
            id: id,
            ownerID: nil,
            mediaType: .image,
            localDateTime: localDateTime,
            fileCreatedAt: fileCreatedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            width: 4_032,
            height: 3_024,
            thumbhash: "fixture-thumbhash",
            checksum: "fixture-checksum",
            originalFileName: "fixture.jpg",
            originalMimeType: "image/jpeg",
            isFavorite: false,
            isEdited: false,
            isArchived: isArchived,
            isTrashed: isTrashed,
            visibility: visibility,
            rating: rating
        )
    }

    static func account(namespace: UUID = accountNamespace) -> Account {
        Account(
            namespace: namespace,
            serverURL: URL(string: "https://photos.example.com")!,
            userID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            serverVersion: "3.1.0",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func deterministicID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}
