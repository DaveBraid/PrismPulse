import CoreGraphics
import Foundation
import ImageIO
import PaletteKit

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
}

public struct SpectrumPalette: Equatable, Sendable {
    public var colors: [RGB]
    public init(_ colors: [RGB]) { self.colors = colors }

    public static let aurora = SpectrumPalette([RGB(hex: 0x55F0D2), RGB(hex: 0x64A4FF), RGB(hex: 0xDB83FF)])
    public static let dusk = SpectrumPalette([RGB(hex: 0xFF8D69), RGB(hex: 0xEF64B2), RGB(hex: 0x9979FF)])
    public static let amber = SpectrumPalette([RGB(hex: 0xFC6F57), RGB(hex: 0xFFC55C), RGB(hex: 0xFFF0AC)])
    public static let lagoon = SpectrumPalette([RGB(hex: 0x30BAFF), RGB(hex: 0x44E8D4), RGB(hex: 0xC0FF7B)])
    public static let silver = SpectrumPalette([RGB(hex: 0x8295B1), RGB(hex: 0xD9E4F0), RGB(hex: 0xF7FBFF)])

    /// 在相同位置采样当前和目标渐变，再用 OKLab 混合，保持切歌中断时连续。
    public func blended(to target: SpectrumPalette, progress: Double) -> SpectrumPalette {
        guard progress > 0 else { return self }
        guard progress < 1, !colors.isEmpty, !target.colors.isEmpty else { return target }
        let count = max(colors.count, target.colors.count)
        return SpectrumPalette((0..<count).map { i in
            let position = Double(i) / Double(max(1, count - 1))
            let a = sampled(at: position), b = target.sampled(at: position)
            return a == b ? a : OKLab(a).mixed(with: OKLab(b), fraction: progress).sRGB
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

    /// 输入为封面字节。缩略解码后按像素占比分色，返回可缓存的渐变色标。
    public static func artwork(_ data: Data) async -> SpectrumPalette? {
        guard !data.isEmpty, data.count <= 12 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 48,
              ] as CFDictionary)
        else { return nil }

        let width = thumbnail.width, height = thumbnail.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let pixels = rgba.withUnsafeMutableBytes { bytes -> [PixelTriplet] in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: RGB.space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return [] }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
            var pixels: [PixelTriplet] = []
            pixels.reserveCapacity(width * height)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(bytes[offset + 3])
                guard alpha > 140 else { continue } // 忽略透明边缘。
                func channel(_ index: Int) -> UInt8 {
                    // 去掉预乘 Alpha 的影响，保留半透明像素本身的颜色。
                    UInt8(clamping: (Int(bytes[index]) * 255 + alpha / 2) / alpha)
                }
                pixels.append(PixelTriplet(r: channel(offset), g: channel(offset + 1), b: channel(offset + 2)))
            }
            return pixels
        }
        guard !pixels.isEmpty, let groups = try? await MmcqQuantizer().quantize(pixels: pixels, maxColors: 6) else { return nil }
        let ordered = groups.filter { $0.population > 0 }.sorted { first, second in
            if first.population != second.population { return first.population > second.population }
            // 面积相等时使用固定顺序，同一张封面再次出现也不会交换主辅色。
            let a = first.color, b = second.color
            return (a.r, a.g, a.b) < (b.r, b.g, b.b)
        }
        let swatches = ordered.map { group in
            let color = group.color
            let rgb = RGB(Double(color.r) / 255, Double(color.g) / 255, Double(color.b) / 255)
            return (color: OKLab(rgb), population: group.population)
        }
        guard let primary = swatches.first else { return nil }
        let total = Double(swatches.reduce(0) { $0 + $1.population })
        var base = primary.color
        var population = primary.population
        for swatch in swatches.dropFirst() where swatch.color.distance(to: primary.color) < 0.075 {
            // 相近的色组一起构成底色，避免缩略图噪点影响色相。
            population += swatch.population
            base = base.mixed(with: swatch.color, fraction: Double(swatch.population) / Double(population))
        }
        base = base.withVisibleLightness

        let secondary = swatches.dropFirst().first {
            Double($0.population) / total >= 0.05 && $0.color.distance(to: primary.color) >= 0.09
        }
        let accent: OKLab
        let transitionStart: Double
        let transitionWidth: Double
        if let secondary {
            let share = Double(secondary.population) / total
            accent = secondary.color.withVisibleLightness
            transitionStart = max(0.38, 0.72 - 0.65 * share) // 辅色面积越大，越早进入过渡。
            transitionWidth = 0.22
        } else {
            // 单色封面沿用原色相，只做明度变化。
            accent = OKLab(min(0.97, base.l + 0.075), base.a, base.b)
            transitionStart = 0
            transitionWidth = 1
        }
        // 预采样 OKLab 渐变，绘制时继续复用普通的 Core Graphics 渐变。
        return SpectrumPalette((0...32).map { index in
            let position = Double(index) / 32
            let fraction = min(1, max(0, (position - transitionStart) / transitionWidth))
            return base.mixed(with: accent, fraction: fraction).sRGB
        })
    }
}
