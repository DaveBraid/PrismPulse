import AppKit
import SpectrumCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: PulseAppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(colors: [Color(red: 0.08, green: 0.52, blue: 0.50), Color(red: 0.36, green: 0.20, blue: 0.67)],
                                       startPoint: .bottomLeading, endPoint: .topTrailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("流光频谱").font(.system(size: 23, weight: .semibold))
                    Text("PRISMPULSE  /  SYSTEM AUDIO")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("演示动画", isOn: $model.demo)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            StylePreview(prefs: model.prefs, palette: model.palette)
                .frame(height: 107)
                .accessibilityLabel("\(model.prefs.style.rawValue)样式预览")
                .overlay(alignment: .topTrailing) {
                    Text("样式预览").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }

            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 9) {
                GridRow {
                    rowLabel("显示")
                    Picker("显示", selection: $model.prefs.placement) {
                        ForEach(Placement.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                GridRow {
                    rowLabel("样式")
                    HStack {
                        Picker("样式", selection: $model.prefs.style) {
                            ForEach(SpectrumStyle.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                        Text("\(SpectrumStyle.allCases.count) 款").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                GridRow {
                    rowLabel("颜色")
                    Picker("颜色", selection: $model.prefs.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                GridRow {
                    rowLabel(model.prefs.colorMode == .artwork ? "备用配色" : "自定颜色")
                    HStack {
                        switch model.prefs.colorMode {
                        case .artwork:
                            Picker("备用配色", selection: $model.prefs.fallback) {
                                ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                        case .solid, .gradient:
                            ColorPicker(model.prefs.colorMode == .solid ? "颜色" : "起点",
                                        selection: color($model.prefs.firstColor), supportsOpacity: false)
                            if model.prefs.colorMode == .gradient {
                                ColorPicker("终点", selection: color($model.prefs.lastColor), supportsOpacity: false)
                            }
                        }
                        Spacer(minLength: 0)
                        if model.prefs.colorMode != .solid {
                            Picker("渐变方向", selection: $model.prefs.vertical) {
                                Text("横向").tag(false)
                                Text("纵向").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 108)
                        }
                    }
                }
                if model.prefs.colorMode == .artwork {
                    GridRow {
                        rowLabel("封面来源")
                        HStack {
                            Text(model.artwork.note).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if !model.artwork.connectable.isEmpty {
                                Menu("授权取色") {
                                    ForEach(model.artwork.connectable) { player in
                                        Button("允许 \(player.rawValue)") { model.connectArtwork(player) }
                                    }
                                }.fixedSize()
                            } else if model.artwork.note.contains("自动化") {
                                Button("系统设置…", action: model.openAutomationPermissions)
                            }
                        }
                    }
                }
            }

            if model.prefs.placement.showsMenu {
                Divider()
                statusBarSettings
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("悬浮窗").font(.headline)
                    Spacer()
                    Toggle("跟随 Dock", isOn: $model.prefs.followsDock).toggleStyle(.checkbox)
                    Menu(model.prefs.followsDock ? "窗口高度" : "窗口尺寸") {
                        Button(model.prefs.followsDock ? "82 pt" : "小 · 300 × 82") {
                            model.resizeWindow(CGSize(width: 300, height: 82))
                        }
                        Button(model.prefs.followsDock ? "124 pt" : "中 · 474 × 124") {
                            model.resizeWindow(CGSize(width: 474, height: 124))
                        }
                        Button(model.prefs.followsDock ? "146 pt" : "宽 · 650 × 146") {
                            model.resizeWindow(CGSize(width: 650, height: 146))
                        }
                        Button(model.prefs.followsDock ? "300 pt" : "方 · 300 × 300") {
                            model.resizeWindow(CGSize(width: 300, height: 300))
                        }
                    }.fixedSize()
                }
                HStack(spacing: 19) {
                    Toggle("置顶", isOn: $model.prefs.onTop)
                    Toggle("点击穿透", isOn: $model.prefs.clickThrough)
                    Toggle("深色底板", isOn: $model.prefs.backdrop)
                    Toggle("静音时淡出", isOn: $model.prefs.hidesWhenSilent)
                    Spacer()
                }.toggleStyle(.checkbox)
                HStack(spacing: 11) {
                    Text("不透明度").foregroundStyle(.secondary)
                    Slider(value: $model.prefs.opacity, in: 0.12...1) { Text("窗口不透明度") }.labelsHidden()
                    Text("\(Int((model.prefs.opacity * 100).rounded()))%")
                        .monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                HStack(spacing: 11) {
                    Text("圆角").foregroundStyle(.secondary)
                    Slider(value: $model.prefs.cornerRadius, in: 0...Preferences.maximumCornerRadius, step: 1) {
                        Text("悬浮窗圆角")
                    }.labelsHidden()
                    Text("\(Int(model.prefs.cornerRadius)) pt")
                        .monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                Text(model.prefs.followsDock
                     ? "Dock 位于屏幕底部时自动对齐。关闭后恢复手动位置。"
                     : "拖动浮窗可移动；拖右下角可缩放。穿透开启后，可从菜单栏关回。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.prefs.placement.showsWindow)

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(model.audioNote == "正在读取系统音频" || model.demo ? Color.mint : Color.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(model.audioNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Picker("帧率", selection: $model.prefs.fps) {
                    ForEach(Preferences.fixedFrameRates, id: \.self) { Text("\($0) 帧").tag($0) }
                    Text("跟随屏幕").tag(Preferences.screenFPS)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Menu {
                    Button(model.prefs.capture ? "暂停系统音频" : "恢复系统音频") { model.prefs.capture.toggle() }
                    Button("重连系统音频", action: model.restartAudio).disabled(model.demo || !model.prefs.capture)
                    Button("录音权限…", action: model.openAudioPermissions)
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("音频选项")
                }.fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 23)
        .padding(.top, 13)
        .padding(.bottom, 18)
        .frame(width: 506)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: true, vertical: true)
    }

    private var statusBarSettings: some View {
        let settings = model.prefs.statusBar
        let requestedWidth = Int(settings.width.rounded())
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("菜单栏频谱").font(.headline)
                Spacer()
                Toggle("自适应铺满", isOn: $model.prefs.statusBar.fillsSpace)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 11) {
                Text("背景不透明度").foregroundStyle(.secondary)
                Slider(value: $model.prefs.statusBar.backgroundOpacity, in: 0...1) {
                    Text("菜单栏背景不透明度")
                }.labelsHidden()
                Text("\(Int((settings.backgroundOpacity * 100).rounded()))%")
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            if settings.fillsSpace {
                HStack {
                    Text("随前台应用与显示器调整").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.actualMenuWidth) pt").monospacedDigit()
                }
            } else {
                HStack(spacing: 11) {
                    Text("长度").foregroundStyle(.secondary)
                    Slider(value: $model.prefs.statusBar.width,
                           in: StatusBarPreferences.minimumWidth...manualWidthUpperBound, step: 1) {
                        Text("菜单栏频谱长度")
                    }.labelsHidden()
                    TextField("长度", value: menuWidthInput, format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 51)
                    Text("pt").foregroundStyle(.secondary)
                }
                if model.actualMenuWidth < requestedWidth {
                    Text("当前菜单栏空间可容纳 \(model.actualMenuWidth) pt")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var manualWidthUpperBound: Double {
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1_200
        return min(StatusBarPreferences.maximumWidth, max(model.prefs.statusBar.width, screenWidth))
    }

    private var menuWidthInput: Binding<Double> {
        Binding(get: { model.prefs.statusBar.width }, set: { width in
            guard width.isFinite else { return }
            model.prefs.statusBar.width = min(StatusBarPreferences.maximumWidth,
                                              max(StatusBarPreferences.minimumWidth, width.rounded()))
        })
    }

    private func rowLabel(_ label: String) -> some View {
        Text(label).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
    }

    /// 在原生取色器与持久化 sRGB 数值之间转换。
    private func color(_ value: Binding<RGB>) -> Binding<Color> {
        Binding(
            get: { Color(red: value.wrappedValue.red, green: value.wrappedValue.green, blue: value.wrappedValue.blue) },
            set: { new in
                if let rgb = NSColor(new).usingColorSpace(.sRGB) {
                    value.wrappedValue = RGB(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                }
            }
        )
    }
}

private struct StylePreview: NSViewRepresentable {
    let prefs: Preferences
    let palette: SpectrumPalette

    func makeNSView(context: Context) -> SpectrumCanvas {
        let data = SpectrumFrame(levels: [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
        data.demo(at: 1.77)
        return SpectrumCanvas(frameData: data, surface: .preview)
    }

    func updateNSView(_ view: SpectrumCanvas, context: Context) {
        var settings = prefs
        settings.backdrop = true
        view.apply(settings, palette: palette)
    }
}
