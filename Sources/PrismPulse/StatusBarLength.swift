import AppKit

@MainActor
final class StatusBarLength {
    private struct Layout {
        let screen: NSRect
        let item: NSRect
        let buttonWidth: CGFloat
        let leadingLimit: CGFloat
        let visible: Bool

        var trailing: CGFloat { item.maxX - screen.minX }
    }

    private let item: NSStatusItem
    private let didFit: (Int) -> Void
    private var request: Int? // nil 表示自适应铺满。
    private var enabled = false
    private var fitting: Task<Void, Never>?
    private var anchor: Layout?
    private var settled = Int(StatusBarPreferences.widthDefault)
    private var trackingMenu = false
    private static let minimum = Int(StatusBarPreferences.minimumWidth)

    init(item: NSStatusItem, didFit: @escaping (Int) -> Void) {
        self.item = item
        self.didFit = didFit
    }

    /// 切换图标、手动长度和自适应长度。手动值也是申请上限，由系统布局约束。
    func configure(enabled: Bool, preferences: StatusBarPreferences) {
        let requested = preferences.fillsSpace ? nil : Int(preferences.width.rounded())
        guard enabled != self.enabled || requested != request else { return }
        self.enabled = enabled
        request = requested
        if enabled {
            if item.length <= 0 { item.length = CGFloat(settled) }
            refresh()
        } else {
            fitting?.cancel()
            fitting = nil
            anchor = nil
            item.length = NSStatusItem.squareLength
        }
    }

    /// 状态菜单展开时保持位置，结束跟踪后再校准可用宽度。
    func menuTracking(_ tracking: Bool) {
        trackingMenu = tracking
        if tracking, fitting != nil {
            fitting?.cancel()
            fitting = nil
            item.length = CGFloat(settled)
        } else if !tracking {
            layoutChanged()
        }
    }

    /// 在切换屏幕、空间或应用菜单时重新测量，动画定时器不参与布局。
    func refresh() {
        guard enabled, !trackingMenu else { return }
        fitting?.cancel()
        fitting = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(125))
                guard let self, !Task.isCancelled else { return }
                try await self.fit()
                self.fitting = nil
            } catch {}
        }
    }

    /// 外部布局变化可能改了右侧图标宽度或状态项所在显示器。
    func layoutChanged() {
        guard fitting == nil, let live = layout() else { return }
        guard let anchor else {
            if live.visible { refresh() }
            return
        }
        if live.screen != anchor.screen || abs(live.trailing - anchor.trailing) > 1 || !live.visible {
            refresh()
        }
    }

    func stop() { fitting?.cancel(); fitting = nil }

    /// 小尺寸的右边缘为锚点。二分查找仍落在原生可见区域的最大整数点长度。
    private func fit() async throws {
        let original = settled
        let current = layout()
        let reference: Layout
        if let anchor, let current, current.screen == anchor.screen, accepts(current, reference: anchor) {
            reference = anchor
        } else {
            guard let baseline = try await measure(Self.minimum), baseline.visible else {
                finish(Self.minimum, anchor: nil)
                return
            }
            reference = baseline
        }

        let windowPadding = max(0, reference.item.width - reference.buttonWidth)
        let physicalLimit = max(Self.minimum, Int(floor(reference.item.maxX - reference.leadingLimit - windowPadding)))
        var high = min(request ?? physicalLimit, physicalLimit)
        if let limit = request, limit <= original, let live = layout(), accepts(live, reference: reference) {
            let width = min(high, limit)
            if let proposed = try await measure(width), accepts(proposed, reference: reference) {
                finish(width, anchor: reference)
                return
            }
            high = width - 1
        }

        var low = Self.minimum
        if Int(item.length) <= high, let live = layout(), accepts(live, reference: reference) {
            low = max(low, Int(item.length))
        }
        if request == nil, low > Self.minimum, low < high {
            // 相邻一格也放不下时立即恢复，减少切换前台应用时的伸缩。
            if let next = try await measure(low + 1), accepts(next, reference: reference) {
                low += 1
            } else {
                finish(low, anchor: reference)
                return
            }
        } else if high > low {
            if let largest = try await measure(high), accepts(largest, reference: reference) {
                finish(high, anchor: reference)
                return
            }
            high -= 1
        }
        while high > low {
            let mid = low + (high - low + 1) / 2
            if let measured = try await measure(mid), accepts(measured, reference: reference) {
                low = mid
            } else {
                high = mid - 1
            }
        }
        finish(low, anchor: reference)
    }

    /// 让 WindowServer 完成菜单栏布局后，读取按钮真实窗口几何。
    private func measure(_ width: Int) async throws -> Layout? {
        try Task.checkCancellation()
        if item.length != CGFloat(width) {
            item.length = CGFloat(width)
            try await Task.sleep(for: .milliseconds(85))
        }
        return layout()
    }

    private func layout() -> Layout? {
        guard let button = item.button, let window = button.window, let screen = window.screen else { return nil }
        let rect = window.frame
        // 有刘海时右侧状态项只能延伸到刘海右边缘。
        let right = screen.auxiliaryTopRightArea
        let leading = right.map { rect.maxX > $0.minX ? $0.minX : screen.frame.minX } ?? screen.frame.minX
        return Layout(screen: screen.frame, item: rect, buttonWidth: button.bounds.width, leadingLimit: leading,
                      visible: window.isVisible && window.occlusionState.contains(.visible))
    }

    private func accepts(_ layout: Layout, reference: Layout) -> Bool {
        // 宽度过大时 macOS 27 可能仍报告 isVisible，但会把右边缘移走或隐藏窗口。
        layout.visible && layout.screen == reference.screen &&
        abs(layout.trailing - reference.trailing) <= 1 && layout.item.minX >= reference.leadingLimit - 1
    }

    private func finish(_ width: Int, anchor: Layout?) {
        item.length = CGFloat(width)
        self.anchor = anchor
        settled = width
        didFit(width)
    }
}
