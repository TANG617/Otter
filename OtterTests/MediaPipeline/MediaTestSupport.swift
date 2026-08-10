import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Otter

func mediaTestKey(
    account: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    asset: UUID = UUID(),
    representation: RemoteRepresentation = .preview,
    revision: String = "v1"
) throws -> ByteCacheKey {
    try ByteCacheKey(
        accountNamespace: account,
        assetID: asset,
        variant: representation == .original ? .original : .current,
        representation: representation,
        contentRevision: revision
    )
}
func temporaryTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("OtterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeBytes(count: Int, to directory: URL, name: String = UUID().uuidString) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(repeating: 0xA5, count: count).write(to: url, options: .atomic)
    return url
}

func makeTestJPEG(width: Int, height: Int, at url: URL) throws {
    let bytesPerRow = width * 4
    var pixels = Data(count: bytesPerRow * height)
    pixels.withUnsafeMutableBytes { rawBuffer in
        guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
        for index in stride(from: 0, to: rawBuffer.count, by: 4) {
            bytes[index] = 40
            bytes[index + 1] = 100
            bytes[index + 2] = 200
            bytes[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: pixels as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
          ) else {
        throw MediaError.corruptMedia
    }
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: 0.8,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw MediaError.corruptMedia }
}
