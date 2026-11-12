import CoreGraphics
import ImageIO
import SpectrumCore
import Foundation

@main
struct SpectrumTests {
    static func main() async throws {
        let checks = Self()
        try checks.testDominantBandsAtTwoSampleRates()
        try checks.testStreamingWrapAndSilenceSettles()
        try checks.testHighRefreshBetweenAudioBatches()
        try checks.testAccentFollowsDominantBands()
        try await checks.testArtworkPalette()
        try checks.testPaletteBlending()
        print("Core checks: frequency tracking, ring wrap, silence, high-refresh interpolation, artwork palette, frequency-driven accent and palette blending passed")
    }

    private enum Failure: Error { case assertion(String, UInt) }

    private func expect(_ result: @autoclosure () -> Bool, line: UInt = #line) throws {
        if !result() { throw Failure.assertion("检查结果不符合预期", line) }
    }

    private func require<T>(_ result: T?, line: UInt = #line) throws -> T {
        guard let result else { throw Failure.assertion("未获得预期数据", line) }
        return result
    }
    /// 确认峰值跟随真实频率与采样率，且频带不会读到窗口外的内存。
    func testDominantBandsAtTwoSampleRates() throws {
        for rate in [44_100.0, 48_000.0] {
            let input = try require(PCMBuffer())
            let analyzer = SpectrumAnalyzer(sampleRate: rate)
            for frequency in [93.0, 1_000.0, 8_000.0] {
                analyzer.reset(sampleRate: rate)
                let samples = (0..<SpectrumAnalyzer.size).map {
                    Float(0.24 * sin(2 * .pi * frequency * Double($0) / rate))
                }
                for _ in 0..<7 {
                    input.push(samples)
                    try expect(analyzer.step(input, dt: 1 / 30).audible)
                }
                let levels = analyzer.frame.levels
                let band = try require(levels.indices.max(by: { levels[$0] < levels[$1] }))
                try expect(abs(analyzer.frequencies[band] - Float(frequency)) < Float(frequency * 0.11))
                try expect(levels[band] > 0.75)
                try expect(levels[levels.count - 1 - band] < 0.3)
            }
        }
    }

    /// 分块输入跨过环尾；静音后柱高和峰值都回到零，后续不再请求重绘。
    func testStreamingWrapAndSilenceSettles() throws {
        let input = try require(PCMBuffer())
        let analyzer = SpectrumAnalyzer()
        for i in 0..<120 {
            let samples = (0..<1_024).map {
                Float(0.29 * sin(2 * .pi * 720 * Double(i * 1_024 + $0) / 48_000))
            }
            input.push(samples)
            analyzer.step(input, dt: 1_024 / 48_000)
        }
        try expect((analyzer.frame.levels.max() ?? 0) > 0.8)
        for _ in 0..<75 {
            input.push([Float](repeating: 0, count: 1_600))
            analyzer.step(input, dt: 1 / 30)
        }
        try expect(analyzer.frame.peaks.max() == 0)
        try expect(!analyzer.step(input, dt: 0.125).changed)
        try expect(!analyzer.step(input, dt: 0.125).audible)
    }

    /// 模拟 144 Hz 刷新，检查无新样本时继续平滑，明确静音或超时后回落。
    func testHighRefreshBetweenAudioBatches() throws {
        let input = try require(PCMBuffer())
        let analyzer = SpectrumAnalyzer()
        let interval = 1.0 / 144
        let tone = (0..<SpectrumAnalyzer.size).map { 0.2 * sinf(Float($0) * 0.13) }
        input.push(tone)
        try expect(analyzer.step(input, dt: interval).audible)
        let first = try require(analyzer.frame.levels.max())
        try expect(!analyzer.step(input, dt: interval).audible)
        let held = try require(analyzer.frame.levels.max())
        try expect(held > first)

        input.push([Float](repeating: 0, count: SpectrumAnalyzer.size))
        try expect(!analyzer.step(input, dt: interval).audible)
        try expect((analyzer.frame.levels.max() ?? 0) < held)

        input.push(tone)
        analyzer.step(input, dt: interval)
        for _ in 0..<8 { analyzer.step(input, dt: interval) }
        let expired = try require(analyzer.frame.levels.max())
        analyzer.step(input, dt: interval)
        try expect((analyzer.frame.levels.max() ?? 0) < expired)
    }

    /// 连续播放三段正弦波，检查辅色平滑追随低、中、高频，静音时停住。
    func testAccentFollowsDominantBands() throws {
        let input = try require(PCMBuffer())
        let analyzer = SpectrumAnalyzer()
        let dt = 1.0 / 30
        for (frequency, target) in [(65.0, 0.22), (600.0, 0.50), (5_200.0, 0.78)] {
            let previous = analyzer.frame.accentPosition
            let samples = (0..<SpectrumAnalyzer.size).map {
                Float(0.24 * sin(2 * .pi * frequency * Double($0) / 48_000))
            }
            input.push(samples)
            try expect(analyzer.step(input, dt: dt).audible)
            _ = analyzer.updateAccentPosition(dt: dt)
            try expect(abs(analyzer.frame.accentPosition - previous) < 0.06)
            for _ in 0..<45 {
                input.push(samples)
                analyzer.step(input, dt: dt)
                _ = analyzer.updateAccentPosition(dt: dt)
            }
            try expect(abs(analyzer.frame.accentPosition - target) < 0.045)
        }
        let last = analyzer.frame.accentPosition
        analyzer.reset(sampleRate: 48_000)
        try expect(!analyzer.updateAccentPosition(dt: dt) && analyzer.frame.accentPosition == last)
    }

