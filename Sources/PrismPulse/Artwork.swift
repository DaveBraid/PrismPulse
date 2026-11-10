import AppKit
import ApplicationServices
import CryptoKit
import SpectrumCore

enum Player: String, CaseIterable, Identifiable, Sendable {
    case music = "Music", spotify = "Spotify", qqMusic = "QQ 音乐"
    case tabbit = "Tabbit", chrome = "Chrome", safari = "Safari"
    var id: Self { self }
    var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .qqMusic: "com.tencent.QQMusicMac"
        case .tabbit: "com.tabbit-ai.Tabbit"
        case .chrome: "com.google.Chrome"
        case .safari: "com.apple.Safari"
        }
    }
    var isBrowser: Bool {
        switch self {
        case .tabbit, .chrome, .safari: true
        case .music, .spotify, .qqMusic: false
        }
    }
}

struct ArtworkUpdate: Equatable, Sendable {
    var palette: SpectrumPalette?
    var note: String
    var connectable: [Player] = []
    static let waiting = ArtworkUpdate(note: "等待播放器或浏览器提供封面")
}

@MainActor final class ArtworkMonitor {
    private let reader = ArtworkReader()
    private let publish: (ArtworkUpdate) -> Void
    private var timer: Timer?
    private var enabled = false
    private var revision = 0
    private var busy = false
    private var pending: Player?
    private var targetPIDs: [pid_t] = []

    init(publish: @escaping (ArtworkUpdate) -> Void) { self.publish = publish }

    /// 只在封面模式且支持的播放器已运行时每 4 秒检查一次；不会启动播放器。
    func configure(enabled: Bool) {
        if self.enabled != enabled {
            self.enabled = enabled
            revision += 1
            pending = nil
        }
        refresh()
    }

    /// 从应用启动、退出通知刷新目标；仅在用户点授权时弹出自动化权限。
    func refresh(ask: Player? = nil) {
        if let ask { pending = ask }
        let targets = enabled ? Player.allCases.compactMap { player in
            NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first
                .map { (player, $0.processIdentifier) }
        } : []
        let pids = targets.map { $0.1 }
        if pids != targetPIDs {
            targetPIDs = pids
            revision += 1
        }
        guard !targets.isEmpty else {
            timer?.invalidate()
            timer = nil
            pending = nil
            publish(.waiting)
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.7
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        guard !busy else { return }
        busy = true
        let request = pending
        pending = nil
        let ticket = revision
        reader.read(targets, request: request) { [weak self] update in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                if self.enabled, ticket == self.revision { self.publish(update) }
                if self.pending != nil || ticket != self.revision { self.refresh() }
            }
        }
    }
}

private final class ArtworkReader: @unchecked Sendable {
    private struct CacheEntry {
        let key: String
        let palette: SpectrumPalette?
        let time: TimeInterval
    }

    // Apple Events、色板缓存和 HTTP 会话的状态只在此队列读写。
    private let queue = DispatchQueue(label: "local.prismpulse.artwork", qos: .utility)
    private var cache: [Player: CacheEntry] = [:]
    private var http: URLSession?
    private var browser = BrowserArtwork()

    deinit { http?.invalidateAndCancel() }

    func read(_ targets: [(Player, pid_t)], request: Player?, completion: @escaping @Sendable (ArtworkUpdate) -> Void) {
        queue.async { [self] in performRead(targets, request: request, completion: completion) }
    }

