import AppKit
import CoreGraphics
import Darwin

/// 按显示器读取当前 Space，避免后台进程漏掉其他应用的原生全屏状态。
@MainActor
enum FullscreenContext {
    private typealias ConnectionReader = @convention(c) () -> Int32
    private typealias SpacesReader = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let readers: (connection: ConnectionReader, spaces: SpacesReader)? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let framework = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let connection = dlsym(framework, "SLSMainConnectionID"),
              let spaces = dlsym(framework, "SLSCopyManagedDisplaySpaces") else {
            dlclose(framework)
            return nil
        }
        // 仅查询空间类型，框架在应用运行期间保持加载。
        return (unsafeBitCast(connection, to: ConnectionReader.self),
                unsafeBitCast(spaces, to: SpacesReader.self))
    }()

    /// 只在空间、前台应用或显示器变更时查询，不进入频谱绘制循环。
    static func isFullscreen(on screen: NSScreen) -> Bool {
        if let readers,
           let displays = readers.spaces(readers.connection())?.takeRetainedValue() as? [[String: Any]],
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(displayID.uint32Value)?.takeRetainedValue() {
            let identifier = CFUUIDCreateString(nil, uuid) as String
            if let display = displays.first(where: { ($0["Display Identifier"] as? String) == identifier })
                ?? displays.first(where: { ($0["Display Identifier"] as? String) == "Main" }),
               let current = display["Current Space"] as? [String: Any],
               let type = current["type"] as? NSNumber {
                return type.intValue == 4 // 原生全屏和全屏分屏使用此类型。
            }
        }
        // 系统布局接口不可用时退回公开的前台应用展示状态。
        return screen.frame == NSScreen.main?.frame && NSApp.currentSystemPresentationOptions.contains(.fullScreen)
    }
}