    /// 用 PNG 验证低饱和底色、小面积辅色、灰度和透明度。
    func testArtworkPalette() async throws {
        let main = RGB(hex: 0xE1D8CE), accent = RGB(hex: 0xB54E3E)
        let cover = try png(main, accent, firstWidth: 58)
        let colorful = try require(await SpectrumPalette.artwork(cover))
        let base = try require(colorful.colors.first)
        let middle = colorful.colors[colorful.colors.count / 2]
        let width = try require(colorful.accentWidth)
        try expect(abs(base.green - main.green) < 0.035 && abs(base.blue - main.blue) < 0.035)
        try expect(abs(middle.green - accent.green) < 0.035 && abs(middle.blue - accent.blue) < 0.035)
        try expect(colorful.colors.last == base && (0.43...0.47).contains(width))

        let widerCover = try png(main, accent, firstWidth: 42)
        let wider = try require(await SpectrumPalette.artwork(widerCover))
        let widerWidth = try require(wider.accentWidth)
        try expect(widerWidth > width + 0.10)
        let movingFade = colorful.blended(to: wider, progress: 0.5)
        let blendedWidth = try require(movingFade.accentWidth)
        try expect(abs(blendedWidth - (width + widerWidth) / 2) < 0.0001)

        let fixed = SpectrumPalette([base])
        let left = fixed.blended(to: colorful, progress: 0.8, accentPosition: 0.22)
        let right = fixed.blended(to: colorful, progress: 0.8, accentPosition: 0.78)
        try expect(left.accentWidth == nil && right.accentWidth == nil)
        try expect(left.colors[25].green - left.colors[7].green > 0.3)
        try expect(right.colors[7].green - right.colors[25].green > 0.3)
        let fadeOut = colorful.blended(to: fixed, progress: 0.2, accentPosition: 0.22)
        try expect(abs(fadeOut.colors[7].green - left.colors[7].green) < 0.001)

        let gray = try png(RGB(hex: 0x303030), RGB(hex: 0xB5B5B5))
        let monochrome = try require(await SpectrumPalette.artwork(gray))
        try expect(monochrome.colors.allSatisfy { abs($0.red - $0.blue) < 0.001 && abs($0.green - $0.blue) < 0.001 })
        let grays = monochrome.colors.map(\.red)
        let darkest = try require(grays.min())
        let lightest = try require(grays.max())
        try expect(lightest - darkest > 0.35)

        let transparent = try png(main, accent, firstWidth: 0, lastAlpha: 0)
        let invisible = await SpectrumPalette.artwork(transparent)
        let invalid = await SpectrumPalette.artwork(Data([1, 2, 3]))
        try expect(invisible == nil && invalid == nil)
        let translucent = try png(main, accent, firstWidth: 0, lastAlpha: 0.7)
        let visible = try require(await SpectrumPalette.artwork(translucent))
        try expect(visible.accentWidth == nil)
        let first = try require(visible.colors.first)
        try expect(abs(first.red - accent.red) < 0.02 && abs(first.green - accent.green) < 0.02)
    }

    /// 验证 OKLab 的半程明度，以及不同色标数量的过渡端点。
    func testPaletteBlending() throws {
        let black = RGB(hex: 0x000000), white = RGB(hex: 0xFFFFFF)
        let solid = SpectrumPalette([black])
        let gradient = SpectrumPalette([black, white])
        let midpoint = solid.blended(to: gradient, progress: 0.5)
        try expect(midpoint.colors.first == black)
        let half = try require(midpoint.colors.last)
        try expect(abs(half.red - 0.389) < 0.002 && abs(half.red - half.blue) < 0.001)
        try expect(solid.blended(to: .aurora, progress: 0) == solid)
        try expect(solid.blended(to: .aurora, progress: 1) == .aurora)
        let neutral = SpectrumPalette([RGB(0.5, 0.5, 0.5), RGB(0.5, 0.5, 0.5), RGB(0.5, 0.5, 0.5)])
        let three = gradient.blended(to: neutral, progress: 0.5)
        try expect(three.colors.count == 3 && three.colors[1] == RGB(0.5, 0.5, 0.5))
        try expect(three.colors[0].red < 0.25 && three.colors[2].red > 0.73)
    }

    private func png(_ first: RGB, _ last: RGB, firstWidth: CGFloat = 40, lastAlpha: CGFloat = 1) throws -> Data {
        let ctx = try require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: RGB.space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(first.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: firstWidth, height: 64))
        ctx.setFillColor(try require(last.cgColor.copy(alpha: lastAlpha)))
        ctx.fill(CGRect(x: firstWidth, y: 0, width: 64 - firstWidth, height: 64))
        let data = NSMutableData()
        let destination = try require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        let image = try require(ctx.makeImage())
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
