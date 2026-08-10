import CoreGraphics
import Foundation

// ThumbHash decoder derived from Evan Wallace's ThumbHash reference algorithm.
// Copyright (c) 2023 Evan Wallace. Used under the MIT License.
// https://github.com/evanw/thumbhash

struct DecodedThumbHash: Equatable, Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

final class ThumbHashDecoder: @unchecked Sendable {
    private let cache = NSCache<NSString, RenderSurface>()

    init(countLimit: Int = 256) {
        cache.countLimit = countLimit
    }

    func decode(base64: String) throws -> RenderSurface {
        if let cached = cache.object(forKey: base64 as NSString) { return cached }
        guard let data = Data(base64Encoded: base64) else { throw MediaError.corruptMedia }
        let decoded = try decodeBytes(Array(data))
        guard let provider = CGDataProvider(data: Data(decoded.rgba) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: decoded.width,
                height: decoded.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: decoded.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw MediaError.corruptMedia
        }
        let surface = RenderSurface(cgImage: image)
        cache.setObject(surface, forKey: base64 as NSString)
        return surface
    }

    func decodeBytes(_ hash: [UInt8]) throws -> DecodedThumbHash {
        guard hash.count >= 5 else { throw MediaError.corruptMedia }
        let header24 = Int(hash[0]) | Int(hash[1]) << 8 | Int(hash[2]) << 16
        let header16 = Int(hash[3]) | Int(hash[4]) << 8
        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = (header24 & (1 << 23)) != 0
        guard !hasAlpha || hash.count >= 6 else { throw MediaError.corruptMedia }
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = (header16 & (1 << 15)) != 0
        let shortCount = Int(header16 & 7)
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : shortCount)
        let ly = max(3, isLandscape ? shortCount : (hasAlpha ? 5 : 7))
        let aDC = hasAlpha ? Double(hash[5] & 15) / 15 : 1
        let aScale = hasAlpha ? Double(hash[5] >> 4) / 15 : 0

        var nibbleIndex = 0
        let acStart = hasAlpha ? 6 : 5
        let l = try channel(hash, start: acStart, nibbleIndex: &nibbleIndex, nx: lx, ny: ly, dc: lDC, scale: lScale)
        let p = try channel(hash, start: acStart, nibbleIndex: &nibbleIndex, nx: 3, ny: 3, dc: pDC, scale: pScale)
        let q = try channel(hash, start: acStart, nibbleIndex: &nibbleIndex, nx: 3, ny: 3, dc: qDC, scale: qScale)
        let alpha = hasAlpha
            ? try channel(hash, start: acStart, nibbleIndex: &nibbleIndex, nx: 5, ny: 5, dc: aDC, scale: aScale)
            : Channel(dc: 1, nx: 0, ny: 0, ac: [])

        let ratio = Double(lx) / Double(ly)
        let width = ratio > 1 ? 32 : max(1, Int((32 * ratio).rounded()))
        let height = ratio > 1 ? max(1, Int((32 / ratio).rounded())) : 32
        var rgba = [UInt8]()
        rgba.reserveCapacity(width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let luminance = max(0, l.value(x: x, y: y, width: width, height: height))
                let pValue = p.value(x: x, y: y, width: width, height: height)
                let qValue = q.value(x: x, y: y, width: width, height: height)
                let blue = luminance - 2 * pValue / 3
                let red = (3 * luminance - blue + qValue) / 2
                let green = red - qValue
                let a = alpha.value(x: x, y: y, width: width, height: height)
                rgba.append(byte(red))
                rgba.append(byte(green))
                rgba.append(byte(blue))
                rgba.append(byte(a))
            }
        }
        return .init(width: width, height: height, rgba: rgba)
    }

    private struct Channel {
        let dc: Double
        let nx: Int
        let ny: Int
        var ac: [Double]

        func value(x: Int, y: Int, width: Int, height: Int) -> Double {
            var value = dc
            var index = 0
            for cy in 0..<ny {
                for cx in 0..<nx where cx != 0 || cy != 0 {
                    guard cx * ny < nx * (ny - cy) else { continue }
                    value += ac[index]
                        * cos(.pi / Double(width) * (Double(x) + 0.5) * Double(cx))
                        * cos(.pi / Double(height) * (Double(y) + 0.5) * Double(cy))
                    index += 1
                }
            }
            return value
        }
    }

    private func channel(
        _ hash: [UInt8],
        start: Int,
        nibbleIndex: inout Int,
        nx: Int,
        ny: Int,
        dc: Double,
        scale: Double
    ) throws -> Channel {
        var ac: [Double] = []
        for cy in 0..<ny {
            for cx in 0..<nx where cx != 0 || cy != 0 {
                guard cx * ny < nx * (ny - cy) else { continue }
                let byteIndex = start + nibbleIndex / 2
                guard byteIndex < hash.count else { throw MediaError.corruptMedia }
                let shift = (nibbleIndex & 1) * 4
                let coefficient = Double((Int(hash[byteIndex]) >> shift) & 15) / 7.5 - 1
                ac.append(coefficient * scale)
                nibbleIndex += 1
            }
        }
        return Channel(dc: dc, nx: nx, ny: ny, ac: ac)
    }

    private func byte(_ value: Double) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}
