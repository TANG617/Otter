import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SyntheticImageSize: Equatable, Sendable {
    let width: Int
    let height: Int

    static let tiny = SyntheticImageSize(width: 32, height: 24)
    static let thumbnail = SyntheticImageSize(width: 384, height: 288)
    static let photo12Megapixel = SyntheticImageSize(width: 4_032, height: 3_024)
    static let photo48Megapixel = SyntheticImageSize(width: 8_064, height: 6_048)
}

enum SyntheticImageFixtureError: Error, Equatable, Sendable {
    case invalidDimensions
    case contextCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case encodingFailed
}

enum SyntheticImageFixtures {
    static func png(
        size: SyntheticImageSize = .thumbnail,
        seed: UInt32 = 0,
        includesAlpha: Bool = true
    ) throws -> Data {
        try encodedImage(
            size: size,
            seed: seed,
            includesAlpha: includesAlpha,
            type: UTType.png,
            properties: [:]
        )
    }

    static func jpeg(
        size: SyntheticImageSize = .thumbnail,
        seed: UInt32 = 0,
        quality: Double = 0.82
    ) throws -> Data {
        try encodedImage(
            size: size,
            seed: seed,
            includesAlpha: false,
            type: UTType.jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)]
        )
    }

    private static func encodedImage(
        size: SyntheticImageSize,
        seed: UInt32,
        includesAlpha: Bool,
        type: UTType,
        properties: [CFString: Any]
    ) throws -> Data {
        let image = try image(size: size, seed: seed, includesAlpha: includesAlpha)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw SyntheticImageFixtureError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticImageFixtureError.encodingFailed
        }
        return output as Data
    }

    private static func image(
        size: SyntheticImageSize,
        seed: UInt32,
        includesAlpha: Bool
    ) throws -> CGImage {
        guard size.width > 0, size.height > 0 else {
            throw SyntheticImageFixtureError.invalidDimensions
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: includesAlpha
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue
        )
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw SyntheticImageFixtureError.contextCreationFailed
        }

        let red = CGFloat((seed >> 16) & 0xff) / 255
        let green = CGFloat((seed >> 8) & 0xff) / 255
        let blue = CGFloat(seed & 0xff) / 255
        let backgroundAlpha: CGFloat = includesAlpha ? 0.78 : 1

        context.setFillColor(red: red, green: green, blue: blue, alpha: backgroundAlpha)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height)))

        context.setFillColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: 1)
        context.fill(
            CGRect(
                x: size.width / 8,
                y: size.height / 6,
                width: size.width / 3,
                height: size.height / 2
            )
        )

        context.setStrokeColor(red: blue, green: red, blue: green, alpha: 1)
        context.setLineWidth(max(1, CGFloat(min(size.width, size.height)) / 48))
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: size.width, y: size.height))
        context.strokePath()

        guard let image = context.makeImage() else {
            throw SyntheticImageFixtureError.imageCreationFailed
        }
        return image
    }
}
