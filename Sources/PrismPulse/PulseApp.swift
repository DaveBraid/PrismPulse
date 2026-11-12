import AppKit
import QuartzCore
import SpectrumCore
import SwiftUI

@MainActor
final class PulseAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, ObservableObject {
    @Published var prefs: Preferences {
        didSet {
            guard oldValue != prefs, overlay != nil else { return }
            if persists { prefs.save() }
            let positionChanged = oldValue.desktopPosition != prefs.desktopPosition
            if positionChanged {
                if !prefs.followsDock { dockAnchor = nil }
                refreshFullscreenContext()
            }
            updateOverlayPlacement()
            if positionChanged || oldValue.placement != prefs.placement ||
               oldValue.fullscreenBehavior != prefs.fullscreenBehavior {
                updateDockTracking()
            }
            applyAppearance()
            if oldValue.capture != prefs.capture { restartAudio() }
            if oldValue.colorMode != prefs.colorMode || oldValue.capture != prefs.capture { updateArtworkMonitor() }
            if oldValue.fps != prefs.fps || oldValue.placement != prefs.placement ||
               oldValue.hidesWhenSilent != prefs.hidesWhenSilent { tuneClock() }
        }
    }
    @Published private(set) var audioNote = "正在准备系统音频"
    @Published private(set) var actualMenuWidth = Int(StatusBarPreferences.widthDefault)
    @Published private(set) var artwork = ArtworkUpdate.waiting
    @Published private(set) var palette: SpectrumPalette
    @Published var demo: Bool {
        didSet {
            guard demo != oldValue, overlay != nil else { return }
            restartAudio()
            updateArtworkMonitor()
        }
    }

    private let analyzer = SpectrumAnalyzer()
    private let capture = AudioCapture()
    private let persists: Bool
    private let smoke: Bool
    private let smokeDirectory: String?
    private var pcm: PCMBuffer?
    private var captureRevision = 0
    private static let freeWindowMinimum = CGSize(width: 150, height: 48)
    private static let freeWindowMaximum = CGSize(width: 1400, height: 680)
    private var overlay: SpectrumPanel!
    private var plot: SpectrumCanvas!
    private var freeWindowFrame = CGRect.zero
    private var dockAnchor: DockAlignment.Anchor?
    private var dockTimer: Timer?
    private var fullscreenScreen: NSScreen?
    private var applyingOverlayFrame = false
    private var presentationObserver: NSKeyValueObservation?
    private var fullscreenRefresh: DispatchWorkItem?
    private var statusItem: NSStatusItem!
    private var menuPlot: SpectrumCanvas!
    private var menuLength: StatusBarLength!
    private var settings: NSWindow?
    private var clock: Timer?
    private var displayClock: CADisplayLink?
    private weak var displayClockWindow: NSWindow?
    private var clockRate = 0
    private var lastTick = 0.0
    private var lastMenuPaint = 0.0
    private var lastAudible = -100.0
    private static let silenceDelay = 1.4 // 低于音频阈值持续这些秒后才淡出。
    private var overlayWantsToShow = false
    private var overlayFade = 0.0         // 0…1，实际不透明度还要乘上用户设置。
    private var paletteFrom: SpectrumPalette?
    private var paletteTarget: SpectrumPalette
    private var paletteStarted = 0.0
    private static let paletteDuration = 0.65 // 秒，封面配色切换的缓动时间。
    private var routeRestart: DispatchWorkItem?
    private var frameSave: DispatchWorkItem?
    private var quitReplied = false
    private var quitting = false
    lazy var updates = AppUpdates(enabled: persists)
    private lazy var artMonitor = ArtworkMonitor { [weak self] update in
        guard let self, self.artwork != update else { return }
        self.artwork = update
        self.applyPalette()
    }

