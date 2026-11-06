import AppKit

@main @MainActor
struct PrismPulseMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--audio-smoke" { exit(Diagnostics.audioSmoke()) }
        if arguments.first == "--benchmark" {
            Diagnostics.benchmark()
            return
        }
        if arguments.count == 2 && ["--render-gallery", "--render-icon"].contains(arguments[0]) {
            do {
                if arguments[0] == "--render-gallery" { try Diagnostics.gallery(to: arguments[1]) }
                else { try Diagnostics.icon(to: arguments[1]) }
            } catch {
                fputs("生成预览失败：\(error)\n", stderr)
                exit(1)
            }
            return
        }

        let app = NSApplication.shared
        let smoke = arguments.first == "--ui-smoke"
        let delegate = PulseAppDelegate(demo: arguments.contains("--demo"), smoke: smoke,
                                        smokeDirectory: smoke ? arguments.dropFirst().first : nil)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
