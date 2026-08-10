import Foundation

struct ServerVersionDTO: Decodable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?
}

struct SearchMetadataResponseDTO: Decodable {
    let assets: SearchAssetPageDTO
}

struct SearchAssetPageDTO: Decodable {
    let items: [ImmichAssetDTO]
    let nextPage: ContinuationDTO?
}

struct ContinuationDTO: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int.self) {
            value = String(integer)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a continuation token.")
            )
        }
    }
}

struct ImmichAssetDTO: Decodable {
    let id: String
    let type: String
    let ownerId: String?
    let localDateTime: Date?
    let fileCreatedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let width: Int?
    let height: Int?
    let thumbhash: String?
    let checksum: String?
    let originalFileName: String?
    let originalMimeType: String?
    let isFavorite: Bool?
    let isEdited: Bool?
    let isArchived: Bool?
    let isTrashed: Bool?
    let visibility: String?
    let deletedAt: Date?
    let exifInfo: ImmichExifDTO?
}

struct ImmichExifDTO: Decodable {
    let rating: Int?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
}

struct MetadataSearchBody: Encodable {
    let page: Int
    let size: Int
    let updatedAfter: Date?

    enum CodingKeys: String, CodingKey {
        case page, size, updatedAfter, withExif, isArchived, isTrashed, type, visibility
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(page, forKey: .page)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(updatedAfter, forKey: .updatedAfter)
        try container.encode(true, forKey: .withExif)
        try container.encode(false, forKey: .isArchived)
        try container.encode(false, forKey: .isTrashed)
        try container.encode("IMAGE", forKey: .type)
        try container.encode("timeline", forKey: .visibility)
    }
}

struct RatingUpdateBody: Encodable {
    let rating: AssetRating?

    enum CodingKeys: String, CodingKey { case rating }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let rating {
            try container.encode(rating.rawValue, forKey: .rating)
        } else {
            try container.encodeNil(forKey: .rating)
        }
    }
}

enum ImmichJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date."
            )
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}
