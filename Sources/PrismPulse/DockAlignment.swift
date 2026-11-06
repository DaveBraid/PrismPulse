import AppKit
import CoreGraphics
import Darwin

/// 读取底部 Dock 的真实边界，并转换成 NSWindow 使用的屏幕坐标。
@MainActor
enum DockAlignment {
    struct Anchor {
        let bounds: CGRect
        let display: CGRect
        let ceiling: CGFloat

        /// 浮窗贴住 Dock 上沿，左右避开 Dock 圆角并保留少量余量。
        func windowFrame(height: CGFloat) -> CGRect {
            // Dock 只提供外框。用高度的四分之一估算圆角，再多留 6 pt。
            let inset = min(ceil(bounds.height / 4) + 6, floor(bounds.width * 0.2))
            return CGRect(x: bounds.minX + inset, y: bounds.maxY, width: bounds.width - 2 * inset,
                          height: min(height, ceiling - bounds.maxY))
        }
    }

    enum Reading {
        case bottom(Anchor)
        case otherEdge
        case unavailable
    }

    private typealias DockRectReader = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void
    private static let readSystemBounds: DockRectReader? = {
        // 新版 macOS 的窗口列表可能只暴露全屏 Dock 容器；按需解析只读的布局接口。
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let framework = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let symbol = dlsym(framework, "CoreDockGetRect") else {
            dlclose(framework)
            return nil
        }
        return unsafeBitCast(symbol, to: DockRectReader.self) // 系统框架在进程生命周期内保持加载。
    }()

    /// 优先读取实际布局。系统接口缺失时，仅接受窗口列表里可识别的 Dock 条。
    static func read() -> Reading {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return .unavailable }
        if let readSystemBounds {
            var raw = CGRect.zero
            readSystemBounds(&raw)
            return classify(raw, screens: screens, originY: primary.frame.maxY)
        }

        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return .unavailable }

        let dockLevel = CGWindowLevelForKey(.dockWindow)
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int32) == dockLevel,
                  let data = window[kCGWindowBounds as String] as? NSDictionary,
                  let raw = CGRect(dictionaryRepresentation: data as CFDictionary)
            else { continue }
            let reading = classify(raw, screens: screens, originY: primary.frame.maxY)
            if case .unavailable = reading { continue }
            return reading
        }
        return .unavailable
    }

    /// 过滤隐藏状态和全屏容器，只把底边的水平 Dock 用作浮窗锚点。
    private static func classify(_ raw: CGRect, screens: [NSScreen], originY: CGFloat) -> Reading {
        guard [raw.minX, raw.minY, raw.width, raw.height].allSatisfy(\.isFinite),
              raw.width >= 12, raw.height >= 12 else { return .unavailable }
        let rect = CGRect(x: raw.minX, y: originY - raw.maxY, width: raw.width, height: raw.height)

        for screen in screens {
            let frame = screen.frame
            let intersection = rect.intersection(frame)
            guard !intersection.isNull else { continue }
            if abs(rect.minY - frame.minY) <= 12,
               rect.width >= rect.height * 1.25,
               rect.height < frame.height * 0.3,
               intersection.width >= rect.width - 1,
               rect.maxY + 48 <= screen.visibleFrame.maxY {
                return .bottom(Anchor(bounds: rect, display: frame, ceiling: screen.visibleFrame.maxY))
            }
            if rect.height > rect.width,
               rect.width < frame.width * 0.3,
               abs(rect.minX - frame.minX) <= 12 || abs(rect.maxX - frame.maxX) <= 12 {
                return .otherEdge
            }
        }
        return .unavailable
    }
}
