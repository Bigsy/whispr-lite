import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@Suite struct AudioTests {
    @Test func longCapturePublishesCompletedChunksWithoutChangingFinalAudio() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        let stream = try #require(try worker.begin(warm: false, earlyChunks: true))
        let received = LockedCounter()
        let reader = Task { () throws -> [PCM16k] in
            var result: [PCM16k] = []
            for try await chunk in stream { result.append(chunk); received.increment() }
            return result
        }
        let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200))
        packet.frameLength = 3200
        func feed(_ value: Float, packets: Int) {
            for index in 0..<3200 { packet.floatChannelData![0][index] = value }
            for _ in 0..<packets { worker.receive(packet); worker.queue.sync {} }
        }
        feed(0.2, packets: 50); feed(0, packets: 2)
        // The stream holds one finished chunk; real-time audio gives the reader seconds to take it.
        try await poll { received.value == 1 }
        feed(0.3, packets: 50); feed(0, packets: 2)
        let full = try await worker.end()
        let chunks = try await reader.value
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { (10...15).contains($0.duration) })
        #expect(Array(full.pcm.samples.prefix(chunks.flatMap(\.samples).count)) == chunks.flatMap(\.samples))
    }
    @Test func earlyChunkEndsAtAPauseOverANoiseFloor() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        let stream = try #require(try worker.begin(warm: false, earlyChunks: true))
        let reader = Task { () throws -> [PCM16k] in
            var result: [PCM16k] = []
            for try await chunk in stream { result.append(chunk) }
            return result
        }
        // About 0.007 RMS with peaks over 0.01: quiet to the ear, but a per-sample amplitude test
        // resets on every peak and never finds the pause.
        let noise: [Float] = [0.011, -0.011, 0, 0, 0]
        let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200))
        packet.frameLength = 3200
        var position = 0
        func feed(seconds: Double, speech: Bool) {
            for _ in 0..<Int(seconds * 5) {
                for index in 0..<3200 {
                    packet.floatChannelData![0][index] = noise[position % noise.count]
                        + (speech ? 0.2 * sin(Float(position) * 0.05) : 0)
                    position += 1
                }
                worker.receive(packet); worker.queue.sync {}
            }
        }
        feed(seconds: 10.4, speech: true); feed(seconds: 0.6, speech: false); feed(seconds: 2, speech: true)
        _ = try await worker.end()
        let chunks = try await reader.value
        #expect(chunks.count == 1)
        #expect((10.4...11.0).contains(try #require(chunks.first).duration))
    }
    @MainActor @Test func engineTapCallbackRunsOffMainActorWithOwnedAudio() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        _ = try worker.begin(warm: false)
        // Construct the production tap on MainActor, invoke it as AVAudioEngine does.
        let callback = AudioTap(worker).callback()
        try await Task.detached {
            #expect(pthread_main_np() == 0)
            let format = try monoFormat()
            let buffer = try filledBuffer(format: format, frames: 320, value: 0.25)
            callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            // Source buffers can be reused as soon as the callback returns.
            for i in 0..<320 { buffer.floatChannelData![0][i] = 0 }
        }.value
        let result = try await worker.end()
        #expect(result.pcm.samples.count == 320)
        #expect(result.pcm.samples.allSatisfy { abs($0 - 0.25) < 0.001 })
    }
    @Test(arguments: [16_000.0, 44_100.0, 48_000.0]) func conversionPreservesTailAndDuration(rate: Double) async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let worker = try AudioWorker(format: format)
        _ = try worker.begin(warm: false)
        // 40 ms, with an audible ending marker; no hardware/microphone permission.
        let frames = Int(rate * 0.04)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        for channel in 0..<2 { for i in 0..<frames { buffer.floatChannelData![channel][i] = i >= frames - Int(rate * 0.01) ? 0.5 : 0 } }
        worker.receive(buffer)
        let result = try await worker.end()
        #expect(abs(result.pcm.samples.count - 640) <= 2)
        #expect(result.pcm.samples.suffix(80).contains { abs($0) > 0.1 })
    }
    @Test func warmPrerollIsBoundedAndNotDuplicated() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        let buffer = try filledBuffer(format: format, frames: 3200, value: 0.1)
        worker.receive(buffer)
        _ = try worker.begin(warm: true)
        let result = try await worker.end()
        #expect(result.pcm.samples.count == 2400)
        _ = try worker.begin(warm: true)
        #expect(try await worker.end().pcm.samples.isEmpty)
    }
    @Test(arguments: [44_100.0, 96_000.0, 192_000.0]) func hardwareSizedInputPacketDoesNotOverflowWarmCapture(rate: Double) async throws {
        let format = try monoFormat(rate: rate)
        let worker = try AudioWorker(format: format)
        // Taps deliver ~100 ms packets despite a 512-frame request: 4,410 frames at 44.1 kHz on this Mac.
        let frames = AVAudioFrameCount(rate / 10)
        let buffer = try filledBuffer(format: format, frames: frames, value: 0.25)
        worker.receive(buffer)
        _ = try worker.begin(warm: true)
        let audio = try await worker.end()
        #expect(abs(audio.pcm.samples.count - 1600) <= 2)
        #expect(audio.pcm.samples.suffix(100).contains { abs($0) > 0.1 })
    }
}
@Suite struct LowLatencyCaptureTests {
    func feed(_ callback: AVAudioSinkNodeReceiverBlock, packets: Int, rate: Double, gapAfter: Int? = nil,
              gapFrames: Double = 512, from start: Double = 0) throws {
        let format = try monoFormat(rate: rate)
        let buffer = try filledBuffer(format: format, frames: 512, value: 0.2)
        var sample = start
        for packet in 0..<packets {
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = sample; stamp.mHostTime = AVAudioTime.hostTime(forSeconds: 10 + sample / rate)
            stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            _ = callback(&stamp, 512, buffer.audioBufferList)
            sample += packet == gapAfter ? 512 + gapFrames : 512
        }
    }
    @Test func ioCyclePacketsTrimToTheReleaseBoundary() async throws {
        let format = try monoFormat(rate: 44_100)
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        _ = try worker.begin(warm: false)
        // Ten 11.6 ms I/O cycles, as this Mac delivers; release 50 ms in.
        try feed(callback, packets: 10, rate: 44_100)
        let audio = try await worker.end(at: AVAudioTime.seconds(forHostTime: AVAudioTime.hostTime(forSeconds: 10.05)))
        #expect(abs(audio.pcm.samples.count - 800) <= 16)
        #expect(!audio.drainTimedOut)
    }
    @Test func shortMissingIOCycleSplicesButLongerLossFails() async throws {
        let format = try monoFormat(rate: 48_000)
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        _ = try worker.begin(warm: false)
        try feed(callback, packets: 6, rate: 48_000, gapAfter: 2)
        // Six packets joined across the 10.7 ms hole: nothing is inserted.
        let audio = try await worker.end()
        #expect(abs(audio.pcm.samples.count - 6 * 512 / 3) <= 16)
        let spliced = try #require(worker.lastReport)
        #expect(spliced.failure == nil && spliced.gaps == 1 && abs(spliced.gapMS - 10.67) < 0.01)
        // 104 ms is over the late-gap budget.
        let stalled = try AudioWorker(format: format, lowLatency: true)
        let stalledCallback = AudioTap(stalled).sinkCallback()
        _ = try stalled.begin(warm: false)
        try feed(stalledCallback, packets: 6, rate: 48_000, gapAfter: 2, gapFrames: 5_000)
        await #expect(throws: AppError.overflow) { try await stalled.end() }
        #expect(stalled.lastReport?.failure == .gap)
    }
    @Test func splicedGapKeepsTheReleaseTrimOnTheTimeline() async throws {
        let format = try monoFormat(rate: 44_100)
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        _ = try worker.begin(warm: false)
        // Release 50 ms in, with an 11.6 ms cycle lost before it: about 38.4 ms of audio, not 50.
        try feed(callback, packets: 10, rate: 44_100, gapAfter: 2)
        let audio = try await worker.end(at: AVAudioTime.seconds(forHostTime: AVAudioTime.hostTime(forSeconds: 10.05)))
        #expect(abs(audio.pcm.samples.count - 614) <= 16)
    }
    @Test func onDemandRestartStartsAFreshTimelineButAGapWithinARunStillFails() async throws {
        // Without the warm microphone the engine stops after each recording, and the next
        // start's I/O timestamps do not continue the last run's. A cycle skipped while the
        // device settles re-syncs; a stall after it (here about 320 ms in) is still lost audio.
        let format = try monoFormat(rate: 48_000)
        let worker = try AudioWorker(format: format, lowLatency: true)
        let tap = AudioTap(worker), callback = tap.sinkCallback()
        for (start, gap) in [(0.0, nil), (960_000, 1)] as [(Double, Int?)] {
            _ = try worker.begin(warm: false)
            try feed(callback, packets: 4, rate: 48_000, gapAfter: gap, from: start)
            let audio = try await worker.end()
            #expect(abs(audio.pcm.samples.count - 4 * 512 / 3) <= 16)
            tap.restart()
        }
        _ = try worker.begin(warm: false)
        try feed(callback, packets: 40, rate: 48_000, gapAfter: 30, gapFrames: 5_000, from: 2_000_000)
        await #expect(throws: AppError.overflow) { try await worker.end() }
    }
    @Test func reportSeparatesSettlingGapsFromALateGap() async throws {
        let format = try monoFormat(rate: 48_000)
        let worker = try AudioWorker(format: format, lowLatency: true)
        let tap = AudioTap(worker), callback = tap.sinkCallback()
        tap.restart()
        _ = try worker.begin(warm: false)
        try feed(callback, packets: 4, rate: 48_000, gapAfter: 1)
        _ = try await worker.end()
        let settled = try #require(worker.lastReport)
        #expect(settled.failure == nil && settled.settlingGaps == 1 && settled.gaps == 0 && settled.packets == 4)
        tap.restart()
        _ = try worker.begin(warm: false)
        try feed(callback, packets: 40, rate: 48_000, gapAfter: 30, from: 2_000_000)
        _ = try await worker.end()
        let late = try #require(worker.lastReport)
        #expect(late.failure == nil && late.gaps == 1 && late.settlingGaps == 0)
        #expect(abs(late.gapMS - 10.67) < 0.01)
        // 512 skipped frames at 48 kHz; the late packet starts 31 cycles plus the gap after the first.
        #expect(abs(late.largestGapMS - 10.67) < 0.01)
        #expect(abs((late.firstGapAtMS ?? 0) - 341.33) < 0.5)
        // Timings stay off unless the worker was prepared with debug logging.
        #expect(late.maxCallbackMS == nil && late.maxQueueDelayMS == nil)
    }
    @Test func measuredWorkerReportsCallbackAndQueueTimings() async throws {
        let format = try monoFormat(rate: 48_000)
        let worker = try AudioWorker(format: format, lowLatency: true, measured: true)
        let callback = AudioTap(worker).sinkCallback()
        _ = try worker.begin(warm: false)
        try feed(callback, packets: 4, rate: 48_000)
        _ = try await worker.end()
        let report = try #require(worker.lastReport)
        #expect(report.failure == nil && report.maxCallbackMS != nil && report.maxQueueDelayMS != nil)
    }
    @Test func smallSlotsStillAbsorbAWorkerStall() async throws {
        let format = try monoFormat(rate: 44_100)
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        _ = try worker.begin(warm: false)
        let gate = DispatchSemaphore(value: 0)
        worker.queue.async { gate.wait() }
        // About 1.4 s of I/O cycles while the worker is stalled.
        try feed(callback, packets: 120, rate: 44_100)
        gate.signal()
        let audio = try await worker.end()
        #expect(abs(audio.pcm.samples.count - 120 * 512 * 16_000 / 44_100) <= 16)
    }
}
@Suite struct AudioPoolTests {
    @Test func exhaustedPoolOverflowsWithoutBlockingAndReturnsEverySlot() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        let packet = try filledBuffer(format: format, frames: 320, value: 0)
        let gate = DispatchSemaphore(value: 0)
        worker.queue.async { gate.wait() }
        // 16 slots: the 17th callback finds none and returns at once rather than waiting.
        for _ in 0..<17 { worker.receive(packet) }
        gate.signal()
        #expect(throws: AppError.overflow) { try worker.begin(warm: false) }
        _ = try worker.begin(warm: false)
        for _ in 0..<40 { worker.receive(packet); worker.queue.sync {} }
        #expect(try await worker.end().pcm.samples.count == 12_800)
    }
    @Test func reportNamesDroppedPacketsAndAnEndWithoutRecording() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        let packet = try filledBuffer(format: format, frames: 320, value: 0)
        _ = try worker.begin(warm: false)
        let gate = DispatchSemaphore(value: 0)
        worker.queue.async { gate.wait() }
        for _ in 0..<17 { worker.receive(packet) }
        gate.signal()
        await #expect(throws: AppError.overflow) { try await worker.end() }
        let report = try #require(worker.lastReport)
        #expect(report.failure == .overflow && report.droppedPackets == 1 && report.packets == 16)
        await #expect(throws: AppError.capture) { try await worker.end() }
        #expect(worker.lastReport?.failure == .notRecording)
    }
}
@Suite struct AudioBoundaryTests {
    @Test func releaseInsideNextPacketIncludesOnlyTheFinalSamples() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        func packet(_ value: Float) throws -> AVAudioPCMBuffer {
            try filledBuffer(format: format, frames: 320, value: value)
        }
        _ = try worker.begin(warm: false)
        worker.receive(try packet(0.1), hostSeconds: 10)
        let finish = Task { try await worker.end(at: 10.025) }
        try await Task.sleep(for: .milliseconds(5))
        worker.receive(try packet(0.9), hostSeconds: 10.02)
        let result = try await finish.value
        #expect(result.pcm.samples.count == 400)
        #expect(result.pcm.samples.suffix(80).allSatisfy { abs($0 - 0.9) < 0.001 })
    }
    @Test func lateReleasePacketKeepsCapturedAudio() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        let packet = try filledBuffer(format: format, frames: 320, value: 0.3)
        _ = try worker.begin(warm: false)
        worker.receive(packet, hostSeconds: 10)
        // The packet covering the release never arrives: keep what was captured, flag the tail.
        let result = try await worker.end(at: 10.5)
        #expect(result.pcm.samples.count == 320)
        #expect(result.drainTimedOut)
        _ = try worker.begin(warm: false)
        worker.receive(packet)
        #expect(!(try await worker.end()).drainTimedOut)
    }
}
