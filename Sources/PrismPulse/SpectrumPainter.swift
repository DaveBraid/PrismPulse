import AppKit
import SpectrumCore

/// 实时层只组装几何并按形状填色；渐变在颜色变化时才创建。
final class SpectrumPainter {
    private var palette: SpectrumPalette?
    private var gradient: CGGradient?
    private var solid = RGB(hex: 0x54F1CE).cgColor
    private var radial: [CGPoint] = []
    private var menuLevels = [Float](repeating: 0, count: 12)
    private var menuPeaks = [Float](repeating: 0, count: 12)

    func setPalette(_ palette: SpectrumPalette) {
        guard self.palette != palette, let color = palette.colors.first else { return }
        self.palette = palette
        solid = color.cgColor
        gradient = palette.colors.count < 2 ? nil : CGGradient(
            colorsSpace: RGB.space, colors: palette.colors.map(\.cgColor) as CFArray, locations: nil
        )
    }

    /// 输入实时帧、画布与样式。菜单栏按宽度合并频带，铺满时可绘制全部 48 带。
    func draw(_ frame: SpectrumFrame, in context: CGContext, rect: CGRect, style: SpectrumStyle,
              vertical: Bool, compact: Bool, cornerRadius: CGFloat = 0) {
        guard rect.width > 4, rect.height > 4 else { return }
        let statusStyle = style == .orbit || style == .halo ? .mirror : style
        let count = max(4, Int(rect.width / 4.25))
        if !compact || count >= frame.levels.count {
            draw(frame.levels, peaks: frame.peaks, in: context, rect: rect,
                 style: compact ? statusStyle : style, vertical: vertical,
                 cornerRadius: compact ? 0 : cornerRadius)
            return
        }
        if menuLevels.count != count {
            menuLevels = Array(repeating: 0, count: count)
            menuPeaks = Array(repeating: 0, count: count)
        }
        for i in menuLevels.indices {
            let lo = i * frame.levels.count / count
            let hi = (i + 1) * frame.levels.count / count
            var level: Float = 0, peak: Float = 0
            for j in lo..<hi {
                level = max(level, frame.levels[j])
                peak = max(peak, frame.peaks[j])
            }
            menuLevels[i] = level
            menuPeaks[i] = peak
        }
        draw(menuLevels, peaks: menuPeaks, in: context, rect: rect,
             style: statusStyle, vertical: vertical, cornerRadius: 0)
    }

