import Foundation

/// 封面渐变与切歌过渡共用的感知色彩空间。
/// 转换矩阵来自 https://bottosson.github.io/posts/oklab/
struct OKLab {
    let l: Double
    let a: Double
    let b: Double

    init(_ l: Double, _ a: Double, _ b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// 输入为 sRGB 色标。先去除传递曲线，再转换到 OKLab。
    init(_ color: RGB) {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let x = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let y = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let z = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.init(0.2104542553 * x + 0.7936177850 * y - 0.0040720468 * z,
                  1.9779984951 * x - 2.4285922050 * y + 0.4505937099 * z,
                  0.0259040371 * x + 0.7827717662 * y - 0.8086757660 * z)
    }

    func distance(to other: OKLab) -> Double {
        hypot(l - other.l, hypot(a - other.a, b - other.b))
    }

    func mixed(with other: OKLab, fraction: Double) -> OKLab {
        OKLab(l + (other.l - l) * fraction, a + (other.a - a) * fraction, b + (other.b - b) * fraction)
    }

    /// 抬升很暗的颜色，保留冷暖关系和灰度。
    var withVisibleLightness: OKLab { OKLab(l < 0.45 ? 0.34 + l * 0.244 : l, a, b) }

    /// 输出可绘制的 sRGB。超出色域时降低彩度，保留明度和色相。
    var sRGB: RGB {
        var channels = linearRGB(chromaScale: 1)
        if !Self.inGamut(channels) {
            var lower = 0.0, upper = 1.0
            for _ in 0..<8 {
                let middle = (lower + upper) / 2
                if Self.inGamut(linearRGB(chromaScale: middle)) { lower = middle }
                else { upper = middle }
            }
            channels = linearRGB(chromaScale: lower)
        }
        func encode(_ value: Double) -> Double {
            let channel = min(1, max(0, value))
            return channel <= 0.0031308 ? 12.92 * channel : 1.055 * pow(channel, 1 / 2.4) - 0.055
        }
        return RGB(encode(channels.x), encode(channels.y), encode(channels.z))
    }

    private func linearRGB(chromaScale: Double) -> SIMD3<Double> {
        let scaledA = a * chromaScale, scaledB = b * chromaScale
        let lRoot = l + 0.3963377774 * scaledA + 0.2158037573 * scaledB
        let mRoot = l - 0.1055613458 * scaledA - 0.0638541728 * scaledB
        let sRoot = l - 0.0894841775 * scaledA - 1.2914855480 * scaledB
        let lCone = lRoot * lRoot * lRoot, mCone = mRoot * mRoot * mRoot, sCone = sRoot * sRoot * sRoot
        return SIMD3(4.0767416621 * lCone - 3.3077115913 * mCone + 0.2309699292 * sCone,
                     -1.2684380046 * lCone + 2.6097574011 * mCone - 0.3413193965 * sCone,
                     -0.0041960863 * lCone - 0.7034186147 * mCone + 1.7076147010 * sCone)
    }

    private static func inGamut(_ color: SIMD3<Double>) -> Bool {
        // 容差避免舍入误差让纯黑、纯白或边界颜色反复映射。
        let range = -0.000001...1.000001
        return range.contains(color.x) && range.contains(color.y) && range.contains(color.z)
    }
}
