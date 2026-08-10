import Foundation

enum SyntheticMetadataScale: Int, CaseIterable, Sendable {
    case standard = 10_000
    case stress = 100_000
}

struct SyntheticAssetMetadata: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let type: String
    let localDateTime: Date
    let fileCreatedAt: Date
    let createdAt: Date
    let updatedAt: Date
    let width: Int
    let height: Int
    let isEdited: Bool
    let rating: Int?
}

struct SyntheticMetadataLibrary: Equatable, RandomAccessCollection, Sendable {
    typealias Index = Int
    typealias Element = SyntheticAssetMetadata

    static let referenceDate = Date(timeIntervalSince1970: 1_735_689_600)

    let count: Int

    init(scale: SyntheticMetadataScale = .standard) {
        count = scale.rawValue
    }

    init(count: Int) {
        precondition(count >= 0, "Synthetic metadata count must be nonnegative")
        self.count = count
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(position: Int) -> SyntheticAssetMetadata {
        precondition(indices.contains(position), "Synthetic metadata index is out of bounds")
        return Self.makeItem(at: position)
    }

    func page(startingAt offset: Int, limit: Int) -> [SyntheticAssetMetadata] {
        guard offset >= 0, limit > 0, offset < count else { return [] }
        return (offset..<Swift.min(offset + limit, count)).map { self[$0] }
    }

    func searchResponseData(startingAt offset: Int, limit: Int) throws -> Data {
        let items = page(startingAt: offset, limit: limit)
        let nextOffset = offset + items.count
        let response = SearchResponse(
            assets: AssetPage(
                items: items,
                nextPage: nextOffset < count ? String(nextOffset) : nil
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(response)
    }

    static func makeItem(at index: Int) -> SyntheticAssetMetadata {
        precondition(index >= 0, "Synthetic metadata index must be nonnegative")
        let dimensions = dimensions(for: index)
        let localDateTime = referenceDate.addingTimeInterval(-TimeInterval(index * 97))

        return SyntheticAssetMetadata(
            id: stableID(for: index),
            type: "IMAGE",
            localDateTime: localDateTime,
            fileCreatedAt: localDateTime.addingTimeInterval(-2),
            createdAt: localDateTime.addingTimeInterval(3),
            updatedAt: localDateTime.addingTimeInterval(7),
            width: dimensions.width,
            height: dimensions.height,
            isEdited: index.isMultiple(of: 11),
            rating: rating(for: index)
        )
    }

    static func stableID(for index: Int) -> UUID {
        precondition(index >= 0, "Synthetic metadata index must be nonnegative")
        let value = UInt64(index)
        return UUID(uuid: (
            0x54, 0x65, 0x73, 0x74,
            0x4d, 0x65, 0x40, 0x00,
            0x80, 0x00,
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ))
    }

    private static func dimensions(for index: Int) -> (width: Int, height: Int) {
        switch index % 4 {
        case 0:
            (4_032, 3_024)
        case 1:
            (3_024, 4_032)
        case 2:
            (6_000, 4_000)
        default:
            (4_000, 6_000)
        }
    }

    private static func rating(for index: Int) -> Int? {
        switch index % 8 {
        case 0:
            nil
        case 1:
            -1
        default:
            1 + (index % 5)
        }
    }
}

private extension SyntheticMetadataLibrary {
    struct SearchResponse: Encodable {
        let assets: AssetPage
    }

    struct AssetPage: Encodable {
        let items: [SyntheticAssetMetadata]
        let nextPage: String?
    }
}
