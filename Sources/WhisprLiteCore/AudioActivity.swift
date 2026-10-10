import Foundation
import Accelerate

/// Visual feedback only. No VAD model, audio gating, segmentation or transcript decisions.
/// Runs on the existing conversion worker, never in the real-time tap.
struct AudioActivityMeter {
    private var frames = 0
    private var energy: Float = 0
    private var measured = 0
    private var level: Float = 0
    mutating func consume(_ samples: UnsafeBufferPointer<Float>) -> Float? {
        if let base = samples.baseAddress, !samples.isEmpty {
            var sum: Float = 0
            vDSP_svesq(base, 1, &sum, vDSP_Length(samples.count))
            if sum.isFinite { energy += sum; measured += samples.count }
        }
        frames += samples.count
        guard frames >= 1600 else { return nil } // At most 10 updates/second.
        let rms = measured == 0 ? 0 : sqrt(energy / Float(measured))
        let target = min(1, max(0, (rms - 0.004) / 0.08))
        level = target >= level ? target : level * 0.35
        if level < 0.025 { level = 0 }
        frames = 0; energy = 0; measured = 0
        return (level * 20).rounded() / 20
    }
}

/// One scalar, no queued UI notifications. Dropping a display update is harmless.
final class AudioActivityValue: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0
    func publish(_ value: Float) {
        guard lock.try() else { return }
        level = value; lock.unlock()
    }
    func read() -> Float {
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        return level
    }
}
