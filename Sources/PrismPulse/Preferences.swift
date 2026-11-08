import AppKit
import SpectrumCore

enum Placement: String, Codable, CaseIterable, Identifiable {
    case window = "悬浮窗", menu = "菜单栏", both = "同时显示"
    var id: Self { self }
    var showsWindow: Bool { self != .menu }
    var showsMenu: Bool { self != .window }
}

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case artwork = "封面取色", solid = "单色", gradient = "自定渐变"
    var id: Self { self }
}

enum FullscreenBehavior: String, Codable, CaseIterable, Identifiable {
    case unchanged = "保持原样", hide = "淡出隐藏", edge = "贴边显示"
    var id: Self { self }
}

enum ScreenEdge: String, Codable, CaseIterable, Identifiable {
    case top = "上", bottom = "下", left = "左", right = "右"
    var id: Self { self }
    var isVertical: Bool { self == .left || self == .right }

    /// 沿所选屏幕边缘居中，尺寸限制在该屏幕内。
    func windowFrame(size: CGSize, in screen: CGRect, lengthFraction: Double = 1) -> CGRect {
        // 所有方向都以屏宽为缩放基准，纵向长度不超过屏高。
        let length = floor(min(screen.width * min(1, max(0.1, lengthFraction)),
                               isVertical ? screen.height : screen.width))
        let width = isVertical ? min(size.height, screen.width) : length
        let height = isVertical ? length : min(size.height, screen.height)
        // 与 AppKit 的窗口整点对齐规则一致，避免居中产生半点偏差。
        var frame = CGRect(x: floor(screen.midX - width / 2), y: floor(screen.midY - height / 2), width: width, height: height)
        switch self {
        case .top: frame.origin.y = screen.maxY - height
        case .bottom: frame.origin.y = screen.minY
        case .left: frame.origin.x = screen.minX
        case .right: frame.origin.x = screen.maxX - width
        }
        return frame
    }
}

enum Preset: String, Codable, CaseIterable, Identifiable {
    case aurora = "北极光", dusk = "落日", amber = "琥珀", lagoon = "薄荷海", silver = "月光"
    var id: Self { self }
    var palette: SpectrumPalette {
        switch self {
        case .aurora: .aurora
        case .dusk: .dusk
        case .amber: .amber
        case .lagoon: .lagoon
        case .silver: .silver
        }
    }
}

enum SpectrumStyle: String, Codable, CaseIterable, Identifiable {
    case prism = "流光柱", reeds = "细弦", mirror = "镜像柱", segments = "方格电平"
    case beads = "珠链", peaks = "峰值柱", comet = "星点", wave = "涌浪"
    case silk = "丝线", double = "双弦", ridge = "山脊", ribbons = "叠流"
    case orbit = "日冕", halo = "星环"
    var id: Self { self }
}

struct StatusBarPreferences: Codable, Equatable {
    static let minimumWidth = 40.0
    static let maximumWidth = 3_200.0 // 手动档范围，实际宽度以当前菜单栏布局为准。
    var backgroundOpacity = 0.90      // 只影响底板，0 时保留频谱柱。
    static let widthDefault = 65.0
    var width = Self.widthDefault
    var fillsSpace = false
}

struct Preferences: Codable, Equatable {
    static let maximumCornerRadius = 40.0
    static let fixedFrameRates = [20, 30, 60]
    static let defaultFPS = 30
    static let screenFPS = 0 // 保留整数设置格式，用 0 表示跟随屏幕。
    var placement = Placement.window
    var style = SpectrumStyle.prism
    var colorMode = ColorMode.artwork
    var fallback = Preset.aurora
    var firstColor = RGB(hex: 0x51E3CE)
    var lastColor = RGB(hex: 0xC37DFF)
    var vertical = false
    var onTop = true
    var clickThrough = false
    var backdrop = true
    var opacity = 0.92
    var fps = Self.defaultFPS
    var capture = true

    // 可选字段让旧版本保存的颜色、位置等设置仍可完整解码。
    private var savedStatusBar: StatusBarPreferences?
    private var savedFollowDock: Bool?
    private var savedHideWhenSilent: Bool?
    private var savedCornerRadius: Double?
    private var savedFullscreenBehavior: FullscreenBehavior?
    private var savedFullscreenEdge: ScreenEdge?
    private var savedFullscreenLength: Double?
    var fullscreenLength: Double {
        get { min(1, max(0.1, savedFullscreenLength ?? 1)) }
        set { savedFullscreenLength = newValue.isFinite ? min(1, max(0.1, newValue)) : 1 }
    }
    var fullscreenBehavior: FullscreenBehavior {
        get { savedFullscreenBehavior ?? .unchanged }
        set { savedFullscreenBehavior = newValue }
    }
    var fullscreenEdge: ScreenEdge {
        get { savedFullscreenEdge ?? .bottom }
        set { savedFullscreenEdge = newValue }
    }
    var cornerRadius: Double {
        get { min(Self.maximumCornerRadius, max(0, savedCornerRadius ?? 12)) }
        set { savedCornerRadius = newValue }
    }
    var dockHeight: Double?  // 留空时使用手动浮窗的高度。
    var followsDock: Bool {
        get { savedFollowDock ?? false }
        set { savedFollowDock = newValue }
    }
    var hidesWhenSilent: Bool {
        get { savedHideWhenSilent ?? true }
        set { savedHideWhenSilent = newValue }
    }
    var statusBar: StatusBarPreferences {
        get { savedStatusBar ?? StatusBarPreferences() }
        set { savedStatusBar = newValue }
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "prism.preferences"),
              var settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        settings.opacity = min(1, max(0.12, settings.opacity))
        if settings.fps != screenFPS && !fixedFrameRates.contains(settings.fps) {
            settings.fps = defaultFPS
        }
        if let height = settings.dockHeight { settings.dockHeight = min(680, max(48, height)) }
        if var statusBar = settings.savedStatusBar {
            statusBar.width = min(StatusBarPreferences.maximumWidth, max(StatusBarPreferences.minimumWidth, statusBar.width))
            statusBar.backgroundOpacity = min(1, max(0, statusBar.backgroundOpacity))
            settings.savedStatusBar = statusBar
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "prism.preferences") }
    }

    func palette(artwork: SpectrumPalette?) -> SpectrumPalette {
        switch colorMode {
        case .artwork: artwork ?? fallback.palette
        case .solid: SpectrumPalette([firstColor])
        case .gradient: SpectrumPalette([firstColor, lastColor])
        }
    }
}
