import Foundation

enum PixelBucket {
    static let all = [128, 192, 256, 384, 512, 768, 1_024, 1_536, 2_048, 3_072, 4_096]

    static func normalized(for demand: Double, purpose: MediaPurpose) -> Int {
        let ceiling: Int
        switch purpose {
        case .timeline: ceiling = 512
        case .viewer: ceiling = 3_072
        case .zoom: ceiling = 4_096
        }
        let boundedDemand = max(1, min(Int(demand.rounded(.up)), ceiling))
        return all.first(where: { $0 >= boundedDemand }) ?? ceiling
    }
}
