import CoreGraphics
import ImageIO
import SpectrumCore
import Foundation

@main
struct SpectrumTests {
    static func main() throws {
        let checks = Self()
        try checks.testDominantBandsAtTwoSampleRates()
        try checks.testStreamingWrapAndSilenceSettles()
        try checks.testHighRefreshBetweenAudioBatches()
        try checks.testArtworkPalette()
        print("Core checks: frequency tracking, ring wrap, silence, high-refresh interpolation and artwork palette passed")
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

    /// 使用真实 PNG 输入验证双色、灰度封面和无效数据的处理。
    func testArtworkPalette() throws {
        let cover = try png(RGB(hex: 0xDE241A), RGB(hex: 0x2858D9))
        let colorful = try require(SpectrumPalette.artwork(cover))
        try expect(colorful.colors.count == 3)
        try expect(colorful.colors.contains { $0.red > $0.blue + 0.18 })
        try expect(colorful.colors.contains { $0.blue > $0.red + 0.18 })
        let gray = try png(RGB(hex: 0x303030), RGB(hex: 0xB5B5B5))
        try expect(SpectrumPalette.artwork(gray) == .silver)
        try expect(SpectrumPalette.artwork(Data([1, 2, 3])) == nil)
    }

    private func png(_ first: RGB, _ last: RGB) throws -> Data {
        let ctx = try require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: RGB.space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(first.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 64))
        ctx.setFillColor(last.cgColor)
        ctx.fill(CGRect(x: 40, y: 0, width: 24, height: 64))
        let data = NSMutableData()
        let destination = try require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        let image = try require(ctx.makeImage())
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
