import Foundation
import Testing
@testable import Otter

private let accountA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let accountB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let assetID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

private func descriptor(
    account: UUID = accountA,
    thumbnail: String = "thumb-v1",
    original: String = "checksum-v1"
) -> MediaAssetDescriptor {
    MediaAssetDescriptor(
        accountNamespace: account,
        id: assetID,
        revisions: .init(
            thumbnail: thumbnail,
            preview: "preview-v1",
            fullsize: "full-v1",
            original: original
        ),
        originalWidth: 8_064,
        originalHeight: 6_048,
        originalMimeType: "image/jpeg"
    )
}
private func request(
    variant: AssetVariant = .current,
    purpose: MediaPurpose = .viewer,
    viewport: PixelSize = .init(width: 390, height: 844),
    displayScale: Double = 3,
    zoomScale: Double = 1
) -> MediaRequest {
    MediaRequest(
        asset: descriptor(),
        variant: variant,
        purpose: purpose,
        viewport: viewport,
        displayScale: displayScale,
        zoomScale: zoomScale,
        priority: .interactive
    )
}

@Suite("Media domain cache identity")
struct MediaCacheIdentityTests {
    @Test("Current and Original never alias")
    func variantIdentity() throws {
        let current = try ByteCacheKey(asset: descriptor(), variant: .current, representation: .preview)
        let original = try ByteCacheKey(asset: descriptor(), variant: .original, representation: .original)
        #expect(current != original)
        #expect(current.digest != original.digest)
    }

    @Test("Account namespace participates in identity")
    func accountIdentity() throws {
        let a = try ByteCacheKey(asset: descriptor(account: accountA), variant: .current, representation: .preview)
        let b = try ByteCacheKey(asset: descriptor(account: accountB), variant: .current, representation: .preview)
        #expect(a != b)
    }

    @Test("Rating cannot affect media key because it is absent from descriptor")
    func ratingIsExcluded() throws {
        let key = try ByteCacheKey(asset: descriptor(), variant: .current, representation: .preview)
        let reconstructed = try ByteCacheKey(asset: descriptor(), variant: .current, representation: .preview)
        #expect(key == reconstructed)
    }

    @Test("Original checksum changes only Original identity")
    func checksumIdentity() throws {
        let old = try ByteCacheKey(asset: descriptor(original: "old"), variant: .original, representation: .original)
        let new = try ByteCacheKey(asset: descriptor(original: "new"), variant: .original, representation: .original)
        #expect(old != new)
    }

    @Test("Derivative revision changes derivative identity")
    func derivativeIdentity() throws {
        let old = try ByteCacheKey(asset: descriptor(thumbnail: "old"), variant: .current, representation: .thumbnail)
        let new = try ByteCacheKey(asset: descriptor(thumbnail: "new"), variant: .current, representation: .thumbnail)
        #expect(old != new)
    }

    @Test("Invalid variant representation pairs are rejected")
    func legalMatrix() {
        #expect(throws: MediaError.self) {
            _ = try ByteCacheKey(asset: descriptor(), variant: .current, representation: .original)
        }
        #expect(throws: MediaError.self) {
            _ = try ByteCacheKey(asset: descriptor(), variant: .original, representation: .preview)
        }
    }

    @Test("Pixel demand normalizes to stable buckets")
    func bucketNormalization() {
        #expect(PixelBucket.normalized(for: 347, purpose: .timeline) == 384)
        #expect(PixelBucket.normalized(for: 401, purpose: .timeline) == 512)
        #expect(PixelBucket.normalized(for: 1_830, purpose: .viewer) == 2_048)
        #expect(PixelBucket.normalized(for: 9_000, purpose: .zoom) == 4_096)
    }
}

@Suite("Representation planner")
struct RepresentationPlannerTests {
    private let planner = RepresentationPlanner()

    @Test("Unknown profile follows conservative progression")
    func unknownProfile() throws {
        let result = try planner.plan(for: request(purpose: .timeline), profile: .init())
        #expect(result.map(\.representation) == [.thumbnail, .preview])
    }

    @Test("Undersized thumbnail upgrades to preview")
    func thumbnailUpgrade() throws {
        let profile = ServerMediaProfile(
            thumbnail: .init(mimeType: "image/webp", maximumObservedDimension: 250, byteCount: 10_000, redirectsCrossOrigin: false)
        )
        let result = try planner.plan(for: request(purpose: .timeline), profile: profile)
        #expect(result.map(\.representation) == [.thumbnail, .preview])
    }

    @Test("Adequate preview does not request fullsize or Original")
    func adequatePreview() throws {
        let profile = ServerMediaProfile(
            preview: .init(mimeType: "image/jpeg", maximumObservedDimension: 4_096, byteCount: nil, redirectsCrossOrigin: false)
        )
        let result = try planner.plan(for: request(), profile: profile)
        #expect(result.map(\.representation) == [.preview])
    }

    @Test("Zoom demand upgrades to fullsize")
    func zoomUpgrade() throws {
        let result = try planner.plan(for: request(purpose: .zoom, zoomScale: 3), profile: .init())
        #expect(result.map(\.representation) == [.preview, .fullsize])
    }

    @Test("Unsupported fullsize is not probed again")
    func unsupportedFullsize() throws {
        let profile = ServerMediaProfile(fullsizeSupport: .unsupported)
        let result = try planner.plan(
            for: request(purpose: .zoom, zoomScale: 3),
            profile: profile
        )
        #expect(result.map(\.representation) == [.preview])
    }

    @Test("Representation observations merge monotonically")
    func observationMerge() {
        var profile = ServerMediaProfile()
        profile.merge(
            .init(
                mimeType: "image/jpeg",
                maximumObservedDimension: 4_096,
                byteCount: 2_000_000,
                redirectsCrossOrigin: false
            ),
            for: .preview
        )
        profile.merge(
            .init(
                mimeType: "image/webp",
                maximumObservedDimension: 640,
                byteCount: 100_000,
                redirectsCrossOrigin: false
            ),
            for: .preview
        )

        #expect(profile.preview?.maximumObservedDimension == 4_096)
        #expect(profile.preview?.mimeType == "image/jpeg")
        #expect(profile.preview?.byteCount == 2_000_000)
    }

    @Test("Unsupported fullsize evidence remains conservative")
    func fullsizeSupportMerge() {
        var profile = ServerMediaProfile()
        profile.markFullsizeUnsupported()
        profile.merge(
            .init(
                mimeType: "image/jpeg",
                maximumObservedDimension: 2_048,
                byteCount: nil,
                redirectsCrossOrigin: false
            ),
            for: .fullsize
        )
        #expect(profile.fullsizeSupport == .unsupported)
    }

    @Test("Coverage hysteresis prevents threshold thrashing")
    func hysteresis() {
        #expect(planner.coverageDecision(availablePixels: 840, requiredPixels: 1_000) == .upgrade)
        #expect(planner.coverageDecision(availablePixels: 900, requiredPixels: 1_000) == .hold)
        #expect(planner.coverageDecision(availablePixels: 1_000, requiredPixels: 1_000) == .sufficient)
    }

    @Test("Timeline rejects Original")
    func timelineOriginal() {
        #expect(throws: MediaError.timelineOriginalForbidden) {
            _ = try planner.plan(for: request(variant: .original, purpose: .timeline), profile: .init())
        }
    }
}