    /// 读取原生播放器或网页媒体会话提供的封面。
    private func performRead(_ targets: [(Player, pid_t)], request: Player?,
                             completion: @escaping @Sendable (ArtworkUpdate) -> Void) {
        var candidates: [(Player, PlaybackEvents)] = []
        var connectable: [Player] = []
        var refused = false
        var note: String?
        for (player, pid) in targets where player != .qqMusic {
            let target = PlaybackEvents(pid: pid)
            let status = AEDeterminePermissionToAutomateTarget(target.address.aeDesc, kAECoreSuite, kAEGetData, request == player)
            if status == noErr { candidates.append((player, target)) }
            if status == errAEEventWouldRequireUserConsent { connectable.append(player) }
            if status == errAEEventNotPermitted { refused = true }
        }
        // QQ 音乐是系统正在播放的来源时优先用其封面。
        let previousQQ = cache[.qqMusic]
        let cachedQQKey = previousQQ?.palette == nil ? nil : previousQQ?.key
        if targets.contains(where: { $0.0 == .qqMusic }),
           let cover = QQMusicArtwork.read(reusing: cachedQQKey) {
            let palette: SpectrumPalette?
            if let image = cover.artwork {
                let key = cover.key ?? "hash:" + Data(SHA256.hash(data: image)).base64EncodedString()
                palette = localPalette(.qqMusic, key: key) { image }
            } else {
                palette = cover.key == cachedQQKey ? previousQQ?.palette : nil
            }
            if let palette {
                completion(ArtworkUpdate(palette: palette, note: "正在跟随 QQ 音乐的封面", connectable: connectable))
                return
            }
            note = "QQ 音乐未提供可用封面"
        }

        let sounding = candidates.contains(where: { $0.0.isBrowser }) ? BrowserArtwork.audioBundles() : []
        // 原生播放器先检查播放状态；浏览器优先跟随正在输出音频的应用。
        let ordered = candidates.filter { !$0.0.isBrowser }
            + candidates.filter { $0.0.isBrowser && BrowserArtwork.isAudible($0.0, in: sounding) }
            + candidates.filter { $0.0.isBrowser && !BrowserArtwork.isAudible($0.0, in: sounding) }

        for (player, target) in ordered {
            let permitted = connectable
            let source = player.isBrowser ? "\(player.rawValue) 网页" : player.rawValue
            let makeUpdate: @Sendable (SpectrumPalette?) -> ArtworkUpdate = { palette in
                ArtworkUpdate(palette: palette, note: palette == nil ? "\(source) 未提供可用封面" : "正在跟随 \(source) 的封面",
                              connectable: permitted)
            }
            if player.isBrowser {
                switch browser.read(player, target: target, audible: BrowserArtwork.isAudible(player, in: sounding)) {
                case let .found(cover):
                    for image in cover.images {
                        if let data = CoverRedirects.inlineImage(image) {
                            let key = String(image.hashValue)
                            if let palette = localPalette(player, key: key, data: { data }) {
                                completion(makeUpdate(palette))
                                return
                            }
                        } else if let url = CoverRedirects.validURL(image, pageHost: cover.host) {
                            remotePalette(player, url: url) { completion(makeUpdate($0)) }
                            return
                        }
                    }
                    note = note ?? makeUpdate(nil).note
                case .javascriptDisabled:
                    note = note ?? "在 \(player.rawValue) 允许 Apple 事件中的 JavaScript"
                case .noMedia:
                    break
                }
                continue
            }

            guard let state = target.get(PlaybackEvents.property("pPlS")),
                  state.enumCodeValue == PlaybackEvents.code("kPSP") else { continue }
            let track = PlaybackEvents.property("pTrk")
            if player == .music {
                let key = target.get(PlaybackEvents.property("pPIS", of: track))?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    ?? [target.get(PlaybackEvents.property("pnam", of: track))?.stringValue,
                        target.get(PlaybackEvents.property("pArt", of: track))?.stringValue].compactMap { $0 }.joined(separator: "\n")
                let palette = localPalette(player, key: key) {
                    let art = PlaybackEvents.element("cArt", at: 1, of: track)
                    return target.get(PlaybackEvents.property("pRaw", of: art))?.data
                }
                if let palette {
                    completion(makeUpdate(palette))
                    return
                }
            } else if let raw = target.get(PlaybackEvents.property("aUrl", of: track))?.stringValue,
                      let url = CoverRedirects.validURL(raw) {
                remotePalette(player, url: url) { completion(makeUpdate($0)) }
                return
            }
            note = note ?? makeUpdate(nil).note
        }
        let fallback = !connectable.isEmpty ? "可授权读取播放器或浏览器封面"
            : refused ? "在系统设置的「自动化」中允许封面读取"
            : ArtworkUpdate.waiting.note
        completion(ArtworkUpdate(note: note ?? fallback, connectable: connectable))
    }

    /// 同一封面只提取一次颜色。获取失败时留出短暂退避。
    private func localPalette(_ player: Player, key: String, data: () -> Data?) -> SpectrumPalette? {
        let now = ProcessInfo.processInfo.systemUptime
        if let entry = cached(player, key: key, now: now) { return entry.palette }
        let palette = data().flatMap(SpectrumPalette.artwork)
        cache[player] = CacheEntry(key: key, palette: palette, time: now)
        return palette
    }

    private func remotePalette(_ player: Player, url: URL, completion: @escaping @Sendable (SpectrumPalette?) -> Void) {
        let key = url.absoluteString
        let now = ProcessInfo.processInfo.systemUptime
        if let entry = cached(player, key: key, now: now) {
            completion(entry.palette)
            return
        }
        download(url) { [weak self] palette in
            self?.queue.async { [weak self] in
                self?.cache[player] = CacheEntry(key: key, palette: palette, time: now)
                completion(palette)
            }
        }
    }

