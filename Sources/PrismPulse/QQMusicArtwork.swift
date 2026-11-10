import Foundation

enum QQMusicArtwork {
    struct Snapshot: Decodable {
        let key: String?
        let artwork: Data?
    }

    /// 在封面队列中读取 QQ 音乐的系统播放会话。
    /// 活跃来源不匹配或查询失败时返回 nil，保持其他封面来源可用。
    static func read(reusing cachedKey: String?) -> Snapshot? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, "--", Player.qqMusic.bundleID, cachedKey ?? ""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // 私有接口失效时终止本次查询，避免卡住其他播放器。
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: reply)
    }

    // 只读取系统正在播放的 QQ 音乐封面。JXA 对象回调桥参考 YohakuCompanion。
    // https://github.com/Innei/YohakuCompanion/blob/470bc72/YohakuCompanion/Core/MediaInfoManager/JXAMediaInfoProvider.swift
    private static let script = #"""
    ObjC.import("Foundation");
    ObjC.bindFunction("objc_msgSend", ["void", ["id", "selector", "id"]]);

    function run(args) {
        const bundleID = args[0];
        const framework = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework");
        if (!framework.load) return;
        const source = $.NSClassFromString("MRNowPlayingRequest");
        if (source.isNil()) return;

        // 只接受系统正在播放的 QQ 音乐，避免拿到其他播放器的图像。
        function matches(path) {
            return !path.isNil() && ObjC.unwrap(path.client.bundleIdentifier) === bundleID && source.localIsPlaying;
        }

        // 系统封面标识未变时直接复用色板，无须再次请求图片。
        function artworkKey() {
            const info = source.localNowPlayingItem.nowPlayingInfo;
            const value = ObjC.unwrap(info.objectForKey("kMRMediaRemoteNowPlayingInfoArtworkIdentifier"));
            return typeof value === "string" && value.length > 0 && value.length <= 512 && !value.includes("\0")
                ? "art:" + value : null;
        }

        const path = source.localNowPlayingPlayerPath;
        if (!matches(path)) return;
        const key = artworkKey();
        if (key !== null && key === args[1]) return JSON.stringify({key});

        const request = source.alloc.initWithPlayerPath(path);
        const selector = $.NSSelectorFromString("requestNowPlayingItemArtworkWithCompletion:");
        if (!request.respondsToSelector(selector)) return JSON.stringify({key});
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
        if (!matches(source.localNowPlayingPlayerPath) || artworkKey() !== key) return;
        const size = image === null || image.isNil() ? 0 : Number(image.length);
        const artwork = size > 0 && size <= 12 * 1024 * 1024
            ? ObjC.unwrap(image.base64EncodedStringWithOptions(0)) : null;
        return JSON.stringify({key, artwork});
    }
    """#
}
