import CoreAudio
import CPulseRing
import Foundation
import SpectrumCore

struct TapFailure: LocalizedError {
    let action: String
    let status: OSStatus
    var errorDescription: String? { "\(action)（\(status)）" }
}

private func checked(_ status: OSStatus, _ action: String) throws {
    if status != noErr { throw TapFailure(action: action, status: status) }
}

final class TapSession {
    let pcm: PCMBuffer
    private(set) var sampleRate = 0.0
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var callback: AudioDeviceIOProcID?
    private var running = false

    /// 在控制队列创建只读 Tap、私有设备和实时回调；失败时撤销已完成的步骤。
    init() throws {
        guard let pcm = PCMBuffer() else { throw TapFailure(action: "分配 PCM 缓冲区失败", status: -108) }
        self.pcm = pcm
        do { try start() }
        catch { stop(); throw error }
    }

    deinit { stop() }

    /// 创建全局立体声 Tap；返回实际采样率供 FFT 计算频点。
    private func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "PrismPulse • System Output"
        description.isPrivate = true
        description.muteBehavior = .unmuted // 保留系统原来的播放路径和音量。
        try checked(AudioHardwareCreateProcessTap(description, &tap), "无法创建系统音频 Tap")

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checked(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "无法读取音频格式")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0, format.mSampleRate > 0
        else { throw TapFailure(action: "系统 Tap 未提供 Float32 PCM", status: kAudioDeviceUnsupportedFormatError) }
        sampleRate = format.mSampleRate

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PrismPulse • Private Capture",
            kAudioAggregateDeviceUIDKey: "local.prismpulse." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try checked(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "无法创建私有音频设备")
        try checked(AudioDeviceCreateIOProcID(device, PulseRingAudioIO, UnsafeMutableRawPointer(pcm.raw), &callback),
                    "无法注册音频回调")
        try checked(AudioDeviceStart(device, callback), "无法启动系统音频")
        running = true
    }

    /// 先停止回调，再释放系统对象；支持部分初始化与重复清理。
    private func stop() {
        if running { AudioDeviceStop(device, callback); running = false }
        if let callback { AudioDeviceDestroyIOProcID(device, callback); self.callback = nil }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }
}

final class AudioCapture {
    private let queue = DispatchQueue(label: "local.prismpulse.hal", qos: .userInitiated)
    private var session: TapSession?
    private var routeListener: AudioObjectPropertyListenerBlock?

    /// 串行切换 Tap。输入为期望运行状态；完成后在主队列交回 PCM 管道。
    func setActive(_ active: Bool, completion: @escaping (Result<(PCMBuffer, Double)?, Error>) -> Void) {
        queue.async { [self] in
            session = nil
            let result = Result<(PCMBuffer, Double)?, Error> {
                guard active else { return nil }
                let tap = try TapSession()
                session = tap
                return (tap.pcm, tap.sampleRate)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 监听默认输出变化。蓝牙切换时由界面控制器合并通知，再重建一次 Tap。
    func watchOutput(_ onChange: @escaping () -> Void) {
        queue.async { [self] in
            guard routeListener == nil else { return }
            var address = Self.outputAddress
            let block: AudioObjectPropertyListenerBlock = { _, _ in DispatchQueue.main.async(execute: onChange) }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                routeListener = block
            }
        }
    }

    /// 应用退出前释放监听和设备，完成回调返回主队列。
    func shutdown(_ completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            if let routeListener {
                var address = Self.outputAddress
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, routeListener)
                self.routeListener = nil
            }
            session = nil
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static var outputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