    private func cached(_ player: Player, key: String, now: TimeInterval) -> CacheEntry? {
        guard !key.isEmpty, let entry = cache[player], entry.key == key,
              entry.palette != nil || now - entry.time < 20 else { return nil }
        return entry
    }

    private func download(_ url: URL, completion: @escaping @Sendable (SpectrumPalette?) -> Void) {
        if http == nil {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 4
            config.timeoutIntervalForResource = 6
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            http = URLSession(configuration: config, delegate: CoverRedirects(), delegateQueue: nil)
        }
        http?.dataTask(with: url) { data, response, _ in
            let palette = (response as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(SpectrumPalette.artwork) : nil
            completion(palette)
        }.resume()
    }

}

/// 针对已运行的目标发送短超时 Apple Events。播放器和浏览器共享对象引用与错误处理。
struct PlaybackEvents {
    let address: NSAppleEventDescriptor

    init(pid: pid_t) { address = NSAppleEventDescriptor(processIdentifier: pid) }

    func get(_ object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        send(kAECoreSuite, kAEGetData, object).value
    }

    func count(_ element: String, in container: NSAppleEventDescriptor = .null()) -> Int {
        let result = send(kAECoreSuite, kAECountElements, container,
                          parameters: [(keyAEObjectClass, .init(typeCode: Self.code(element)))])
        return Int(result.value?.int32Value ?? 0)
    }

    /// 对象引用是只读操作的目标。授权检查由调用方统一完成。
    func send(_ eventClass: AEEventClass, _ id: AEEventID, _ object: NSAppleEventDescriptor,
              parameters: [(AEKeyword, NSAppleEventDescriptor)] = [], timeout: TimeInterval = 1.2)
        -> (value: NSAppleEventDescriptor?, error: Int32) {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: id, targetDescriptor: address,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        for (key, value) in parameters { event.setParam(value, forKeyword: key) }
        let mode = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent))
        do {
            let reply = try event.sendEvent(options: mode, timeout: timeout)
            let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
            return (error == 0 ? reply.paramDescriptor(forKeyword: keyDirectObject) : nil, error)
        } catch let error as NSError {
            return (nil, Int32(clamping: error.code))
        }
    }

    static func code(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    static func property(_ name: String, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        object(classCode: typeProperty, form: OSType(formPropertyID), key: .init(typeCode: code(name)), container: container)
    }

    static func element(_ name: String, at index: Int, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        object(classCode: code(name), form: OSType(formAbsolutePosition), key: .init(int32: Int32(index)), container: container)
    }

    private static func object(classCode: OSType, form: OSType, key: NSAppleEventDescriptor,
                               container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record()
        spec.setDescriptor(.init(typeCode: classCode), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(.init(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(container ?? .null(), forKeyword: AEKeyword(keyAEContainer))
        return spec.coerce(toDescriptorType: typeObjectSpecifier) ?? spec
    }
}

private final class CoverRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// 原生播放器限定 Spotify 图床，网页允许已知图床和本页的 HTTPS 域名。
    static func validURL(_ text: String, pageHost: String? = nil) -> URL? {
        guard text.utf8.count <= 8192, var parts = URLComponents(string: text),
              let host = parts.host?.lowercased(),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let spotify = ["i.scdn.co", "image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com", "images.spotify.com"]
        let knownCDN = ["hdslb.com", "biliimg.com", "ytimg.com", "googleusercontent.com", "sndcdn.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
        let lastLabel = host.split(separator: ".").last.map(String.init) ?? ""
        let samePublicHost = host == pageHost?.lowercased() && host.contains(".")
            && lastLabel.utf8.allSatisfy { (97...122).contains($0) }
            && !["local", "localhost", "lan", "internal", "home", "test", "invalid"].contains(lastLabel)
        guard spotify.contains(host) || (pageHost != nil && (knownCDN || samePublicHost)) else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    static func inlineImage(_ text: String) -> Data? {
        guard text.utf8.count < 1_400_000, let comma = text.firstIndex(of: ","),
              ["data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64",
               "data:image/avif;base64", "data:image/gif;base64"].contains(String(text[..<comma]).lowercased())
        else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap {
            Self.validURL($0.absoluteString, pageHost: task.originalRequest?.url?.host)
        }.map { URLRequest(url: $0) })
    }
}
