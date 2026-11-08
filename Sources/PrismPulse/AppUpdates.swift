import AppKit
import Combine
import Sparkle

/// 由 Sparkle 管理检查周期、签名校验、安装和重启，不在音频循环中联网。
@MainActor
final class AppUpdates: ObservableObject {
    let enabled: Bool
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    @Published private(set) var canCheck = false
    @Published private(set) var automatic = false
    private let controller: SPUStandardUpdaterController

    init(enabled: Bool) {
        self.enabled = enabled
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.httpHeaders = ["Accept": "application/octet-stream"] // GitHub 资产 API 的匿名二进制下载。
        if enabled {
            controller.startUpdater()
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automatic)
        }
    }

    func setAutomatic(_ value: Bool) {
        controller.updater.automaticallyChecksForUpdates = value
    }

    func check() {
        guard canCheck else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
