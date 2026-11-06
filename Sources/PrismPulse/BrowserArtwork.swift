import CoreAudio
import Foundation

struct BrowserArtwork {
    struct Cover: Decodable {
        let playing: Bool
        let host: String
        let images: [String]
    }

    enum Result {
        case found(Cover)
        case javascriptDisabled
        case noMedia
    }

    private struct Tab: Equatable {
        var window = 1
        var index = 1
    }

    private var recentTabs: [Player: Tab] = [:]
    private var searchPositions: [Player: Tab] = [:]

    /// 优先检查当前标签和上次播放标签。有系统音频时逐批查找后台标签。
    mutating func read(_ player: Player, target: PlaybackEvents, audible: Bool) -> Result {
        let safari = player == .safari
        let tabClass = safari ? "bTab" : "CrTb"
        let activeTabKey = safari ? "cTab" : "acTa"
        let frontTab = PlaybackEvents.property(activeTabKey, of: PlaybackEvents.element("cwin", at: 1))
        let front = probe(frontTab, target: target, safari: safari)
        if case .javascriptDisabled = front { return front }
        if case let .found(cover) = front, cover.playing || !audible { return front }
        if let recent = recentTabs[player] {
            let result = probe(tab(recent, className: tabClass), target: target, safari: safari)
            if case let .found(cover) = result, cover.playing || !audible { return result }
        }

        let windows = min(12, target.count("cwin"))
        var fallback = front
        if windows > 1 {
            for index in 2...min(windows, 3) {
                let window = PlaybackEvents.element("cwin", at: index)
                let selected = PlaybackEvents.property(activeTabKey, of: window)
                let result = probe(selected, target: target, safari: safari)
                if case let .found(cover) = result {
                    if cover.playing || !audible { return result }
                    fallback = result
                }
            }
        }
        guard audible, windows > 0 else { return fallback }
        var position = searchPositions[player] ?? Tab()
        if position.window > windows { position = Tab() }
        var remaining = 8  // 单次最多检查 8 个标签，发现播放页后直接复用位置。
        let deadline = ProcessInfo.processInfo.systemUptime + 1.15
        for _ in 0..<windows {
            let window = PlaybackEvents.element("cwin", at: position.window)
            let count = target.count(tabClass, in: window)
            while position.index <= count, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
                let current = position
                position.index += 1
                remaining -= 1
                let result = probe(tab(current, className: tabClass), target: target, safari: safari)
                if case let .found(cover) = result, cover.playing {
                    recentTabs[player] = current
                    searchPositions[player] = position
                    return result
                }
            }
            if position.index <= count { break }
            position = Tab(window: position.window % windows + 1)
            if remaining == 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
        }
        searchPositions[player] = position
        return fallback
    }

    private func tab(_ position: Tab, className: String) -> NSAppleEventDescriptor {
        PlaybackEvents.element(className, at: position.index, of: PlaybackEvents.element("cwin", at: position.window))
    }

    /// 只读媒体状态和封面，不返回标题、网页内容或浏览历史。
    private func probe(_ tab: NSAppleEventDescriptor, target: PlaybackEvents, safari: Bool) -> Result {
        let js = NSAppleEventDescriptor(string: Self.coverScript)
        let result = safari
            ? target.send(PlaybackEvents.code("sfri"), PlaybackEvents.code("dojs"), js,
                          parameters: [(PlaybackEvents.code("dcnm"), tab)], timeout: 0.45)
            : target.send(PlaybackEvents.code("CrSu"), PlaybackEvents.code("ExJa"), tab,
                          parameters: [(PlaybackEvents.code("JvSc"), js)], timeout: 0.45)
        // 两类浏览器的脚本权限错误号在不同版本有差异；常规无对象、超时单独处理。
        if result.error != 0, ![-1728, -1712, -600, -609, -1708, -1743, -1744].contains(result.error) {
            return .javascriptDisabled
        }
        guard let text = result.value?.stringValue, !text.isEmpty, text.utf8.count < 2_900_000,
              let cover = try? JSONDecoder().decode(Cover.self, from: Data(text.utf8)) else { return .noMedia }
        return .found(cover)
    }

    // 浏览器仍保有媒体会话时允许当前标签页暂停。页面海报只用于实际在播的视频。
    static let coverScript = #"""
    (() => {
        if (location.protocol !== "https:" && location.protocol !== "http:") return "";
        const session = navigator.mediaSession;
        const media = Array.from(document.querySelectorAll("video,audio"))
            .find(v => !v.paused && !v.ended && !v.muted && v.volume > 0);
        const playing = Boolean(media || session?.playbackState === "playing");
        const candidates = (session?.metadata?.artwork ?? []).slice(0, 4).map(image => image.src);
        if (playing) {
            candidates.push(media?.poster, document.querySelector('meta[property="og:image"]')?.content);
        }
        const images = [];
        for (const source of candidates) {
            if (!source || images.length >= 4) continue;
            try {
                const url = new URL(source, location.href);
                if ((url.protocol === "https:" || url.protocol === "http:") && url.href.length <= 8192) {
                    if (!images.includes(url.href)) images.push(url.href);
                } else if (url.protocol === "data:" && url.href.length < 1350000 && !images.length) {
                    images.push(url.href);
                }
            } catch {}
        }
        if (!images.length) return "";
        return JSON.stringify({playing, host: location.hostname, images});
    })()
    """#

    /// 用 HAL 公开的输出状态区分浏览器与辅助进程，避免空闲时扫描后台标签。
    static func audioBundles() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return [] }
        let bytesPerID = MemoryLayout<AudioObjectID>.stride
        guard Int(size) >= bytesPerID else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / bytesPerID)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &list, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        var bundles: Set<String> = []
        for id in ids.prefix(Int(size) / bytesPerID) {
            var runningAddress = address(kAudioProcessPropertyIsRunningOutput)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }
            var bundleAddress = address(kAudioProcessPropertyBundleID)
            var bundle: CFString?
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            let result = withUnsafeMutablePointer(to: &bundle) {
                AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, $0)
            }
            if result == noErr, let bundle { bundles.insert((bundle as String).lowercased()) }
        }
        return bundles
    }

    static func isAudible(_ player: Player, in bundles: Set<String>) -> Bool {
        let id = player.bundleID.lowercased()
        return bundles.contains { $0 == id || $0.hasPrefix(id + ".") }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
