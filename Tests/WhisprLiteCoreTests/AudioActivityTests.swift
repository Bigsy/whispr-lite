import Testing
import Foundation
import AVFoundation
@testable import WhisprLiteCore

@Suite struct AudioActivityTests {
    @Test func silenceNoiseSpeechAndDecayAreBounded() {
        var meter = AudioActivityMeter()
        func feed(_ amplitude: Float) -> Float? {
            [Float](repeating: amplitude, count: 1600).withUnsafeBufferPointer { meter.consume($0) }
        }
        #expect(feed(0) == 0)
        #expect(feed(0.002) == 0)
        #expect(feed(0.06)! > 0.5)
        for _ in 0..<6 { _ = feed(0) }
        #expect(feed(0) == 0)
        #expect(feed(100) == 1)
        for _ in 0..<8 { _ = feed(.nan) }
        #expect(feed(.infinity) == 0)
    }
    @Test func smallPacketsPublishAtMostTenTimesPerAudioSecond() {
        var meter = AudioActivityMeter(), publications = 0
        let packet = [Float](repeating: 0.04, count: 320)
        for _ in 0..<50 { if packet.withUnsafeBufferPointer({ meter.consume($0) }) != nil { publications += 1 } }
        #expect(publications == 10)
    }
    @Test func feedbackPreservesCapturedPCMAndResetsBetweenRecordings() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)); packet.frameLength = 1600
        for i in 0..<1600 { packet.floatChannelData![0][i] = 0.1 }
        try worker.begin(warm: false, activity: true, timings: true)
        worker.receive(packet); worker.queue.sync {}
        #expect(worker.activity.read() == 1)
        #expect(worker.firstAudioUptime() != nil)
        let pcm = try await worker.end()
        #expect(pcm.samples.count == 1600 && pcm.samples.allSatisfy { abs($0 - 0.1) < 0.001 })
        #expect(worker.activity.read() == 0)
        try worker.begin(warm: false, activity: false)
        worker.receive(packet); worker.queue.sync {}
        #expect(worker.activity.read() == 0)
        #expect(worker.firstAudioUptime() == nil)
        #expect(try await worker.end() == pcm)
        // Warm idle input doesn't run or publish an activity meter.
        worker.receive(packet); worker.queue.sync {}
        #expect(worker.activity.read() == 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHISPR_FEEDBACK_BENCHMARK_PATH"] != nil))
    func optionalSyntheticWorkerBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WHISPR_FEEDBACK_BENCHMARK_PATH"])
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let workers = try [AudioWorker(format: format), AudioWorker(format: format)]
        let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)); packet.frameLength = 960
        for channel in 0..<2 { for i in 0..<960 { packet.floatChannelData![channel][i] = 0.06 * sin(Float(i) * 0.05) } }
        var enabled: [Double] = [], disabled: [Double] = []
        for iteration in 0..<32 {
            for mode in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                let worker = workers[mode ? 1 : 0]
                try worker.begin(warm: false, activity: mode)
                let start = ContinuousClock.now
                for _ in 0..<100 { worker.receive(packet); worker.queue.sync {} }
                let audio = try await worker.end()
                #expect(abs(audio.duration - 2) < 0.002)
                let ms = start.duration(to: .now).milliseconds
                if iteration >= 2 { if mode { enabled.append(ms) } else { disabled.append(ms) } }
            }
        }
        let data: [String: Any] = ["schema": 1, "mode": "synthetic-capture-worker-only", "audio_seconds_per_run": 2,
                                  "count_per_condition": enabled.count, "enabled_ms": enabled, "disabled_ms": disabled,
                                  "physical_capture_or_asr_measured": false]
        try JSONReport.write(data, to: URL(fileURLWithPath: path))
    }
}
