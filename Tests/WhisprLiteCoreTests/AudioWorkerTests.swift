import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@Suite struct AudioTests {
    @Test func longCapturePublishesCompletedChunksWithoutChangingFinalAudio() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        guard case let .completed(stream) = try worker.begin(warm: false, earlyChunks: true) else {
            Issue.record("Expected completed-chunk stream"); return
        }
        let reader = Task { () throws -> [PCM16k] in
            var result: [PCM16k] = []
            for try await chunk in stream { result.append(chunk) }
            return result
        }
        let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200))
        packet.frameLength = 3200
        func feed(_ value: Float, packets: Int) {
            for index in 0..<3200 { packet.floatChannelData![0][index] = value }
            for _ in 0..<packets { worker.receive(packet); worker.queue.sync {} }
        }
        feed(0.2, packets: 50); feed(0, packets: 2)
        feed(0.3, packets: 50); feed(0, packets: 2)
        let full = try await worker.end()
        let chunks = try await reader.value
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { (10...15).contains($0.duration) })
        #expect(Array(full.pcm.samples.prefix(chunks.flatMap(\.samples).count)) == chunks.flatMap(\.samples))
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
              from start: Double = 0) throws {
        let format = try monoFormat(rate: rate)
        let buffer = try filledBuffer(format: format, frames: 512, value: 0.2)
        var sample = start
        for packet in 0..<packets {
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = sample; stamp.mHostTime = AVAudioTime.hostTime(forSeconds: 10 + sample / rate)
            stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            _ = callback(&stamp, 512, buffer.audioBufferList)
            sample += packet == gapAfter ? 1024 : 512
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
    @Test func missingIOCycleStillFailsInsteadOfSplicingAudio() async throws {
        let format = try monoFormat(rate: 48_000)
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        _ = try worker.begin(warm: false)
        try feed(callback, packets: 6, rate: 48_000, gapAfter: 2)
        await #expect(throws: AppError.overflow) { try await worker.end() }
    }
    @Test func onDemandRestartStartsAFreshTimelineButAGapWithinARunStillFails() async throws {
        // Without the warm microphone the engine stops after each recording, and the next
        // start's I/O timestamps do not continue the last run's. A cycle skipped while the
        // device settles re-syncs; one after it (here about 320 ms in) is still lost audio.
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
        try feed(callback, packets: 40, rate: 48_000, gapAfter: 30, from: 2_000_000)
        await #expect(throws: AppError.overflow) { try await worker.end() }
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
@Suite struct StreamingAudioTests {
    @Test func invalidStreamingChunkFinishesInsteadOfGrowing() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        guard case let .partial(stream) = try worker.begin(warm: false, streaming: true) else {
            Issue.record("Expected partial stream"); return
        }
        let buffer = try filledBuffer(format: format, frames: 640, value: .nan)
        worker.receive(buffer)
        worker.queue.sync {}
        _ = try? await worker.end()
        await #expect(throws: AppError.invalidAudio) { for try await _ in stream {} }
    }
    @Test func boundedSenderChunksMatchOwnedCaptureAndBackpressureKeepsBatchAudio() async throws {
        let format = try monoFormat()
        let worker = try AudioWorker(format: format)
        guard case let .partial(stream) = try worker.begin(warm: false, streaming: true) else {
            Issue.record("Expected partial stream"); return
        }
        let buffer = try filledBuffer(format: format, frames: 3200, value: 0.1)
        worker.receive(buffer)
        let audio = try await worker.end()
        var chunks: [Float] = []
        for try await chunk in stream { #expect(chunk.samples.count <= 640); chunks.append(contentsOf: chunk.samples) }
        #expect(chunks == audio.pcm.samples)
        guard case let .partial(overflow) = try worker.begin(warm: false, streaming: true) else {
            Issue.record("Expected partial stream"); return
        }
        // Four packets produce 20 chunks, exceeding the fixed 16-chunk sender buffer without a consumer.
        for _ in 0..<4 { worker.receive(buffer); worker.queue.sync {} }
        let retained = try await worker.end()
        #expect(retained.pcm.samples.count == 12_800)
        await #expect(throws: AppError.overflow) { for try await _ in overflow {} }
    }
}
