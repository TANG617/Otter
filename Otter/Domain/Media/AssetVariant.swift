import Foundation

enum AssetVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case current
    case original
}
enum RemoteRepresentation: String, Codable, CaseIterable, Hashable, Sendable {
    case thumbnail
    case preview
    case fullsize
    case original

    func isValid(for variant: AssetVariant) -> Bool {
        switch (variant, self) {
        case (.current, .thumbnail), (.current, .preview), (.current, .fullsize), (.original, .original):
            true
        default:
            false
        }
    }
}
