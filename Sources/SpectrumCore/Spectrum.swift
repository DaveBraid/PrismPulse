import Accelerate
import CPulseRing
import Foundation

/// 固定容量的 PCM 管道，只有音频回调写入，频谱分析器读取。
public final class PCMBuffer: @unchecked Sendable {
    public let raw: OpaquePointer

    public init?() {
        guard let ring = PulseRingCreate() else { return nil }
        raw = ring
    }

    deinit { PulseRingDestroy(raw) }

    /// 输入合成 PCM，供自检和性能测量使用。
    public func push(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { data in
            if let base = data.baseAddress { PulseRingPushMono(raw, base, data.count) }
        }
    }
}

/// 同一主线程上的分析器与多个视图共享帧，省去每次刷新复制数组。
public final class SpectrumFrame {
    public fileprivate(set) var levels: [Float]
    public fileprivate(set) var peaks: [Float]
    public fileprivate(set) var accentPosition = 0.5

    public init(levels: [Float], peaks: [Float]? = nil) {
        precondition(!levels.isEmpty && (peaks == nil || peaks?.count == levels.count))
        self.levels = levels
        self.peaks = peaks ?? levels
    }

    /// 更新演示帧。输入为演示秒数，输出只写入此帧。
    public func demo(at time: Double) {
        for i in levels.indices {
            let x = Double(i) / Double(max(1, levels.count - 1))
            let beat = pow(0.5 + 0.5 * sin(time * 7.8 - x * 5), 5)
            let lobes = 0.22 * exp(-pow((x - 0.47) * 6, 2))
                      + 0.16 * exp(-pow((x - 0.79) * 8, 2))
            let ripples = 0.13 * (0.5 + 0.5 * sin(39 * x + time * 5.5))
            let bass = (0.34 + 0.38 * beat) * exp(-x * 3.2)
            levels[i] = Float(min(1, 0.04 + bass + lobes + ripples))
            peaks[i] = min(1, levels[i] + 0.07 + 0.06 * Float(0.5 + 0.5 * sin(x * 32 - time)))
        }
    }
}

