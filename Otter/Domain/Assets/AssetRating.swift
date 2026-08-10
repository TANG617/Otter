import Foundation

struct AssetRating: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    let rawValue: Int

    init?(rawValue: Int) {
        guard rawValue == -1 || (1...5).contains(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    static let rejected = AssetRating(rawValue: -1)!
    static let one = AssetRating(rawValue: 1)!
    static let two = AssetRating(rawValue: 2)!
    static let three = AssetRating(rawValue: 3)!
    static let four = AssetRating(rawValue: 4)!
    static let five = AssetRating(rawValue: 5)!

    static func < (lhs: AssetRating, rhs: AssetRating) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
