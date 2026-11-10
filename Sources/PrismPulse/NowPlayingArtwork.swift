import Foundation

enum NowPlayingArtwork {
    struct Snapshot: Decodable {
        let sourceName: String?
        let key: String?
        let artwork: Data?
    }

    /// 在封面队列中读取 macOS 当前播放会话的封面。
    /// 输入已缓存的封面标识。命中时只返回标识，查询失败时交给备用来源。
    static func read(reusing cachedKey: String?) -> Snapshot? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, "--", cachedKey ?? ""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // 私有接口失效时终止本次查询，避免卡住其他播放器。
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        let reply = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, let reply else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: reply)
    }

    // JXA 对象回调桥参考 YohakuCompanion。
    // https://github.com/Innei/YohakuCompanion/blob/470bc72/YohakuCompanion/Core/MediaInfoManager/JXAMediaInfoProvider.swift
    private static let script = #"""
    ObjC.import("Foundation");
    ObjC.bindFunction("objc_msgSend", ["void", ["id", "selector", "id"]]);

    function run(args) {
        const framework = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework");
        if (!framework.load) return;
        const source = $.NSClassFromString("MRNowPlayingRequest");
        if (source.isNil()) return;

        function text(value) {
            const string = ObjC.unwrap(value);
            return typeof string === "string" || typeof string === "number" ? String(string) : "";
        }

        // 读取系统选择的当前会话。暂停时也可能保有封面。
        function session() {
            const path = source.localNowPlayingPlayerPath;
            if (path.isNil() || path.client.isNil()) return null;
            const client = path.client;
            const item = source.localNowPlayingItem;
            if (item.isNil()) return null;
            const info = item.nowPlayingInfo;
            if (info.isNil()) return null;
            const bundle = text(client.bundleIdentifier);
            const parent = client.respondsToSelector($.NSSelectorFromString("parentApplicationBundleIdentifier"))
                ? text(client.parentApplicationBundleIdentifier) : "";
            return {
                path, info, client,
                sourceID: bundle || parent ? JSON.stringify([bundle, parent]) : "",
                itemID: item.respondsToSelector($.NSSelectorFromString("identifier")) ? text(item.identifier) : "",
                artworkID: text(info.objectForKey("kMRMediaRemoteNowPlayingInfoArtworkIdentifier"))
            };
        }

        function encodeImage(data) {
            if (data === null || data.isNil()) return null;
            const size = Number(data.length);
            return size > 0 && size <= 12 * 1024 * 1024
                ? text(data.base64EncodedStringWithOptions(0)) || null : null;
        }

        const current = session();
        if (!current) return;
        const name = current.client.respondsToSelector($.NSSelectorFromString("displayName"))
            ? text(current.client.displayName).trim().slice(0, 100) : "";
        const key = current.sourceID && current.artworkID && current.artworkID.length <= 512
            ? "art:" + JSON.stringify([current.sourceID, current.artworkID]) : null;
        const result = {sourceName: name || null, key};
        if (key !== null && key === args[0]) return JSON.stringify(result);

        const inline = encodeImage(current.info.objectForKey("kMRMediaRemoteNowPlayingInfoArtworkData"));
        if (inline) return JSON.stringify({...result, artwork: inline});
        const request = source.alloc.initWithPlayerPath(current.path);
        const selector = $.NSSelectorFromString("requestNowPlayingItemArtworkWithCompletion:");
        if (!request.respondsToSelector(selector)) return JSON.stringify(result);

        let finished = false;
        let image = null;
        const receive = ObjC.block(["void", ["id", "id"]], (artwork, error) => {
            if (error.isNil() && !artwork.isNil()) {
                image = artwork.respondsToSelector($.NSSelectorFromString("imageData")) ? artwork.imageData : artwork;
            }
            finished = true;
        });
        const bridge = $.NSPredicate.predicateWithBlock(receive); // 持有原生回调直至查询结束。
        $.objc_msgSend(request, selector, bridge.valueForKey("block"));
        const deadline = Date.now() + 1200;
        while (!finished && Date.now() < deadline) {
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.03));
        }

        // 回调等待期间切歌或换播放器时丢弃旧图。
        const latest = session();
        if (!latest || latest.sourceID !== current.sourceID || latest.itemID !== current.itemID ||
            latest.artworkID !== current.artworkID || (!current.sourceID && !current.path.isEqual(latest.path))) return;
        return JSON.stringify({...result, artwork: encodeImage(image)});
    }
    """#
}
