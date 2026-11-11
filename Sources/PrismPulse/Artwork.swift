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
        Task(priority: .utility) { [weak self, reader] in
            let update = await reader.read()
            guard let self else { return }
            self.busy = false
            guard self.enabled else { return }
            if ticket == self.revision { self.publish(update) }
            else { self.refresh() }
        }
    }
}

private actor ArtworkReader {
    private let queue = DispatchQueue(label: "local.prismpulse.artwork", qos: .utility)
    private var cache: (key: String, palette: SpectrumPalette)?

    /// 先按封面标识复用色板，缺少标识时比较图像哈希。
    /// 读图或取色失败时返回空色板，由设置中的备用配色接管。
    func read() async -> ArtworkUpdate {
        let cachedKey = cache?.key
        // 等待系统会话的阻塞调用继续放在专用队列。
        let snapshot = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: NowPlayingArtwork.read(reusing: cachedKey)) }
        }
        guard let cover = snapshot,
              let key = cover.key ?? cover.artwork.map({ "hash:" + Data(SHA256.hash(data: $0)).base64EncodedString() })
        else { return .waiting }

        let palette: SpectrumPalette
        if let cached = cache, cached.key == key {
            palette = cached.palette
        } else {
            guard let data = cover.artwork, let extracted = await SpectrumPalette.artwork(data) else { return .waiting }
            palette = extracted
            cache = (key, extracted)
        }
        let note = cover.sourceName.map { "正在跟随 \($0) 的封面" } ?? "正在跟随系统播放封面"
        return ArtworkUpdate(palette: palette, note: note)
    }
}
