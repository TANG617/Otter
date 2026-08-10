import Foundation
import Testing
@testable import Otter

@Suite("ImageIO and ThumbHash decoding")
struct DecoderAndThumbHashTests {
    @Test("ImageIO inspects and bounds a large decode off main")
    func boundedDecode() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("large.jpg")
        try makeTestJPEG(width: 1_200, height: 800, at: imageURL)
        let decoder = ImageIODecoder()

        let properties = try await decoder.inspect(fileURL: imageURL, mimeType: "image/jpeg")
        let surface = try await decoder.decode(fileURL: imageURL, maxPixelSize: 256)
        #expect(properties.pixelWidth == 1_200)
        #expect(properties.pixelHeight == 800)
        #expect(max(surface.pixelWidth, surface.pixelHeight) <= 256)
    }

    @Test("Invalid image bytes fail explicitly")
    func invalidBytes() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeBytes(count: 100, to: root)
        let decoder = ImageIODecoder()
        await #expect(throws: MediaError.corruptMedia) {
            _ = try await decoder.decode(fileURL: file, maxPixelSize: 256)
        }
    }

    @Test("Known zero-DC ThumbHash decodes deterministically")
    func knownThumbHash() throws {
        let hash = [UInt8](repeating: 0, count: 40)
        let decoded = try ThumbHashDecoder().decodeBytes(hash)
        #expect(decoded.width == 14)
        #expect(decoded.height == 32)
        #expect(Array(decoded.rgba.prefix(4)) == [0, 43, 170, 255])
    }
}
