# PrismPulse · 流光频谱

> Working alone in front of a screen gets dull! Visualize the background music you work to. Give your screen a little movement and life.

[简体中文](README.md) · English · [Download the latest release](https://github.com/DaveBraid/PrismPulse/releases/latest)

PrismPulse is a live system audio visualizer for macOS. Let your music, videos, or games animate a spectrum above the Dock, in the menu bar, or in a floating window anywhere on your screen.

![PrismPulse changes color with the cover and resizes as the Dock changes width](docs/demo.gif)

*The demo uses the app's spectrum renderer and color extraction code with a simulated Dock and sample covers.*

## Features

- **Follow the Dock.** Keep the spectrum centered just above the bottom Dock. It follows the Dock's width and leaves room for its rounded corners. Set the height and corner radius separately. Pick the wave style (「涌浪」) and turn off the dark backdrop for a transparent wave that meets the top of the Dock.
- **Extract colors from artwork.** PrismPulse blends colors from the current album cover or video thumbnail by default. Colors transition smoothly from the fallback palette and between covers. It uses the current macOS Now Playing artwork, including covers and thumbnails from apps that publish them to the system. Choose a fallback palette, a single color, or a custom two-color gradient.
- **14 spectrum styles.** Choose from bars, beads, waves, and rings. The floating window supports always on top, click-through, opacity, and drag resizing. The menu bar spectrum supports adjustable width, automatic fit, and a fully transparent background.
- **Fade out in silence.** The window fades away when playback goes quiet and fades in when sound returns. Capture stops after about two seconds without an active output stream and resumes when playback returns. Choose a fixed frame rate or follow the current display.
- **Snap to a desktop edge.** Under 「悬浮窗 → 桌面位置」, choose 「贴边显示」 for the left, top, or right edge. The top meets the bottom of the menu bar, and the sides leave space for a side Dock. Set the length to 10%–100% of the display width, capped by the available space.
- **Make room for full-screen apps.** Under 「应用全屏时」, keep the desktop layout, fade out, or set a separate edge and length. A separate edge draws flush against the physical display boundary. The top expands downward, and the sides rotate vertically and expand inward. The desktop layout returns when you exit full screen.
- **Update in the app.** PrismPulse checks GitHub releases daily by default. You can also choose 「检查更新…」 in the menu or settings. Confirm installation to download, verify the signatures, replace the app, and relaunch. Automatic checks can be disabled in settings.

<details>
<summary>See all 14 styles</summary>

![All 14 spectrum styles](docs/styles.png)

</details>

## Install

Requires **macOS 14.4 or later**. The universal download supports Apple silicon and Intel Macs.

1. Open [Releases](https://github.com/DaveBraid/PrismPulse/releases/latest) and download `PrismPulse-macOS.zip` from Assets.
2. Unzip it, drag `PrismPulse.app` into Applications, and open it.
3. Play some music or a video and allow system audio recording when prompted. Click the waveform in the menu bar to open settings.

The release is ad hoc signed and has not been notarized by Apple. If macOS blocks the first launch and you have confirmed the download came from this repository, go to **System Settings → Privacy & Security** and choose **Open Anyway** after trying to open the app. [Apple's instructions](https://support.apple.com/en-us/102445)

If you use 0.7 or earlier, install the latest version manually once to enable future in-app updates. Download URLs in 1.0.0 and 1.0.1 return 504 on some networks. Users of those versions should manually install the latest release.

If browser downloads time out, use GitHub CLI.

```sh
gh release download --repo DaveBraid/PrismPulse --pattern PrismPulse-macOS.zip
```

## Quick start

The app uses Chinese labels. These are the settings to look for.

- **Position the floating window.** Choose free placement, bottom Dock, or edge snapping under 「悬浮窗 → 桌面位置」. Drag and resize in free placement. Set the height when following the Dock, or use 「桌面贴边」 for direction and length and 「贴边厚度」 for the thickness of a snapped spectrum.
- **Follow system artwork.** Choose 「封面取色」. PrismPulse uses the cover for the active macOS Now Playing session, including artwork published by QQ Music and browsers, without an additional permission prompt. PrismPulse uses your fallback palette when the system artwork is missing or cannot be read.
- **Check audio.** The menu's demo mode (「演示动画」) needs no recording permission. If the spectrum stays still during playback, check **System Settings → Privacy & Security → Screen & System Audio Recording**, then choose 「重连系统音频」 to reconnect.

Audio analysis and artwork color extraction run locally. PrismPulse captures system output through a Core Audio Process Tap. It does not save or upload audio.

## Build from source

Install Xcode or Command Line Tools with Swift 6 and the macOS 14.4 SDK or later. The first build downloads a pinned version of the Sparkle update framework through Swift Package Manager.

```sh
git clone https://github.com/DaveBraid/PrismPulse.git
cd PrismPulse
./Scripts/build.sh
open build/PrismPulse.app
```

Run `swift run -c release SpectrumCheck` for the core checks. The floating window and menu bar share spectrum data computed with Accelerate vDSP. The UI uses AppKit, Core Graphics, and SwiftUI.

Implementation references include [Apple Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [AudioCap](https://github.com/insidegui/AudioCap), [Nowsee](https://github.com/Sergio-prog/Nowsee), and [Hammerspoon's Space queries](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m). Full-screen detection uses a private, read-only Space layout API with an AppKit presentation-state fallback. macOS updates may affect detection.

## Publish future updates

Commit the source, prepare a universal arm64/x86_64 app bundle and release notes, then run the following scripts. They sign the assets, publish anonymous downloads through GitHub's official asset API, and update the signed feed.

```sh
./Scripts/prepare-update.sh build/PrismPulse.app release-notes.md
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/PrismPulse.app/Contents/Info.plist)
git push origin main
./Scripts/publish-update.sh "build/releases/v$version" release-notes.md
```

Increment `CFBundleVersion` and update `CFBundleShortVersionString` for each release. The private update-signing key stays in the macOS login Keychain under `local.ethanlee.PrismPulse`. Keep that key and the app's public key for subsequent releases. The script uses Sparkle's SwiftPM tools by default. Set `SPARKLE_TOOLS_DIR` to use another tool directory.

## License

Updates use [Sparkle](https://sparkle-project.org/). Its license is included in the application bundle.

[MIT](LICENSE)
