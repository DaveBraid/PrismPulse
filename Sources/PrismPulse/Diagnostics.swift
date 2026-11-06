import AppKit
import AVFoundation
import ImageIO
import SpectrumCore

enum Diagnostics {
    /// 输出固定信号通过 PCM 缓冲与 FFT 的平均耗时，供 Release 构建复测。
    static func benchmark() {
        guard let source = PCMBuffer() else { exit(1) }
        let analyzer = SpectrumAnalyzer()
        let input = (0..<SpectrumAnalyzer.size).map { i in
            0.16 * sinf(2 * .pi * 440 * Float(i) / 48_000) +
            0.10 * sinf(2 * .pi * 3_400 * Float(i) / 48_000)
        }
        for _ in 0..<100 { source.push(input); analyzer.step(source, dt: 1 / 30) }
        let count = 4_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count { source.push(input); analyzer.step(source, dt: 1 / 30) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
        print(String(format: "PCM + 4096 FFT + 48 bands: %.3f ms/frame (%d frames)", elapsed / Double(count) / 1e6, count))
    }

    /// 以低音量短播测试音，验证实际 Core Audio Tap 是否把该频段交给分析器。
    static func audioSmoke() -> Int32 {
        do {
            let session = try TapSession()
            print("Core Audio tap started: \(session.sampleRate) Hz")
            fflush(stdout)
            let frequency = 997.0
            let player = try AVAudioPlayer(data: tone(frequency))
            guard player.play() else { return 2 }
            defer { player.stop() }
            let analyzer = SpectrumAnalyzer(sampleRate: session.sampleRate)
            let end = ProcessInfo.processInfo.systemUptime + 2.2
            var hits = 0
            while ProcessInfo.processInfo.systemUptime < end {
                Thread.sleep(forTimeInterval: 0.033)
                guard analyzer.step(session.pcm, dt: 0.033).audible,
                      let index = analyzer.frame.levels.indices.max(by: { analyzer.frame.levels[$0] < analyzer.frame.levels[$1] })
                else { continue }
                if abs(Double(analyzer.frequencies[index]) - frequency) < frequency * 0.15 { hits += 1 }
            }
            withExtendedLifetime(session) {}
            if hits < 3 {
                fputs("Audio smoke: no matching captured signal; check system audio permission and output route.\n", stderr)
                return 3
            }
            print("Audio smoke: verified \(Int(frequency)) Hz system output in \(hits) analysis frames")
            return 0
        } catch {
            fputs("Audio smoke: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func tone(_ hz: Double) -> Data {
        let rate: UInt32 = 48_000
        let frames = 67_200
        var data = Data()
        func four(_ text: String) { data.append(contentsOf: text.utf8) }
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        four("RIFF"); append(UInt32(36 + frames * 2)); four("WAVE")
        four("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        four("data"); append(UInt32(frames * 2))
        for i in 0..<frames {
            let fade = min(1, Double(min(i, frames - 1 - i)) / 1200)
            append(Int16(590 * fade * sin(2 * .pi * hz * Double(i) / Double(rate))))
        }
        return data
    }

    /// 输出使用真实渲染器绘制的样式图，便于一次检查全部样式。
    static func gallery(to path: String) throws {
        let width = 1320, height = 784
        let context = try bitmap(width: width, height: height)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        let backdrop = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(RGB(hex: 0x0B101B).cgColor)
        context.fill(backdrop)
        let painter = SpectrumPainter()
        let painterFrame = SpectrumFrame(levels: [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
        let tint = NSColor(srgbRed: 0.35, green: 0.90, blue: 0.79, alpha: 1)
        let muted = NSColor(srgbRed: 0.60, green: 0.68, blue: 0.79, alpha: 1)
        let text = NSColor(srgbRed: 0.91, green: 0.95, blue: 1.0, alpha: 1)
        label("PRISMPULSE   /   STYLE INDEX", x: 40, y: 734, font: .monospacedSystemFont(ofSize: 13, weight: .semibold), color: tint)
        label("流光频谱", x: 39, y: 672, font: .systemFont(ofSize: 46, weight: .semibold), color: text)
        label("14 种频谱样式 · 同一段示例信号", x: 40, y: 644, font: .systemFont(ofSize: 16, weight: .medium), color: muted)
        label("macOS    /    SYSTEM AUDIO", x: 1048, y: 734, font: .monospacedSystemFont(ofSize: 12, weight: .medium), color: muted)
        let colors: [SpectrumPalette] = [.aurora, .dusk, .lagoon, .amber]
        let styles = SpectrumStyle.allCases
        for index in 0..<16 {
            let column = index % 4, row = index / 4
            let x = 40 + 314 * column, y = 494 - 145 * row
            let tile = CGRect(x: x, y: y, width: 298, height: 132)
            context.setFillColor(RGB(hex: 0x141C2C).cgColor)
            context.setStrokeColor(RGB(hex: 0x28364F).cgColor)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 15, cornerHeight: 15, transform: nil))
            context.drawPath(using: .fillStroke)
            let tileTitle = index < styles.count ? styles[index].rawValue : (index == 14 ? "菜单栏 · 12 条" : "配色")
            label(tileTitle, x: x + 15, y: y + 99, font: .systemFont(ofSize: 15, weight: .semibold), color: text)
            label(index < styles.count ? String(format: "%02d", index + 1) : (index == 14 ? "MENU" : "COLOR"),
                  x: x + (index < styles.count ? 260 : 238), y: y + 101,
                  font: .monospacedSystemFont(ofSize: 11, weight: .medium), color: muted)
            painterFrame.demo(at: 1.77)
            painter.setPalette(colors[row])
            if index < styles.count {
                painter.draw(painterFrame, in: context, rect: CGRect(x: x + 15, y: y + 15, width: 268, height: 70),
                             style: styles[index], vertical: false, compact: false)
            } else if index == 14 {
                let pill = CGRect(x: x + 97, y: y + 33, width: 104, height: 40)
                context.setFillColor(RGB(hex: 0x080C13).cgColor)
                context.addPath(CGPath(roundedRect: pill, cornerWidth: 15, cornerHeight: 15, transform: nil))
                context.fillPath()
                painter.draw(painterFrame, in: context, rect: pill.insetBy(dx: 12, dy: 9), style: .prism, vertical: false, compact: true)
            } else {
                for (i, palette) in colors.enumerated() {
                    let cg = CGGradient(colorsSpace: RGB.space, colors: palette.colors.map(\.cgColor) as CFArray, locations: nil)!
                    let strip = CGRect(x: x + 15, y: y + 68 - i * 15, width: 268, height: 7)
                    context.saveGState()
                    context.addPath(CGPath(roundedRect: strip, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
                    context.clip()
                    context.drawLinearGradient(cg, start: CGPoint(x: strip.minX, y: strip.midY),
                                               end: CGPoint(x: strip.maxX, y: strip.midY), options: [])
                    context.restoreGState()
                }
            }
        }
        try write(context, to: path)
    }

    /// 用相同的色板和柱形图生成应用图标的源 PNG。
    static func icon(to path: String) throws {
        let context = try bitmap(width: 1024, height: 1024)
        let tile = CGRect(x: 84, y: 84, width: 856, height: 856)
        context.saveGState()
        let border = CGPath(roundedRect: tile, cornerWidth: 208, cornerHeight: 208, transform: nil)
        context.addPath(border)
        context.clip()
        let colors = [RGB(hex: 0x101929), RGB(hex: 0x242048)].map(\.cgColor)
        let bg = CGGradient(colorsSpace: RGB.space, colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(bg, start: .init(x: 100, y: 110), end: .init(x: 850, y: 900),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
        context.setStrokeColor(RGB(hex: 0x455779).cgColor)
        context.setLineWidth(8)
        context.addPath(border)
        context.strokePath()
        let painter = SpectrumPainter()
        painter.setPalette(.aurora)
        let data = SpectrumFrame(levels: [0.22, 0.43, 0.76, 1, 0.66, 0.44, 0.57, 0.26, 0.15])
        painter.draw(data, in: context, rect: CGRect(x: 195, y: 289, width: 634, height: 446),
                     style: .mirror, vertical: false, compact: false)
        try write(context, to: path)
    }

    private static func label(_ text: String, x: Int, y: Int, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: RGB.space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        return context
    }

    private static func write(_ context: CGContext, to path: String) throws {
        guard let image = context.makeImage(),
              let writer = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
    }
}
