import Foundation

struct FixtureAccount: Equatable, Sendable {
    let accountNamespace: UUID
    let serverURL: URL
    let accountDisplayName: String
    let serverVersion: String

    static let standard = FixtureAccount(
        accountNamespace: UUID(uuidString: "4F747465-7246-4000-8000-000000000001")!,
        serverURL: URL(string: "https://fixture.invalid")!,
        accountDisplayName: "Fixture Account",
        serverVersion: "fixture-1"
    )
}

enum FixtureLibraryScale: Int, CaseIterable, Identifiable, Sendable {
    case standard = 10_000
    case stress = 100_000

    var id: Int { rawValue }
}

struct FixtureLibraryConfiguration: Equatable, Sendable {
    static let assetCountArgument = "-OTTER_FIXTURE_ASSET_COUNT"
    static let assetCountEnvironmentKey = "OTTER_FIXTURE_ASSET_COUNT"

    let scale: FixtureLibraryScale

    init(scale: FixtureLibraryScale = .standard) {
        self.scale = scale
    }

    static func resolved(
        arguments: [String],
        environment: [String: String]
    ) -> FixtureLibraryConfiguration {
        let argumentValue = arguments.firstIndex(of: assetCountArgument).flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let requestedCount = argumentValue ?? environment[assetCountEnvironmentKey]
        return FixtureLibraryConfiguration(scale: requestedCount == "100000" ? .stress : .standard)
    }
}

struct FixtureLibraryItem: Equatable, Identifiable, Sendable {
    let id: UUID
    let ordinal: Int
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let rating: Int?
    let hasEdits: Bool
    let colorSeed: UInt32

    var aspectRatio: Double {
        Double(pixelWidth) / Double(pixelHeight)
    }
}

struct FixtureLibrary: Equatable, Sendable {
    let account: FixtureAccount
    let items: [FixtureLibraryItem]
}

enum FixtureLibraryGenerator {
    static let referenceDate = Date(timeIntervalSince1970: 1_735_689_600)

    static func generate(
        configuration: FixtureLibraryConfiguration = FixtureLibraryConfiguration(),
        account: FixtureAccount = .standard
    ) -> FixtureLibrary {
        let items = (0..<configuration.scale.rawValue).map(makeItem)
        return FixtureLibrary(account: account, items: items)
    }

    static func makeItem(at index: Int) -> FixtureLibraryItem {
        precondition(index >= 0, "Fixture indexes must be nonnegative")
        let dimensions = dimensions(for: index)

        return FixtureLibraryItem(
            id: stableID(for: index),
            ordinal: index,
            capturedAt: referenceDate.addingTimeInterval(-TimeInterval(index * 97)),
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            rating: rating(for: index),
            hasEdits: index.isMultiple(of: 11),
            colorSeed: UInt32(truncatingIfNeeded: index &* 2_654_435_761)
        )
    }

    static func stableID(for index: Int) -> UUID {
        precondition(index >= 0, "Fixture indexes must be nonnegative")
        let value = UInt64(index)

        return UUID(uuid: (
            0x4f, 0x74, 0x74, 0x65,
            0x72, 0x46, 0x40, 0x00,
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
        switch index % 6 {
        case 0:
            (4_032, 3_024)
        case 1:
            (3_024, 4_032)
        case 2:
            (4_032, 2_268)
        case 3:
            (2_268, 4_032)
        case 4:
            (6_000, 4_000)
        default:
            (4_000, 6_000)
        }
    }

    private static func rating(for index: Int) -> Int? {
        switch index % 9 {
        case 0:
            nil
        case 1:
            -1
        default:
            1 + (index % 5)
        }
    }
}
