import AppKit
import SpectrumCore

final class SpectrumCanvas: NSView {
    enum Surface { case window, status, preview }
    private static let panelInk = CGColor(srgbRed: 0.046, green: 0.061, blue: 0.094, alpha: 0.88)
    private static let panelEdge = CGColor(srgbRed: 0.68, green: 0.78, blue: 0.96, alpha: 0.23)
    private static let menuInk = CGColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1)
    private let painter = SpectrumPainter()
    private let frameData: SpectrumFrame
    private let surface: Surface
    private var prefs = Preferences()
    private var resizeStart: (CGRect, CGPoint)?
    var attachedToDock = false {
        didSet {
            guard oldValue != attachedToDock else { return }
            resizeStart = nil
            needsDisplay = true
        }
    }

    init(frameData: SpectrumFrame, surface: Surface) {
        self.frameData = frameData
        self.surface = surface
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(surface == .window)
        setAccessibilityRole(.image)
        setAccessibilityLabel("实时音频频谱")
    }

    required init?(coder: NSCoder) { nil }

    /// 输入显示设置与当前有效调色板，刷新画布。
    func apply(_ prefs: Preferences, palette: SpectrumPalette) {
        self.prefs = prefs
        painter.setPalette(palette)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let compact = surface == .status
        let paddingX: CGFloat = compact ? 7 : min(23, bounds.width * 0.075)
        let paddingY: CGFloat = compact ? 6 : min(17, bounds.height * 0.17)
        // 透明的 Dock 频谱从贴边处起画，让波形底边紧邻 Dock 上沿。
        let plot = attachedToDock && !prefs.backdrop
            ? CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - paddingY)
            : bounds.insetBy(dx: paddingX, dy: paddingY)
        let radius = compact ? 0 : min(prefs.cornerRadius, min(bounds.width, bounds.height) / 2)
        // 透明的面积波形按自身轮廓收圆。其他浮窗内容沿四角裁切。
        let clipsWindow = radius > 0 && (prefs.backdrop || (prefs.style != .wave && prefs.style != .ridge))
        if clipsWindow {
            context.saveGState()
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        }
        defer { if clipsWindow { context.restoreGState() } }
        if compact ? prefs.statusBar.backgroundOpacity > 0 : prefs.backdrop {
            let box = compact ? bounds.insetBy(dx: 2, dy: 2.5) : bounds.insetBy(dx: 0.6, dy: 0.6)
            guard box.width > 0, box.height > 0 else { return }
            let edgeRadius = compact ? box.height / 2 : min(radius, min(box.width, box.height) / 2)
            let background = CGPath(roundedRect: box, cornerWidth: edgeRadius, cornerHeight: edgeRadius, transform: nil)
            context.setFillColor(compact ? Self.menuInk : Self.panelInk)
            if compact { context.setAlpha(prefs.statusBar.backgroundOpacity) }
            context.addPath(background)
            context.fillPath()
            if compact { context.setAlpha(1) }
            if !compact {
                context.setLineWidth(1)
                context.setStrokeColor(Self.panelEdge)
                context.addPath(background)
                context.strokePath()
            }
        }
        painter.draw(frameData, in: context, rect: plot, style: prefs.style,
                     vertical: prefs.vertical, compact: compact, cornerRadius: radius)
        if surface == .window && !attachedToDock && !prefs.clickThrough && prefs.backdrop {
            context.setStrokeColor(Self.panelEdge)
            context.setLineWidth(1)
            context.setLineCap(.round)
            for length: CGFloat in [3, 6, 9] {
                context.move(to: CGPoint(x: bounds.maxX - 6 - length, y: 6))
                context.addLine(to: CGPoint(x: bounds.maxX - 6, y: 6 + length))
            }
            context.strokePath()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { surface == .status ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { surface == .window }

    /// 鼠标按下：右下角开始缩放，其余区域拖动整块浮窗。
    override func mouseDown(with event: NSEvent) {
        guard surface == .window, !attachedToDock, let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.x >= bounds.maxX - 25 && p.y <= 24 {
            resizeStart = (window.frame, NSEvent.mouseLocation)
        } else {
            window.performDrag(with: event)
        }
    }

    /// 以左上角为锚点计算新尺寸，并限制在适合频谱的范围。
    override func mouseDragged(with event: NSEvent) {
        guard let (initial, start) = resizeStart, let window else { return }
        let p = NSEvent.mouseLocation
        let width = max(window.minSize.width, min(window.maxSize.width, initial.width + p.x - start.x))
        let height = max(window.minSize.height, min(window.maxSize.height, initial.height + start.y - p.y))
        window.setFrame(CGRect(x: initial.minX, y: initial.maxY - height, width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) { resizeStart = nil }
}
