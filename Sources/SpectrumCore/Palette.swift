import CoreGraphics
import Foundation
import ImageIO

public struct RGB: Equatable, Codable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 255) / 255,
                  Double((hex >> 8) & 255) / 255,
                  Double(hex & 255) / 255)
    }

    public static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    fileprivate init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - floor(hue)) * 6
        let i = Int(h)
        let f = h - Double(i)
        let v = brightness
        let p = v * (1 - saturation)
        let q = v * (1 - saturation * f)
        let t = v * (1 - saturation * (1 - f))
        switch i {
        case 0: self.init(v, t, p)
        case 1: self.init(q, v, p)
        case 2: self.init(p, v, t)
        case 3: self.init(p, q, v)
        case 4: self.init(t, p, v)
        default: self.init(v, p, q)
        }
    }
}

public struct SpectrumPalette: Equatable, Sendable {
    public var colors: [RGB]
    public init(_ colors: [RGB]) { self.colors = colors }

    public static let aurora = SpectrumPalette([RGB(hex: 0x55F0D2), RGB(hex: 0x64A4FF), RGB(hex: 0xDB83FF)])
    public static let dusk = SpectrumPalette([RGB(hex: 0xFF8D69), RGB(hex: 0xEF64B2), RGB(hex: 0x9979FF)])
    public static let amber = SpectrumPalette([RGB(hex: 0xFC6F57), RGB(hex: 0xFFC55C), RGB(hex: 0xFFF0AC)])
    public static let lagoon = SpectrumPalette([RGB(hex: 0x30BAFF), RGB(hex: 0x44E8D4), RGB(hex: 0xC0FF7B)])
    public static let silver = SpectrumPalette([RGB(hex: 0x8295B1), RGB(hex: 0xD9E4F0), RGB(hex: 0xF7FBFF)])

    /// 先按相同位置采样两组渐变，再混合颜色，兼容单色、双色和封面三色。
    public func blended(to target: SpectrumPalette, progress: Double) -> SpectrumPalette {
        guard progress > 0 else { return self }
        guard progress < 1, !colors.isEmpty, !target.colors.isEmpty else { return target }
        let count = max(colors.count, target.colors.count)
        return SpectrumPalette((0..<count).map { i in
            let position = Double(i) / Double(max(1, count - 1))
            let a = sampled(at: position), b = target.sampled(at: position)
            return RGB(a.red + (b.red - a.red) * progress,
                       a.green + (b.green - a.green) * progress,
                       a.blue + (b.blue - a.blue) * progress)
        })
    }

    private func sampled(at position: Double) -> RGB {
        let offset = position * Double(colors.count - 1)
        let index = Int(offset)
        let a = colors[index], b = colors[min(index + 1, colors.count - 1)]
        let fraction = offset - Double(index)
        return RGB(a.red + (b.red - a.red) * fraction,
                   a.green + (b.green - a.green) * fraction,
                   a.blue + (b.blue - a.blue) * fraction)
    }

    /// 输入为原封面字节；ImageIO 缩略解码后提取两组色相，输出三段可读渐变。
    public static func artwork(_ data: Data) -> SpectrumPalette? {
        guard !data.isEmpty, data.count <= 12 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 48,
              ] as CFDictionary)
        else { return nil }

        let width = thumbnail.width, height = thumbnail.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes -> SpectrumPalette? in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: RGB.space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
            let count = 36  // 以 10° 为一组，合并相邻色相的权重。
            var votes = [Double](repeating: 0, count: count)
            var saturation = votes
            var chroma = 0.0
            var visible = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Double(bytes[i + 3])
                guard alpha > 140 else { continue }
                visible += 1
                let r = Double(bytes[i]) / alpha
                let g = Double(bytes[i + 1]) / alpha
                let b = Double(bytes[i + 2]) / alpha
                let hi = max(r, g, b), lo = min(r, g, b)
                let delta = hi - lo
                guard hi > 0.16, delta > 0.075 else { continue }
                let s = delta / hi
                guard s > 0.17 else { continue }
                let raw = hi == r ? (g - b) / delta : hi == g ? 2 + (b - r) / delta : 4 + (r - g) / delta
                let hue = (raw + 6).truncatingRemainder(dividingBy: 6) / 6
                let index = Int(hue * Double(count)) % count
                let weight = s * (0.25 + hi * 0.75)
                votes[index] += weight
                saturation[index] += weight * s
                chroma += weight
            }
            guard visible > 0 else { return nil }
            guard chroma > Double(visible) * 0.014 else { return .silver }

            let scores = votes.indices.map { i in
                votes[i] + 0.55 * (votes[(i + count - 1) % count] + votes[(i + 1) % count])
            }
            let primary = scores.indices.max { scores[$0] < scores[$1] }!
            let secondary = scores.indices.filter {
                let delta = abs($0 - primary)
                return min(delta, count - delta) >= 4
            }.max { scores[$0] < scores[$1] }!
            let hue = (Double(primary) + 0.5) / Double(count)
            let hasSecondary = scores[secondary] >= scores[primary] * 0.19
            let other = hasSecondary ? (Double(secondary) + 0.5) / Double(count) : hue + 0.085
            let s = min(0.84, max(0.54, saturation[primary] / max(votes[primary], 0.001)))
            let direction = (other - hue + 1.5).truncatingRemainder(dividingBy: 1) - 0.5
            return SpectrumPalette([
                RGB(hue: hue, saturation: s, brightness: 0.95),
                RGB(hue: hue + 0.52 * direction, saturation: 0.66, brightness: 1),
                RGB(hue: other, saturation: 0.44, brightness: 1),
            ])
        }
    }
}