    /// 使用同一条线性渐变为几何填色，避免为每一条柱形单独生成渐变。
    private func paint(_ path: CGPath, in context: CGContext, rect: CGRect, vertical: Bool, alpha: CGFloat = 1) {
        if path.isEmpty { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.addPath(path)
        if let gradient {
            context.clip()
            let start = CGPoint(x: rect.minX, y: vertical ? rect.minY : rect.midY)
            let end = CGPoint(x: vertical ? rect.minX : rect.maxX, y: vertical ? rect.maxY : rect.midY)
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            context.setFillColor(solid)
            context.fillPath()
        }
        context.restoreGState()
    }

    private func draw(_ levels: [Float], peaks: [Float], in context: CGContext, rect: CGRect,
                      style: SpectrumStyle, vertical: Bool, cornerRadius: CGFloat) {
        let shape = CGMutablePath()
        let accents = CGMutablePath()
        let step = rect.width / CGFloat(levels.count)
        let minimum = min(2.0, rect.height * 0.16)
        let span = rect.height - minimum

        switch style {
        case .prism, .reeds, .mirror, .segments, .beads, .peaks, .comet:
            let width = max(1, step * (style == .reeds ? 0.25 : style == .beads ? 0.53 : 0.68))
            let rows = max(3, min(10, Int(rect.height / max(3, width * 0.95)))) // 限制单帧图元数量。
            let pitch = rect.height / CGFloat(rows)
            for i in levels.indices {
                let x = rect.minX + (CGFloat(i) + 0.5) * step
                let level = CGFloat(levels[i])
                let height = minimum + level * span
                switch style {
                case .segments, .beads:
                    let count = min(rows, max(1, Int(ceil(level * CGFloat(rows)))))
                    let dotSize = min(width, pitch * 0.70)
                    for row in 0..<count {
                        let y = rect.minY + CGFloat(row) * pitch
                        if style == .segments {
                            let block = CGRect(x: x - width / 2, y: y, width: width, height: pitch * 0.69)
                            shape.addRoundedRect(in: block, cornerWidth: min(1.1, width / 4), cornerHeight: min(1.1, pitch / 5))
                        } else {
                            shape.addEllipse(in: CGRect(x: x - dotSize / 2, y: y, width: dotSize, height: dotSize))
                        }
                    }
                case .comet:
                    let size = min(width, minimum + 1 + level * 3)
                    let tail = CGRect(x: x - width * 0.13, y: rect.minY,
                                      width: max(0.8, width * 0.26), height: max(0, height - size))
                    accents.addRect(tail)
                    shape.addEllipse(in: CGRect(x: x - size / 2, y: rect.minY + max(0, height - size), width: size, height: size))
                default:
                    let y = style == .mirror ? rect.midY - height / 2 : rect.minY
                    let bar = CGRect(x: x - width / 2, y: y, width: width, height: height)
                    let radius = min(width * 0.45, height * 0.48)
                    shape.addRoundedRect(in: bar, cornerWidth: radius, cornerHeight: radius)
                    if style == .peaks, peaks[i] - levels[i] > 0.025 {
                        accents.addRect(CGRect(x: x - width / 2, y: rect.minY + CGFloat(peaks[i]) * span, width: width, height: minimum))
                    }
                }
            }
            paint(accents, in: context, rect: rect, vertical: vertical, alpha: style == .comet ? 0.38 : 0.85)
            paint(shape, in: context, rect: rect, vertical: vertical)
        case .wave, .silk, .double, .ridge, .ribbons:
            let centered = style == .silk || style == .double || style == .ribbons
            let baseline = centered ? rect.midY : rect.minY
            let height = centered ? span * 0.47 : span
            if style == .wave || style == .ridge {
                let line = filledWave(shape, levels: levels, rect: rect, amplitude: height,
                                      radius: cornerRadius, smooth: style == .wave)
                paint(shape, in: context, rect: rect, vertical: vertical, alpha: style == .wave ? 0.48 : 0.63)
                paint(line, in: context, rect: rect, vertical: vertical)
            } else {
                trace(shape, levels: levels, rect: rect, baseline: baseline, amplitude: height, smooth: true)
                if style == .double || style == .ribbons {
                    trace(accents, levels: levels, rect: rect, baseline: baseline, amplitude: -height * 0.93, smooth: true)
                    paint(accents.copy(strokingWithWidth: 1.4, lineCap: .round, lineJoin: .round, miterLimit: 2),
                          in: context, rect: rect, vertical: vertical, alpha: 0.72)
                }
                if style == .ribbons {
                    let middle = CGMutablePath()
                    trace(middle, levels: peaks, rect: rect, baseline: baseline, amplitude: height * 0.37, smooth: true)
                    paint(middle.copy(strokingWithWidth: 1.1, lineCap: .round, lineJoin: .round, miterLimit: 2),
                          in: context, rect: rect, vertical: vertical, alpha: 0.44)
                }
                paint(shape.copy(strokingWithWidth: min(2.5, max(1.3, rect.height / 46)),
                                 lineCap: .round, lineJoin: .round, miterLimit: 2),
                      in: context, rect: rect, vertical: vertical)
            }
        case .orbit, .halo:
            if radial.count != levels.count {
                radial = levels.indices.map {
                    let angle = Double($0) * 2 * .pi / Double(levels.count) - .pi / 2
                    return CGPoint(x: cos(angle), y: sin(angle))
                }
            }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let extent = max(3, min(rect.width, rect.height) * 0.46)
            let base = extent * (style == .orbit ? 0.43 : 0.49)
            let colorRect = CGRect(x: center.x - extent, y: center.y - extent, width: 2 * extent, height: 2 * extent)
            for i in levels.indices {
                let direction = radial[i]
                let r = base + 1.5 + (extent - base - 1.5) * CGFloat(levels[i])
                let start = CGPoint(x: center.x + base * direction.x, y: center.y + base * direction.y)
                let end = CGPoint(x: center.x + r * direction.x, y: center.y + r * direction.y)
                if style == .orbit {
                    shape.move(to: start)
                    shape.addLine(to: end)
                } else if i == 0 {
                    shape.move(to: end)
                } else {
                    shape.addLine(to: end)
                }
            }
            if style == .halo { shape.closeSubpath() }
            accents.addEllipse(in: CGRect(x: center.x - base, y: center.y - base, width: base * 2, height: base * 2))
            paint(accents.copy(strokingWithWidth: 0.9, lineCap: .round, lineJoin: .round, miterLimit: 2),
                  in: context, rect: colorRect, vertical: vertical, alpha: 0.28)
            paint(shape.copy(strokingWithWidth: max(1.1, min(3.2, extent / 27)),
                             lineCap: .round, lineJoin: .round, miterLimit: 2),
                  in: context, rect: colorRect, vertical: vertical)
        }
    }

    /// 给填充波形的四个端角留出弧线。低电平时压低弧线高度，避免两个角挤在一起。
    private func filledWave(_ path: CGMutablePath, levels: [Float], rect: CGRect, amplitude: CGFloat,
                            radius: CGFloat, smooth: Bool) -> CGPath {
        let base = rect.minY
        let left = rect.minX
        let right = rect.maxX
        let span = min(radius, rect.width / 4)
        let first = waveHeight(levels[0], amplitude: amplitude)
        let last = waveHeight(levels[levels.count - 1], amplitude: amplitude)
        let leftRise = min(span, first / 2)
        let rightRise = min(span, last / 2)
        if span > 0 {
            path.move(to: CGPoint(x: left, y: base + first - leftRise))
            path.addQuadCurve(to: CGPoint(x: left + span, y: base + first),
                              control: CGPoint(x: left, y: base + first))
        }
        trace(path, levels: levels, rect: rect.insetBy(dx: span, dy: 0),
              baseline: base, amplitude: amplitude, smooth: smooth)
        if span > 0 {
            path.addQuadCurve(to: CGPoint(x: right, y: base + last - rightRise),
                              control: CGPoint(x: right, y: base + last))
        }
        let line = path.copy(strokingWithWidth: 1.4, lineCap: .round, lineJoin: .round, miterLimit: 2)
        path.addLine(to: CGPoint(x: right, y: base + rightRise))
        path.addQuadCurve(to: CGPoint(x: right - span, y: base), control: CGPoint(x: right, y: base))
        path.addLine(to: CGPoint(x: left + span, y: base))
        path.addQuadCurve(to: CGPoint(x: left, y: base + leftRise), control: CGPoint(x: left, y: base))
        path.closeSubpath()
        return line
    }

    private func waveHeight(_ level: Float, amplitude: CGFloat) -> CGFloat {
        (0.014 + 0.97 * CGFloat(level)) * amplitude
    }

    /// 按对数频带生成连续曲线；三次插值保持相邻区段的切线连续。
    private func trace(_ path: CGMutablePath, levels: [Float], rect: CGRect, baseline: CGFloat,
                       amplitude: CGFloat, smooth: Bool) {
        guard levels.count > 1 else { return }
        let dx = rect.width / CGFloat(levels.count - 1)
        let y: (Int) -> CGFloat = { i in baseline + self.waveHeight(levels[i], amplitude: amplitude) }
        let rounded = !path.isEmpty
        if !rounded { path.move(to: CGPoint(x: rect.minX, y: y(0))) }
        for i in 1..<levels.count {
            let x = rect.minX + CGFloat(i) * dx
            let current = y(i), previous = y(i - 1)
            if smooth {
                let a = y(max(0, i - 2)), b = y(min(levels.count - 1, i + 1))
                let fromY = rounded && i == 1 ? previous : previous + (current - a) / 6
                let toY = rounded && i == levels.count - 1 ? current : current - (b - previous) / 6
                path.addCurve(to: CGPoint(x: x, y: current),
                              control1: CGPoint(x: x - dx * 2 / 3, y: fromY),
                              control2: CGPoint(x: x - dx / 3, y: toY))
            } else {
                path.addLine(to: CGPoint(x: x, y: current))
            }
        }
    }
}