    init(demo: Bool = false, smoke: Bool = false, smokeDirectory: String? = nil) {
        self.demo = demo || smoke
        self.smoke = smoke
        self.smokeDirectory = smokeDirectory
        persists = !demo && !smoke
        let initial = persists ? Preferences.load() : Preferences()
        prefs = initial
        palette = initial.palette(artwork: nil)
        paletteTarget = initial.palette(artwork: nil)
        super.init()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// 创建窗口、菜单栏入口和音频监控；演示模式完全使用合成数据。
    func applicationDidFinishLaunching(_ notification: Notification) {
        makeSurfaces()
        updateOverlayPlacement()
        applyAppearance()
        restartAudio()
        updateArtworkMonitor()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(outputChanged), name: NSWorkspace.didWakeNotification, object: nil)
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(menuLayoutContextChanged), name: name, object: nil)
        }
        let events = NotificationCenter.default
        events.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
            events.addObserver(self, selector: #selector(surfaceWindowChanged(_:)), name: name, object: nil)
        }
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshFullscreenContext() }
        }
        refreshFullscreenContext()
        if persists { _ = updates }
        if persists {
            capture.watchOutput { [weak self] in self?.outputChanged() }
        }
        if smoke {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.checkSurfaces()
            }
        } else if !persists {
            showSettings()
        }
    }

    /// 初始化无焦点浮窗及原生菜单栏按钮，两处读取同一份频谱帧。
    private func makeSurfaces() {
        freeWindowFrame = Self.initialFrame(saved: persists)
        overlay = SpectrumPanel(contentRect: freeWindowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.minSize = Self.freeWindowMinimum
        overlay.maxSize = Self.freeWindowMaximum
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = true
        overlay.hidesOnDeactivate = false
        overlay.isReleasedWhenClosed = false
        overlay.delegate = self
        overlay.title = "流光频谱"
        plot = SpectrumCanvas(frameData: analyzer.frame, surface: .window)
        overlay.contentView = plot

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if persists { statusItem.autosaveName = "PrismPulse" }
        menuLength = StatusBarLength(item: statusItem) { [weak self] width in
            if let self, actualMenuWidth != width { actualMenuWidth = width }
        }
        if let button = statusItem.button {
            button.setAccessibilityLabel("流光频谱菜单")
            button.toolTip = "流光频谱 · PrismPulse"
            menuPlot = SpectrumCanvas(frameData: analyzer.frame, surface: .status)
            menuPlot.frame = button.bounds
            button.addSubview(menuPlot)
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// 恢复上次位置；显示器变更后将浮窗放回可用屏幕。
    private static func initialFrame(saved: Bool) -> CGRect {
        if saved, let text = UserDefaults.standard.string(forKey: "prism.window") {
            let rect = NSRectFromString(text)
            if (150...1400).contains(rect.width), (48...680).contains(rect.height),
               NSScreen.screens.contains(where: { $0.visibleFrame.contains(rect) }) { return rect }
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(474, screen.width - 48)
        return CGRect(x: screen.maxX - width - 26, y: screen.minY + 28, width: width, height: 124)
    }

    /// 应用交互和外观设置；只在显示模式实际切换时重新排序窗口。
    private func applyAppearance() {
        let floats = prefs.onTop || fullscreenEdgeScreen != nil
        overlay.level = floats ? .floating : .normal
        overlay.collectionBehavior = floats ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace]
        overlay.hasShadow = prefs.backdrop && !plot.pinnedToScreenEdge
        updateOverlayVisibility(now: ProcessInfo.processInfo.systemUptime)
        if let button = statusItem.button, let menuPlot {
            menuPlot.isHidden = !prefs.placement.showsMenu
            menuLength.configure(enabled: prefs.placement.showsMenu, preferences: prefs.statusBar)
            button.image = prefs.placement.showsMenu ? nil :
                NSImage(systemSymbolName: "waveform", accessibilityDescription: "流光频谱")
            menuPlot.frame = button.bounds
        }
        applyPalette()
    }

    @objc private func menuLayoutContextChanged() {
        menuLength.refresh()
        refreshFullscreenContext()
        // Space 通知可能早于切屏动画结束，合并事件后再确认一次。
        fullscreenRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFullscreenContext() }
        fullscreenRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private var layoutScreen: NSScreen? {
        // 自动布局始终以桌面位置确定显示器，避免把临时贴边位置作为下一次的锚点。
        let anchor = (prefs.followsDock ? dockAnchor?.display : nil) ?? freeWindowFrame
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? overlay.screen ?? NSScreen.main
    }

    private var fullscreenEdgeScreen: NSScreen? {
        prefs.placement.showsWindow && prefs.fullscreenBehavior == .edge ? fullscreenScreen : nil
    }

    /// 显示器的全屏空间改变时更新浮窗，不在绘图循环里轮询。
    private func refreshFullscreenContext() {
        // 界面自检注入全屏状态，避免真实 Space 通知覆盖测试过程。
        guard !quitting, !smoke else { return }
        let screen = layoutScreen.flatMap { FullscreenContext.isFullscreen(on: $0) ? $0 : nil }
        updateFullscreenContext(screen)
    }

    /// 同步全屏策略；桌面贴边同时刷新菜单栏和 Dock 占用后的可用区域。
    private func updateFullscreenContext(_ screen: NSScreen?) {
        let changed = screen?.frame != fullscreenScreen?.frame
        fullscreenScreen = screen
        if changed || prefs.desktopPosition == .edge { updateOverlayPlacement() }
        guard changed else { return }
        applyAppearance()
        updateDockTracking()
        tuneClock()
    }

    private var positionedHeight: CGFloat {
        switch prefs.desktopPosition {
        case .free: freeWindowFrame.height
        case .dock: prefs.dockHeight ?? freeWindowFrame.height
        case .edge: prefs.desktopEdgeThickness ?? freeWindowFrame.height
        }
    }

    /// 将桌面位置和全屏策略解析成窗口边框；自动布局共享同一份自由位置。
    private func updateOverlayPlacement() {
        let fullscreen = fullscreenEdgeScreen
        let screen = fullscreen ?? (prefs.placement.showsWindow && prefs.desktopPosition == .edge ? layoutScreen : nil)
        let dock = screen == nil && prefs.followsDock ? dockAnchor : nil
        let wasAnchored = plot.pinnedToScreenEdge || plot.attachedToDock
        let edge: ScreenEdge?
        let frame: CGRect
        if let screen {
            let direction = fullscreen == nil ? prefs.desktopEdge : prefs.fullscreenEdge
            let length = fullscreen == nil ? prefs.desktopLength : prefs.fullscreenLength
            let size = CGSize(width: freeWindowFrame.width, height: positionedHeight)
            frame = direction.windowFrame(size: size, in: screen.frame, lengthFraction: length,
                                          within: fullscreen == nil ? screen.visibleFrame : nil)
            edge = direction
        } else if let dock {
            frame = dock.windowFrame(height: positionedHeight)
            edge = nil
        } else {
            guard wasAnchored else { return }
            if !NSScreen.screens.contains(where: { $0.frame.intersects(freeWindowFrame) }) {
                freeWindowFrame = Self.initialFrame(saved: persists)
            }
            frame = freeWindowFrame
            edge = nil
        }

        overlay.pinsToScreenEdge = edge != nil
        plot.screenEdge = edge
        plot.attachedToDock = dock != nil
        let anchored = edge != nil || dock != nil
        guard overlay.frame != frame || anchored != wasAnchored else { return }
        // 尺寸约束和窗口移动都会触发回调，恢复过程中不记录中间位置。
        applyingOverlayFrame = true
        defer { applyingOverlayFrame = false }
        overlay.minSize = CGSize(width: min(Self.freeWindowMinimum.width, frame.width),
                                 height: min(Self.freeWindowMinimum.height, frame.height))
        overlay.maxSize = CGSize(width: max(Self.freeWindowMaximum.width, frame.width),
                                 height: max(Self.freeWindowMaximum.height, frame.height))
        if overlay.frame != frame { overlay.setFrame(frame, display: overlay.isVisible) }
    }

    /// 屏幕模式或刷新率改变后重读显示配置。
    @objc private func screensChanged() {
        menuLayoutContextChanged()
        tuneClock()
        updateDisplayClockRate()
    }

    /// 菜单栏布局改变时复测长度，显示面跨屏或显隐时同步动画时钟。
    @objc private func surfaceWindowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let isMenuWindow = window === statusItem.button?.window
        if isMenuWindow { menuLength.layoutChanged() }
        if window === overlay, notification.name == NSWindow.didChangeScreenNotification {
            // 等窗口移动及自由位置回调结束，再读最终所在的屏幕。
            DispatchQueue.main.async { [weak self] in self?.refreshFullscreenContext() }
        }
        guard prefs.fps == Preferences.screenFPS, isMenuWindow || window === overlay,
              notification.name != NSWindow.didMoveNotification else { return }
        tuneClock()
        if notification.name == NSWindow.didChangeScreenNotification { updateDisplayClockRate() }
    }

    private func applyPalette() {
        let target = prefs.palette(artwork: artwork.palette)
        if target != paletteTarget {
            if prefs.colorMode == .artwork {
                let now = ProcessInfo.processInfo.systemUptime
                advancePalette(at: now)
                paletteFrom = palette
                paletteStarted = now
            } else {
                paletteFrom = nil
                palette = target
            }
            paletteTarget = target
        }
        plot?.apply(prefs, palette: palette)
        menuPlot?.apply(prefs, palette: palette)
        tuneClock()
    }

    /// 从当前已显示的颜色重新起步，切歌或重复取色不会闪回旧配色。
    @discardableResult
    private func advancePalette(at now: TimeInterval) -> Bool {
        guard let from = paletteFrom else { return false }
        let progress = min(1, max(0, (now - paletteStarted) / Self.paletteDuration))
        let eased = progress * progress * (3 - 2 * progress)
        palette = from.blended(to: paletteTarget, progress: eased,
                               accentPosition: analyzer.frame.accentPosition)
        plot?.setPalette(palette)
        menuPlot?.setPalette(palette)
        if progress >= 1 { paletteFrom = nil }
        return true
    }

    /// 切换实时音频、暂停和演示。修订号防止旧的启动结果覆盖新状态。
    @objc func restartAudio() {
        guard !quitting else { return }
        captureRevision += 1
        let ticket = captureRevision
        pcm = nil
        lastAudible = -100
        analyzer.reset(sampleRate: 48_000)
        plot.needsDisplay = true
        menuPlot?.needsDisplay = true
        let active = prefs.capture && !demo
        audioNote = demo ? "演示动画 · 无需音频权限" : active ? "正在检查系统音频" : "系统音频已暂停"
        updateOverlayVisibility(now: ProcessInfo.processInfo.systemUptime)
        tuneClock()
        capture.setActive(active) { [weak self] result in
            guard let self, ticket == self.captureRevision, active, !self.quitting else { return }
            switch result {
            case let .success(session?):
                self.pcm = session.0
                self.analyzer.reset(sampleRate: session.1)
                self.audioNote = "正在读取系统音频"
                self.tuneClock()
            case let .failure(error):
                self.audioNote = error.localizedDescription
            case .success(nil):
                self.pcm = nil
                self.analyzer.reset(sampleRate: 48_000)
                self.plot.needsDisplay = true
                self.menuPlot?.needsDisplay = true
                self.audioNote = "等待播放 · 采集已暂停"
                self.tuneClock()
            }
        }
    }

    private func heardRecently(at now: TimeInterval) -> Bool {
        now - lastAudible < Self.silenceDelay
    }

    /// 按音频状态推进淡入淡出。未传 elapsed 时只同步设置与窗口状态。
    private func updateOverlayVisibility(now: TimeInterval, elapsed: TimeInterval? = nil) {
        let wasShowing = overlayWantsToShow
        let previousFade = overlayFade
        overlayWantsToShow = prefs.placement.showsWindow &&
            !(fullscreenScreen != nil && prefs.fullscreenBehavior == .hide) &&
            (!prefs.hidesWhenSilent || demo || heardRecently(at: now))

        if !prefs.placement.showsWindow {
            overlayFade = 0
        } else if wasShowing == overlayWantsToShow, let elapsed {
            // 开始或反转时从当前亮度起步，静音时钟的长间隔不会跳过淡入。
            let duration = overlayWantsToShow ? 0.18 : 0.36 // 秒，声音回来时更快淡入。
            let step = elapsed / duration
            overlayFade = overlayWantsToShow ? min(1, overlayFade + step) : max(0, overlayFade - step)
        }

        guard elapsed == nil || wasShowing != overlayWantsToShow || previousFade != overlayFade else { return }
        let eased = overlayFade * overlayFade * (3 - 2 * overlayFade)
        overlay.alphaValue = prefs.opacity * eased
        overlay.ignoresMouseEvents = prefs.clickThrough || !overlayWantsToShow || overlayFade == 0
        let visible = overlayWantsToShow || overlayFade > 0
        if visible != overlay.isVisible {
            if visible { overlay.orderFrontRegardless() }
            else { overlay.orderOut(nil) }
            updateDockTracking()
        }
    }

    /// 切换屏幕同步、固定帧率和 8 Hz 静音检查。两处频谱共用一个时钟。
    private func tuneClock() {
        guard !quitting else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fading = overlayFade != (overlayWantsToShow ? 1 : 0)
        let hasSurface = overlayWantsToShow || overlayFade > 0 || prefs.placement.showsMenu
        let animating = fading || paletteFrom != nil || (hasSurface && (demo || (pcm != nil && heardRecently(at: now))))
        let followsScreen = prefs.fps == Preferences.screenFPS
        if animating, followsScreen, let window = visibleSurfaceWindow() {
            guard displayClockWindow !== window else { return }
            stopClock()
            let link = window.displayLink(target: self, selector: #selector(displayFrame(_:)))
            displayClockWindow = window
            displayClock = link
            updateDisplayClockRate()
            lastTick = now
            link.add(to: .main, forMode: .common)
            return
        }
        // 浮窗淡入前可能还没有可见的显示面，用定时器继续推进过渡。
        let fixedRate = followsScreen ? Preferences.defaultFPS : prefs.fps
        let activeRate = prefs.placement == .menu ? min(fixedRate, 24) : fixedRate
        let rate = animating ? activeRate : (pcm != nil ? 8 : 0)
        guard displayClock != nil || rate != clockRate else { return }
        stopClock()
        clockRate = rate
        guard rate > 0 else { return }
        let interval = 1 / Double(rate)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = min(0.010, interval * 0.18)
        lastTick = now
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// 两处同时显示时以可见悬浮窗为准，菜单栏单独显示时使用按钮所在屏幕。
    private func visibleSurfaceWindow() -> NSWindow? {
        if prefs.placement.showsWindow, overlay.occlusionState.contains(.visible), overlay.screen != nil { return overlay }
        if prefs.placement.showsMenu, let window = statusItem.button?.window,
           window.occlusionState.contains(.visible), window.screen != nil { return window }
        return nil
    }

    /// 将当前显示面的最高刷新率传给 macOS。屏幕同步回调仍受系统调度。
    private func updateDisplayClockRate() {
        guard let displayClock else { return }
        let rate = displayClockWindow?.screen?.maximumFramesPerSecond ?? 0
        guard rate != clockRate else { return }
        clockRate = rate
        let hz = Float(rate)
        displayClock.preferredFrameRateRange = rate > 0
            ? CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz) : .default
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
        displayClock?.invalidate()
        displayClock = nil
        displayClockWindow = nil
        clockRate = 0
    }

    @objc private func displayFrame(_ sender: CADisplayLink) { tick() }

    /// 合并采样、频谱平滑和视图刷新。固定档的菜单栏频谱最多每秒绘制 24 次。
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        var dirty = false
        if demo {
            analyzer.frame.demo(at: now)
            dirty = true
        } else if let pcm {
            let result = analyzer.step(pcm, dt: dt)
            if result.audible { lastAudible = now }
            dirty = result.changed
            if (paletteTarget.accentWidth != nil || paletteFrom?.accentWidth != nil),
               heardRecently(at: now), analyzer.updateAccentPosition(dt: dt) {
                dirty = true
            }
        }
        if advancePalette(at: now) { dirty = true }
        updateOverlayVisibility(now: now, elapsed: dt)
        if dirty && overlay.isVisible { plot.needsDisplay = true }
        if prefs.placement.showsMenu, menuPlot != nil {
            if dirty || menuDirty {
                menuDirty = true
                if displayClock != nil || now - lastMenuPaint >= 1.0 / 24.0 - 0.001 {
                    menuPlot.needsDisplay = true
                    lastMenuPaint = now
                    menuDirty = false
                }
            }
        }
        tuneClock()
    }
    private var menuDirty = false

    private func updateArtworkMonitor() {
        artMonitor.configure(enabled: !demo && prefs.capture && prefs.colorMode == .artwork)
    }

    /// 合并蓝牙或系统唤醒事件，等待新的输出设备完成切换。
    @objc private func outputChanged() {
        guard !quitting, prefs.capture, !demo else { return }
        routeRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartAudio() }
        routeRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 只在贴 Dock 的浮窗显示时跟踪边界，频谱绘图不会触发位置查询。
    private func updateDockTracking() {
        guard fullscreenEdgeScreen == nil, prefs.followsDock, prefs.placement.showsWindow, overlay.isVisible else {
            dockTimer?.invalidate()
            dockTimer = nil
            return
        }
        guard dockTimer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDockAlignment() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        dockTimer = timer
        refreshDockAlignment()
    }

    /// Dock 暂时隐藏时保留上次边界，换到侧边或断开原显示器时恢复自由布局。
    private func refreshDockAlignment() {
        switch DockAlignment.read() {
        case let .bottom(anchor):
            dockAnchor = anchor
        case .otherEdge:
            dockAnchor = nil
        case .unavailable:
            if let dockAnchor, !NSScreen.screens.contains(where: { $0.frame == dockAnchor.display }) {
                self.dockAnchor = nil
            }
        }
        updateOverlayPlacement()
    }

    /// 自动布局只改频谱厚度；自由摆放时调整窗口尺寸并保存位置。
    func resizeWindow(_ size: CGSize) {
        switch prefs.desktopPosition {
        case .dock:
            prefs.dockHeight = Double(size.height)
            return
        case .edge:
            prefs.desktopEdgeThickness = Double(size.height)
            return
        case .free:
            break
        }
        guard let screen = layoutScreen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
        let x = max(bounds.minX, min(bounds.maxX - width, freeWindowFrame.maxX - width))
        let y = max(bounds.minY, min(bounds.maxY - height, freeWindowFrame.minY))
        let frame = CGRect(x: x, y: y, width: width, height: height)
        if plot.pinnedToScreenEdge {
            freeWindowFrame = frame
            updateOverlayPlacement()
            saveFrame()
        } else {
            overlay.setFrame(frame, display: true)
        }
    }

    func windowDidMove(_ notification: Notification) { rememberFreeWindowFrame() }
    func windowDidResize(_ notification: Notification) { rememberFreeWindowFrame() }

    /// 自动贴合产生的移动和缩放不覆盖用户上次摆放的窗口。
    private func rememberFreeWindowFrame() {
        guard !applyingOverlayFrame, !plot.pinnedToScreenEdge, !plot.attachedToDock else { return }
        freeWindowFrame = overlay.frame
        guard persists else { return }
        frameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func saveFrame() {
        if persists { UserDefaults.standard.set(NSStringFromRect(freeWindowFrame), forKey: "prism.window") }
    }

    /// 打开设置。悬浮窗开启点击穿透后，菜单栏仍能关闭它。
    @objc func showSettings() {
        if settings == nil {
            let view = NSHostingController(rootView: SettingsView(model: self))
            let window = NSWindow(contentViewController: view)
            window.styleMask = [.titled, .closable]
            window.title = "流光频谱 · 设置"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            settings = window
        }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc func openAudioPermissions() {
        openPrivacy("Privacy_ScreenCapture")
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// 在每次展开菜单时同步状态，避免动画期间反复改写菜单内容。
    func menuWillOpen(_ menu: NSMenu) { menuLength.menuTracking(true) }
    func menuDidClose(_ menu: NSMenu) { menuLength.menuTracking(false) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let name = NSMenuItem(title: "流光频谱 · PrismPulse", action: nil, keyEquivalent: "")
        name.isEnabled = false
        menu.addItem(name)
        add("设置…", #selector(showSettings), key: ",", to: menu)
        add("检查更新…", #selector(checkForUpdates), to: menu).isEnabled = updates.canCheck
        menu.addItem(.separator())
        for placement in Placement.allCases {
            let item = add(placement.rawValue, #selector(choosePlacement(_:)), to: menu)
            item.representedObject = placement.rawValue
            item.state = prefs.placement == placement ? .on : .off
        }
        menu.addItem(.separator())
        add("跟随 Dock", #selector(toggleFollowDock), state: prefs.followsDock, to: menu).isEnabled = prefs.placement.showsWindow
        add("窗口置顶", #selector(toggleTop), state: prefs.onTop, to: menu)
        add("点击穿透", #selector(toggleClicks), state: prefs.clickThrough, to: menu)
        add("演示动画", #selector(toggleDemo), state: demo, to: menu)
        add(prefs.capture ? "暂停系统音频" : "恢复系统音频", #selector(toggleCapture), to: menu)
        add("重连系统音频", #selector(restartAudio), to: menu).isEnabled = prefs.capture && !demo
        menu.addItem(.separator())
        add("退出流光频谱", #selector(quit), key: "q", to: menu)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "", state: Bool = false, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = state ? .on : .off
        menu.addItem(item)
        return item
    }

    @objc private func choosePlacement(_ item: NSMenuItem) {
        if let value = item.representedObject as? String, let placement = Placement(rawValue: value) { prefs.placement = placement }
    }

    @objc private func toggleFollowDock() { prefs.followsDock.toggle() }
    @objc private func toggleTop() { prefs.onTop.toggle() }
    @objc private func toggleClicks() { prefs.clickThrough.toggle() }
    @objc private func toggleDemo() { demo.toggle() }
    @objc private func toggleCapture() { prefs.capture.toggle() }
    @objc private func checkForUpdates() { updates.check() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitReplied { return .terminateNow }
        if quitting { return .terminateCancel }
        quitting = true
        stopClock()
        presentationObserver?.invalidate()
        fullscreenRefresh?.cancel()
        dockTimer?.invalidate()
        menuLength.stop()
        NotificationCenter.default.removeObserver(self)
        routeRestart?.cancel()
        frameSave?.cancel()
        saveFrame()
        artMonitor.configure(enabled: false)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // 先退出 AppKit 的关闭回调，让主队列能够接收 HAL 的清理结果。
        let reply: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, !self.quitReplied else { return }
            self.quitReplied = true
            sender.terminate(nil)
        }
        capture.shutdown(reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reply)
        return .terminateCancel
    }

    /// 实际启动 AppKit，验证状态栏与浮窗的切换、穿透、透明度和尺寸设置。
    private func checkSurfaces() async {
        guard statusItem.button != nil, overlay.isVisible, overlay.level == .floating, clockRate == 30 else {
            fputs("UI smoke: initial surfaces failed\n", stderr); exit(1)
        }
        prefs.clickThrough = true
        prefs.onTop = false
        prefs.opacity = 0.53
        resizeWindow(CGSize(width: 360, height: 165))
        guard overlay.ignoresMouseEvents, overlay.level == .normal,
              abs(overlay.alphaValue - 0.53) < 0.01, abs(overlay.frame.height - 165) < 1
        else { fputs("UI smoke: window preferences failed\n", stderr); exit(1) }
        await checkDockAlignment()
        checkWaveCorners()
        checkEdgePixels()
        await checkFullscreenBehavior()
        checkDesktopPlacement()
        await checkPaletteFade()
        await checkScreenFrameRate()
        await checkIdleFade()
        prefs.placement = .menu
        guard !overlay.isVisible, !menuPlot.isHidden, statusItem.length == 65, clockRate == 24 else {
            fputs("UI smoke: menu mode failed\n", stderr); exit(1)
        }
        await checkMenuScreenFrameRate()
        prefs.statusBar.width = 120
        prefs.statusBar.backgroundOpacity = 0
        try? await Task.sleep(for: .milliseconds(600))
        guard actualMenuWidth == 120, abs(menuPlot.bounds.width - 120) < 1, menuBackgroundAlpha() < 0.02 else {
            fputs("UI smoke: adjustable width or clear background failed\n", stderr); exit(1)
        }
        prefs.statusBar.backgroundOpacity = 0.5
        guard abs(menuBackgroundAlpha() - 0.5) < 0.04 else {
            fputs("UI smoke: background alpha failed\n", stderr); exit(1)
        }
        prefs.statusBar.fillsSpace = true
        try? await Task.sleep(for: .milliseconds(1_700))
        let fitted = actualMenuWidth
        guard fitted >= 120, statusItem.length == CGFloat(fitted), statusItem.button?.window?.occlusionState.contains(.visible) == true else {
            fputs("UI smoke: menu fit failed (\(fitted) pt)\n", stderr); exit(1)
        }
        prefs.statusBar.fillsSpace = false
        prefs.statusBar.width = Double(fitted + 1)
        try? await Task.sleep(for: .milliseconds(1_700))
        guard actualMenuWidth == fitted else {
            fputs("UI smoke: fit boundary changed (\(fitted) → \(actualMenuWidth) pt)\n", stderr); exit(1)
        }
        print("UI smoke: menu alpha 0% / 50%, manual 120 pt, maximum \(fitted) pt")
        prefs.statusBar.fillsSpace = true
        prefs.placement = .both
        guard overlay.isVisible, !menuPlot.isHidden else { fputs("UI smoke: both mode failed\n", stderr); exit(1) }
        showSettings()
        guard settings?.isVisible == true else { fputs("UI smoke: settings did not open\n", stderr); exit(1) }
        if let directory = smokeDirectory, let content = settings?.contentView {
            for (name, view) in [("settings", content), ("menu", menuPlot!), ("overlay", plot!)] {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        print("UI smoke: overlay, menu, preferences and settings passed")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// 在真实 Dock 边界上验证宽度、上沿与手动布局的恢复。
    private func checkDockAlignment() async {
        guard case let .bottom(anchor) = DockAlignment.read() else {
            print("UI smoke: Dock check skipped (bottom Dock unavailable)")
            return
        }
        let previous = overlay.frame
        prefs.followsDock = true
        let leftInset = overlay.frame.minX - anchor.bounds.minX
        let rightInset = anchor.bounds.maxX - overlay.frame.maxX
        guard plot.attachedToDock, overlay.frame == anchor.windowFrame(height: previous.height),
              leftInset > 0, abs(leftInset - rightInset) < 0.01 else {
            fputs("UI smoke: Dock frame mismatch \(overlay.frame) / \(anchor.bounds)\n", stderr)
            exit(1)
        }
        resizeWindow(CGSize(width: 300, height: 82))
        let expected = anchor.windowFrame(height: 82)
        guard overlay.frame == expected else { fputs("UI smoke: Dock height failed\n", stderr); exit(1) }
        overlay.setFrame(expected.offsetBy(dx: 0, dy: 10), display: true)
        try? await Task.sleep(for: .milliseconds(650))
        guard overlay.frame == expected else { fputs("UI smoke: Dock tracking failed\n", stderr); exit(1) }
        prefs.desktopPosition = .edge
        guard plot.pinnedToScreenEdge, !plot.attachedToDock, dockTimer == nil, freeWindowFrame == previous else {
            fputs("UI smoke: desktop edge did not take over from Dock\n", stderr); exit(1)
        }
        prefs.desktopPosition = .dock
        guard overlay.frame == expected, plot.attachedToDock, dockTimer != nil else {
            fputs("UI smoke: desktop edge did not restore Dock layout\n", stderr); exit(1)
        }
        prefs.followsDock = false
        guard overlay.frame == previous, dockTimer == nil, !plot.attachedToDock else {
            fputs("UI smoke: manual window restoration failed\n", stderr); exit(1)
        }
        print("UI smoke: Dock width \(Int(anchor.bounds.width)) pt, inset \(Int(leftInset)) pt each side; manual frame restored")
    }

    /// 用无底板的波形像素验证四角都变透明，且图形中心保留。
    private func checkWaveCorners() {
        let width = 128, height = 48
        func render(radius: CGFloat) -> NSBitmapImageRep? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: RGB.space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let painter = SpectrumPainter()
            painter.setPalette(.aurora)
            painter.draw(SpectrumFrame(levels: [0.8, 0.8]), in: context,
                         rect: CGRect(x: 0, y: 0, width: width, height: height), style: .wave,
                         vertical: false, compact: false, cornerRadius: radius)
            return context.makeImage().map { NSBitmapImageRep(cgImage: $0) }
        }
        guard let square = render(radius: 0), let rounded = render(radius: 16) else { exit(1) }
        for x in [1, width - 2] {
            let filled = (0..<height).filter { (square.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.4 }
            guard let top = filled.first, let bottom = filled.last, bottom - top > 20,
                  (rounded.colorAt(x: x, y: top + 1)?.alphaComponent ?? 1) < 0.1,
                  (rounded.colorAt(x: x, y: bottom - 1)?.alphaComponent ?? 1) < 0.1,
                  (rounded.colorAt(x: width / 2, y: (top + bottom) / 2)?.alphaComponent ?? 0) > 0.4 else {
                fputs("UI smoke: transparent waveform corners failed\n", stderr)
                exit(1)
            }
        }
        if let directory = smokeDirectory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("wave-corners.png")
            try? rounded.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("UI smoke: four waveform corners rounded with the backdrop off")
    }

    /// 对透明画布逐像素检查四边，覆盖全部样式及旋转后的方向。
    private func checkEdgePixels() {
        let data = SpectrumFrame(levels: [Float](repeating: 0.75, count: SpectrumAnalyzer.bandCount))
        for edge in ScreenEdge.allCases {
            for style in SpectrumStyle.allCases {
                let view = SpectrumCanvas(frameData: data, surface: .window)
                view.screenEdge = edge
                view.frame = CGRect(x: 0, y: 0, width: edge.isVertical ? 48 : 200, height: edge.isVertical ? 200 : 48)
                var settings = Preferences()
                settings.backdrop = false
                settings.style = style
                view.apply(settings, palette: .aurora)
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
                let edgeAlphas = (0..<(edge.isVertical ? height : width)).map { position -> CGFloat in
                    switch edge {
                    case .top: return bitmap.colorAt(x: position, y: 0)?.alphaComponent ?? 0
                    case .bottom: return bitmap.colorAt(x: position, y: height - 1)?.alphaComponent ?? 0
                    case .left: return bitmap.colorAt(x: 0, y: position)?.alphaComponent ?? 0
                    case .right: return bitmap.colorAt(x: width - 1, y: position)?.alphaComponent ?? 0
                    }
                }
                guard (edgeAlphas.max() ?? 0) > 0.03 else {
                    fputs("UI smoke: blank edge pixels for \(edge.rawValue) / \(style.rawValue)\n", stderr); exit(1)
                }
                if style == .wave {
                    guard edgeAlphas.dropFirst(8).dropLast(8).allSatisfy({ $0 > 0.35 }) else {
                        fputs("UI smoke: waveform baseline has a pixel gap\n", stderr); exit(1)
                    }
                    if let directory = smokeDirectory {
                        let path = URL(fileURLWithPath: directory).appendingPathComponent("edge-\(edge.id).png")
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: path)
                    }
                }
            }
        }
        let display = CGRect(x: -1000, y: 200, width: 1000, height: 600)
        for edge in ScreenEdge.allCases {
            let frame = edge.windowFrame(size: CGSize(width: 300, height: 60), in: display, lengthFraction: 0.4)
            guard (edge.isVertical ? frame.height : frame.width) == 400, display.contains(frame) else { exit(1) }
        }
        print("UI smoke: zero-pixel edge gaps, four orientations, 14 styles and screen-width scaling passed")
    }

    /// 检查普通桌面三边定位、旧版 Dock 设置和退出全屏后的桌面布局。
    private func checkDesktopPlacement() {
        guard let screen = layoutScreen else { exit(1) }
        let oldPrefs = prefs
        let free = overlay.frame
        let size = free.size

        guard let defaults = try? JSONEncoder().encode(Preferences()),
              var legacy = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any] else { exit(1) }
        legacy["savedFollowDock"] = true
        guard let data = try? JSONSerialization.data(withJSONObject: legacy),
              let migrated = try? JSONDecoder().decode(Preferences.self, from: data),
              migrated.desktopPosition == .dock, migrated.desktopEdge == .top else {
            fputs("UI smoke: legacy Dock preference migration failed\n", stderr); exit(1)
        }

        prefs.desktopPosition = .edge
        prefs.desktopLength = 0.42
        let usable = screen.visibleFrame
        for edge in ScreenEdge.desktopChoices {
            prefs.desktopEdge = edge
            let frame = overlay.frame
            let expected = edge.windowFrame(size: size, in: screen.frame, lengthFraction: 0.42, within: usable)
            guard frame == expected, usable.contains(frame), plot.screenEdge == edge, !overlay.hasShadow,
                  overlay.level == .normal, dockTimer == nil, freeWindowFrame == free else {
                fputs("UI smoke: desktop edge \(edge.rawValue) mismatch \(frame) / \(expected)\n", stderr); exit(1)
            }
        }
        prefs.desktopEdge = .top
        resizeWindow(CGSize(width: 300, height: 48))
        let desktop = overlay.frame
        guard desktop.height == 48, desktop.maxY == usable.maxY, freeWindowFrame == free else { exit(1) }

        updateFullscreenContext(screen)
        guard overlay.frame == desktop, plot.screenEdge == .top else { exit(1) }
        prefs.fullscreenEdge = .right
        prefs.fullscreenLength = 0.35
        prefs.fullscreenBehavior = .edge
        let full = ScreenEdge.right.windowFrame(size: desktop.size, in: screen.frame, lengthFraction: 0.35)
        guard overlay.frame == full, plot.screenEdge == .right, overlay.level == .floating else { exit(1) }
        updateFullscreenContext(nil)
        guard overlay.frame == desktop, plot.screenEdge == .top, prefs.desktopLength == 0.42 else { exit(1) }

        captureSettings(named: "desktop-edge-settings")
        prefs = oldPrefs
        guard overlay.frame == free, !plot.pinnedToScreenEdge, freeWindowFrame == free else {
            fputs("UI smoke: original free window was lost after desktop snapping\n", stderr); exit(1)
        }
        print("UI smoke: three desktop edges, thickness, legacy Dock migration and fullscreen override passed")
    }

    /// 保存设置布局的预览，便于确认各状态下展开的控件。
    private func captureSettings(named name: String) {
        guard let directory = smokeDirectory else { return }
        let view = NSHostingView(rootView: SettingsView(model: self))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let file = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
    }

    /// 验证全屏策略不覆盖手动位置，并能恢复 Dock 跟随。
    private func checkFullscreenBehavior() async {
        guard let screen = overlay.screen else { exit(1) }
        let oldPrefs = prefs
        let original = overlay.frame, free = freeWindowFrame
        let legacy = try? JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(Preferences()))
        guard legacy?.fullscreenBehavior == .unchanged, legacy?.fullscreenEdge == .bottom else { exit(1) }
        prefs.hidesWhenSilent = false
        prefs.fullscreenBehavior = .hide
        updateFullscreenContext(screen)
        try? await Task.sleep(for: .milliseconds(180))
        guard overlay.isVisible, overlay.alphaValue > 0, overlay.alphaValue < prefs.opacity else {
            fputs("UI smoke: fullscreen hide did not fade (visible \(overlay.isVisible), alpha \(overlay.alphaValue), fullscreen \(fullscreenScreen != nil))\n", stderr); exit(1)
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !overlay.isVisible, clockRate == 0 else {
            fputs("UI smoke: fullscreen hide did not settle\n", stderr); exit(1)
        }
        prefs.fullscreenBehavior = .edge
        prefs.onTop = false
        for edge in ScreenEdge.allCases {
            prefs.fullscreenEdge = edge
            let expected = edge.windowFrame(size: original.size, in: screen.frame)
            guard overlay.frame == expected, overlay.level == .floating, dockTimer == nil,
                  plot.pinnedToScreenEdge, freeWindowFrame == free else {
                fputs("UI smoke: fullscreen edge \(edge.rawValue) failed, actual \(overlay.frame), expected \(expected), level \(overlay.level.rawValue), pinned \(plot.pinnedToScreenEdge), free \(freeWindowFrame) / \(free)\n", stderr); exit(1)
            }
        }
        let resized = CGSize(width: 300, height: 82)
        resizeWindow(resized)
        guard overlay.frame == prefs.fullscreenEdge.windowFrame(size: resized, in: screen.frame) else {
            fputs("UI smoke: resized fullscreen window lost its edge\n", stderr); exit(1)
        }
        resizeWindow(original.size)
        captureSettings(named: "fullscreen-settings")
        updateFullscreenContext(nil)
        try? await Task.sleep(for: .milliseconds(250))
        guard overlay.frame == original, !plot.pinnedToScreenEdge,
              overlay.level == .normal, overlay.isVisible else {
            fputs("UI smoke: fullscreen restoration failed\n", stderr); exit(1)
        }
        prefs.followsDock = true
        if dockAnchor != nil {
            let docked = overlay.frame
            updateFullscreenContext(screen)
            updateFullscreenContext(nil)
            guard overlay.frame == docked, plot.attachedToDock, dockTimer != nil, freeWindowFrame == free else {
                fputs("UI smoke: fullscreen did not restore Dock tracking\n", stderr); exit(1)
            }
        }
        prefs = oldPrefs
        print("UI smoke: fullscreen fade, four edges, saved settings and Dock restoration passed")
    }

    /// 暂停音频后仍能完成配色过渡，切歌时从当前颜色续接。
    private func checkPaletteFade() async {
        let oldPrefs = prefs, oldArtwork = artwork
        let oldDemo = demo
        prefs.capture = false
        prefs.hidesWhenSilent = false
        demo = false
        let initial = palette
        artwork = ArtworkUpdate(palette: .dusk, note: "演示封面")
        applyPalette()
        guard palette == initial, paletteTarget == .dusk else { exit(1) }
        try? await Task.sleep(for: .milliseconds(180))
        guard palette != initial, palette != .dusk, paletteFrom != nil else {
            fputs("UI smoke: artwork palette did not interpolate\n", stderr); exit(1)
        }
        artwork = ArtworkUpdate(palette: .lagoon, note: "下一张演示封面")
        applyPalette()
        guard paletteFrom == palette, palette != .dusk else {
            fputs("UI smoke: palette retarget jumped to the old cover\n", stderr); exit(1)
        }
        try? await Task.sleep(for: .milliseconds(780))
        guard palette == .lagoon, paletteFrom == nil, clockRate == 0 else {
            fputs("UI smoke: palette fade did not finish while audio was paused\n", stderr); exit(1)
        }
        prefs.colorMode = .solid
        guard palette == SpectrumPalette([prefs.firstColor]), paletteFrom == nil else { exit(1) }
        artwork = oldArtwork
        demo = oldDemo
        prefs = oldPrefs
        applyPalette()
        try? await Task.sleep(for: .milliseconds(780))
        print("UI smoke: palette fade, interruption continuity and paused-audio completion passed")
    }

    /// 在可用屏幕上检查最大帧率请求和真实回调，使用独立的演示窗口。
    private func checkScreenFrameRate() async {
        guard let initial = overlay.screen else {
            fputs("UI smoke: no display for overlay\n", stderr); exit(1)
        }
        let originalFrame = overlay.frame
        let oldOnTop = prefs.onTop
        let oldFPS = prefs.fps
        prefs.onTop = true
        prefs.fps = Preferences.screenFPS
        defer {
            prefs.fps = oldFPS
            prefs.onTop = oldOnTop
            overlay.setFrame(originalFrame, display: true)
        }
        let other = NSScreen.screens.first { $0.frame != initial.frame }
        for screen in [initial, other].compactMap({ $0 }) {
            if screen.frame != overlay.screen?.frame {
                overlay.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24))
            }
            let start = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .milliseconds(300))
            let rate = screen.maximumFramesPerSecond
            guard overlay.screen?.frame == screen.frame, displayClockWindow === overlay,
                  clock == nil, clockRate == rate, displayClock?.preferredFrameRateRange.preferred == Float(rate),
                  lastTick > start + 0.1 else {
                fputs("UI smoke: screen refresh sync failed (expected \(rate) Hz, set \(clockRate) Hz)\n", stderr)
                exit(1)
            }
            print("UI smoke: screen refresh sync at \(rate) Hz (\(screen.localizedName))")
        }
    }

    /// 菜单栏单独显示且状态项可见时，检查时钟使用按钮所在屏幕。
    private func checkMenuScreenFrameRate() async {
        let oldFPS = prefs.fps
        prefs.fps = Preferences.screenFPS
        defer { prefs.fps = oldFPS }
        try? await Task.sleep(for: .milliseconds(300))
        guard let window = statusItem.button?.window, window.occlusionState.contains(.visible),
              let screen = window.screen else {
            print("UI smoke: menu bar refresh check skipped (status item hidden)")
            return
        }
        guard displayClockWindow === window, clockRate == screen.maximumFramesPerSecond,
              (displayClock?.timestamp ?? 0) > 0 else {
            fputs("UI smoke: menu bar refresh sync failed\n", stderr); exit(1)
        }
        print("UI smoke: menu bar refresh sync at \(clockRate) Hz")
    }

    /// 将合成 PCM 交给正常的采样时钟，验证短停顿、淡出和重新有声时的窗口行为。
    private func checkIdleFade() async {
        guard let samples = PCMBuffer() else { exit(1) }
        let oldClickThrough = prefs.clickThrough
        prefs.fps = Preferences.screenFPS
        prefs.followsDock = true
        let docked = plot.attachedToDock
        prefs.clickThrough = false
        prefs.capture = false
        demo = false
        pcm = samples
        let tone = (0..<SpectrumAnalyzer.size).map { 0.1 * sinf(Float($0) * 0.13) }
        let fullOpacity = prefs.opacity

        try? await Task.sleep(for: .milliseconds(540))
        guard !overlay.isVisible, overlay.ignoresMouseEvents, dockTimer == nil, clockRate == 8, displayClock == nil else {
            fputs("UI smoke: silent overlay did not hide\n", stderr); exit(1)
        }
        samples.push(tone)
        try? await Task.sleep(for: .milliseconds(500))
        guard overlay.isVisible, !overlay.ignoresMouseEvents, abs(overlay.alphaValue - fullOpacity) < 0.01,
              !docked || dockTimer != nil else {
            fputs("UI smoke: sound did not wake overlay or short pause hid it\n", stderr); exit(1)
        }

        let untilFade = lastAudible + Self.silenceDelay + 0.16 - ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(for: .seconds(max(0, untilFade)))
        guard overlay.isVisible, overlay.ignoresMouseEvents,
              overlay.alphaValue > 0, overlay.alphaValue < fullOpacity else {
            fputs("UI smoke: overlay did not fade gradually\n", stderr); exit(1)
        }
        try? await Task.sleep(for: .milliseconds(470))
        guard !overlay.isVisible, dockTimer == nil, clockRate == 8, displayClock == nil else {
            fputs("UI smoke: faded overlay remained visible or active\n", stderr); exit(1)
        }
        samples.push(tone)
        try? await Task.sleep(for: .milliseconds(500))
        guard overlay.isVisible, abs(overlay.alphaValue - fullOpacity) < 0.01 else {
            fputs("UI smoke: sound did not restore window opacity\n", stderr); exit(1)
        }
        prefs.followsDock = false
        prefs.clickThrough = oldClickThrough
        demo = true
        prefs.capture = true
        prefs.fps = Preferences.defaultFPS
        print("UI smoke: short pause, gradual fade, silent idle and sound wake passed")
    }

    /// 在频谱柱上方采样一个底板像素，验证透明度没有作用到整块频谱。
    private func menuBackgroundAlpha() -> CGFloat {
        let bounds = menuPlot.bounds
        guard let image = menuPlot.bitmapImageRepForCachingDisplay(in: bounds) else { return -1 }
        menuPlot.cacheDisplay(in: bounds, to: image)
        let y = Int(CGFloat(image.pixelsHigh) / bounds.height * 4)
        return image.colorAt(x: image.pixelsWide / 2, y: y)?.alphaComponent ?? -1
    }

}
