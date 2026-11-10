import CryptoKit
import Foundation
import SpectrumCore

struct ArtworkUpdate: Equatable, Sendable {
    var palette: SpectrumPalette?
    var note: String
    static let waiting = ArtworkUpdate(note: "使用备用配色")
}

@MainActor final class ArtworkMonitor {
    private let reader = ArtworkReader()
    private let publish: (ArtworkUpdate) -> Void
    private var timer: Timer?
    private var enabled = false
    private var revision = 0
    private var busy = false

    init(publish: @escaping (ArtworkUpdate) -> Void) { self.publish = publish }

    /// 封面模式启用时每 4 秒检查系统会话，关闭时恢复备用配色。
    func configure(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        revision += 1

        guard enabled else {
            timer?.invalidate()
            timer = nil
            publish(.waiting)
            return
        }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.7
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// 合并仍在进行的查询，忽略关闭或重新开启前的结果。
    private func refresh() {
        guard enabled, !busy else { return }
        busy = true
        let ticket = revision
        reader.read { [weak self] update in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.enabled else { return }
                if ticket == self.revision { self.publish(update) }
                else { self.refresh() }
            }
        }
    }
}

private final class ArtworkReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.prismpulse.artwork", qos: .utility)
    private var cache: (key: String, palette: SpectrumPalette)?

    /// 在后台读取系统封面，避免占用动画和界面的主线程。
    func read(completion: @escaping @Sendable (ArtworkUpdate) -> Void) {
        queue.async { [self] in completion(currentArtwork()) }
    }

    /// 先按封面标识复用色板，缺少标识时比较图像哈希。
    /// 读图或取色失败时返回空色板，由设置中的备用配色接管。
    private func currentArtwork() -> ArtworkUpdate {
        guard let cover = NowPlayingArtwork.read(reusing: cache?.key),
              let key = cover.key ?? cover.artwork.map({ "hash:" + Data(SHA256.hash(data: $0)).base64EncodedString() })
        else { return .waiting }

        let palette: SpectrumPalette
        if let cached = cache, cached.key == key {
            palette = cached.palette
        } else {
            guard let data = cover.artwork, let extracted = SpectrumPalette.artwork(data) else { return .waiting }
            palette = extracted
            cache = (key, extracted)
        }
        let note = cover.sourceName.map { "正在跟随 \($0) 的封面" } ?? "正在跟随系统播放封面"
        return ArtworkUpdate(palette: palette, note: note)
    }
}