public final class SpectrumAnalyzer {
    public static let size = 4096        // 48 kHz 下频率间隔约 11.7 Hz。
    public static let bandCount = 48     // 窗口的对数频带数量。
    private static let logSize: vDSP_Length = 12
    private let setup: FFTSetup
    private let normalization: Float
    private var window: [Float]
    private var samples = [Float](repeating: 0, count: size)
    private var windowed = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)
    private var targets = [Float](repeating: 0, count: bandCount)
    private var targetHold: Float = 0
    private var hold = [Float](repeating: 0, count: bandCount)
    private var bands: [(first: Int, last: Int, blend: Float, boost: Float)] = []
    public private(set) var frequencies: [Float] = []
    public let frame = SpectrumFrame(levels: [Float](repeating: 0, count: bandCount))

    /// 创建并复用 FFT 计划、窗函数和工作区。输入为采样率。
    public init(sampleRate: Double = 48_000) {
        guard let setup = vDSP_create_fftsetup(Self.logSize, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("无法初始化 vDSP FFT")
        }
        self.setup = setup
        var hann = [Float](repeating: 0, count: Self.size)
        vDSP_hann_window(&hann, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        var sum: Float = 0
        vDSP_sve(hann, 1, &sum, vDSP_Length(Self.size))
        // 实数 FFT 正变换放大两倍；除以窗函数总和后得到正弦幅值的平方。
        normalization = 1 / (sum * sum)
        window = hann
        reset(sampleRate: sampleRate)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// 输入为 Tap 实际采样率；重算频带索引并清掉上一音频设备的状态。
    public func reset(sampleRate: Double) {
        let rate = Float(max(sampleRate.isFinite ? sampleRate : 48_000, 8_000))
        let binHz = rate / Float(Self.size)
        let lower: Float = 36
        let upper: Float = min(16_000, 0.47 * rate)
        let ratio = upper / lower
        frequencies.removeAll(keepingCapacity: true)
        bands.removeAll(keepingCapacity: true)
        for i in 0..<Self.bandCount {
            let a = lower * powf(ratio, Float(i) / Float(Self.bandCount))
            let b = lower * powf(ratio, Float(i + 1) / Float(Self.bandCount))
            let center = sqrtf(a * b)
            let first = max(1, Int(ceilf(a / binHz)))
            let last = min(Self.size / 2 - 1, Int(floorf(b / binHz)))
            let exact = center / binHz
            let boost = min(9, max(-3, 1.5 * log2f(center / 280))) // 补偿高频的平均能量偏低。
            frequencies.append(center)
            bands.append(first <= last
                ? (first, last, -1, boost)
                : (max(1, Int(exact)), min(Self.size / 2 - 1, Int(exact) + 1), exact - floorf(exact), boost))
        }
        targetHold = 0
        for i in samples.indices { samples[i] = 0 }
        for i in frame.levels.indices {
            frame.levels[i] = 0
            frame.peaks[i] = 0
            hold[i] = 0
        }
    }

    /// 取最新样本并平滑柱高。输入为 PCM 管道和经过的秒数；返回有声和需重绘状态。
    @discardableResult
    public func step(_ source: PCMBuffer?, dt: Double) -> (audible: Bool, changed: Bool) {
        var rms: Float = 0
        var receivedFrames = false
        if let source, PulseRingReadLatest(source.raw, &samples, Self.size) > 0 {
            receivedFrames = true
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(Self.size))
        }
        let audible = rms.isFinite && rms > 0.00018 // 约 -75 dBFS 以下视作静音。
        let elapsed = Float(min(0.25, max(0.001, dt)))
        if audible {
            transform()
            targetHold = 0.05 // 秒，跨过高刷下两个 PCM 批次之间的空帧。
        } else if receivedFrames || source == nil {
            targetHold = 0
        } else {
            targetHold = max(0, targetHold - elapsed)
        }
        let usesTargets = targetHold > 0
        let attack = 1 - expf(-elapsed / 0.029)    // 快速起跳。
        let release = 1 - expf(-elapsed / 0.115)  // 回落更慢，减少毛刺。
        var changed = false
        for i in bands.indices {
            if audible {
                let band = bands[i]
                var energy = power[band.first]
                if band.blend >= 0 {
                    energy += (power[band.last] - energy) * band.blend
                } else {
                    for j in (band.first + 1)..<(band.last + 1) { energy = max(energy, power[j]) }
                }
                let db = 10 * log10f(max(1e-12, energy * normalization)) + band.boost
                targets[i] = min(1, max(0, (db + 64) / 59))
            }
            let target = usesTargets ? targets[i] : 0
            let old = frame.levels[i]
            let oldPeak = frame.peaks[i]
            let level = old + (target - old) * (target > old ? attack : release)
            frame.levels[i] = level > 0.002 ? level : 0
            if frame.levels[i] >= oldPeak {
                frame.peaks[i] = frame.levels[i]
                hold[i] = 0.24                // 峰值停留时间，单位秒。
            } else if hold[i] > 0 {
                hold[i] -= elapsed
            } else {
                frame.peaks[i] = max(frame.levels[i], oldPeak - 0.92 * elapsed)
            }
            if frame.levels[i] != old || frame.peaks[i] != oldPeak { changed = true }
        }
        return (audible, changed)
    }

    /// 复用本帧的柱高，输入为经过的秒数。辅色位置改变时返回 true。
    public func updateAccentPosition(dt: Double) -> Bool {
        var total = 0.0
        var weightedPosition = 0.0
        for (level, frequency) in zip(frame.levels, frequencies) where level > 0.12 {
            let amplitude = Double(level) - 0.12  // 忽略低能量频带。
            let squared = amplitude * amplitude
            let weight = squared * squared      // 让主导频段对位置的影响更明显。
            let position = frequency < 240 ? 0.22 : (frequency < 2_200 ? 0.50 : 0.78)
            total += weight
            weightedPosition += position * weight
        }
        guard total > 0.001 else { return false } // 静音或信号太弱时保留位置。
        let target = weightedPosition / total
        let previous = frame.accentPosition
        let response = 1 - exp(-min(0.25, max(0, dt)) / 0.32) // 按时间平滑，适配不同帧率。
        frame.accentPosition = abs(target - previous) < 0.001
            ? target : previous + (target - previous) * response
        return frame.accentPosition != previous
    }

    /// 使用固定工作区执行加窗实数 FFT，输出各线性频点的功率。
    private func transform() {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.logSize, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.size / 2))
            }
        }
    }
}
