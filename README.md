# 流光频谱 · PrismPulse

> 一个人干活对着屏幕太枯燥了！在屏幕上可视化你的工作 BGM 吧！给你的屏幕增添一些灵动与生气

简体中文 · [English](README.en.md) · [下载最新版](https://github.com/DaveBraid/PrismPulse/releases/latest)

PrismPulse 是 macOS 的实时系统音频频谱。让正在播放的音乐、视频或游戏声音在 Dock 上方跳动，也可以把频谱放进菜单栏，或者悬浮在屏幕任意位置。

![PrismPulse 切换封面时改变配色，Dock 改宽时频谱同步伸缩](docs/demo.gif)

*演示使用应用的频谱渲染和取色代码。Dock 与封面为示例素材。*

## 特色功能

- **跟随 Dock**。频谱居中贴在底部 Dock 上方，随 Dock 宽度伸缩，两侧给圆角留出空间。高度和圆角都能单独调。选「涌浪」并关闭「深色底板」，就能得到一条贴着 Dock 的透明彩色波形。
- **自动提取封面颜色**。默认把当前专辑封面或视频缩略图配成渐变。备用配色到封面配色、换封面时都平滑过渡。可从 Music、Spotify、Tabbit、Chrome 和 Safari 取色。封面不可用时使用备用配色，也可以自己设定单色或双色渐变。
- **14 种频谱样式**。从光柱、珠链到波形和环形。悬浮窗支持置顶、点击穿透、透明度和拖动缩放。菜单栏频谱可调长度，支持自适应铺满和全透明背景。
- **有声时跳动，安静时淡出**。静音后浮窗自动淡出，声音回来时淡入。帧率可选固定档或「跟随屏幕」。静音时降低音频检查频率。
- **全屏时自动避让**。在「设置 → 悬浮窗 → 应用全屏时」选择淡出隐藏，或沿屏幕上、下、左、右边缘居中显示。退出全屏后恢复原位置和 Dock 跟随。默认保持原样，按浮窗所在屏幕的原生全屏状态判断。

<details>
<summary>查看 14 种样式</summary>

![14 种频谱样式](docs/styles.png)

</details>

## 安装

需要 **macOS 14.4 或更新版本**。通用安装包支持 Apple Silicon 和 Intel Mac。

1. 打开 [Releases](https://github.com/DaveBraid/PrismPulse/releases/latest)，在 Assets 下载 `PrismPulse-macOS.zip`。
2. 解压，把 `PrismPulse.app` 拖入「应用程序」并打开。
3. 允许系统音频录制权限。点菜单栏的波形图标打开设置，播放一段音乐或视频即可看到频谱。

安装包采用临时签名，未经 Apple 公证。如果 macOS 提示无法验证，确认文件来自本仓库后，可在首次尝试打开后到「系统设置 → 隐私与安全性」选择「仍要打开」。[Apple 的打开说明](https://support.apple.com/zh-cn/102445)

## 快速上手

- **贴到 Dock 上方**。把 Dock 放在屏幕底部，在「设置 → 悬浮窗」勾选「跟随 Dock」。拖动浮窗可摆放位置，拖右下角可缩放。贴合时可在设置里调整高度。
- **用浏览器封面配色**。播放媒体后，在「设置 → 封面来源 → 授权取色」选择对应浏览器。Tabbit 和 Chrome 需要在「显示 → 开发者」开启「允许 Apple 事件中的 JavaScript」。Safari 的开关在「设置 → 开发者 → 自动化」。网页优先读取播放器提供的 Media Session 封面，也会尝试视频海报和页面封面。
- **检查音频**。菜单里的「演示动画」无需录音权限。如果有声音但频谱不动，检查「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」，再点菜单里的「重连系统音频」。

音频分析和封面取色都在本机运行。PrismPulse 通过 Core Audio Process Tap 获取系统输出，音频不保存、不上传。

## 从源码构建

安装带 Swift 6 和 macOS 14.4 或更新 SDK 的 Xcode 或 Command Line Tools。项目没有第三方依赖。

```sh
git clone https://github.com/DaveBraid/PrismPulse.git
cd PrismPulse
./Scripts/build.sh
open build/PrismPulse.app
```

核心检查可用 `swift run -c release SpectrumCheck` 运行。频谱计算使用 Accelerate vDSP，悬浮窗和菜单栏共用分析结果。界面使用 AppKit、Core Graphics 和 SwiftUI。

实现参考 [Apple Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)、[AudioCap](https://github.com/insidegui/AudioCap)、[Nowsee](https://github.com/Sergio-prog/Nowsee) 和 [Hammerspoon 的空间查询](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m)。全屏识别使用只读的非公开空间布局接口，接口不可用时退回 AppKit 的展示状态。macOS 更新可能影响识别。

## 许可证

[MIT](LICENSE)
