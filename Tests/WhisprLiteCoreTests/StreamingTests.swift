import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@Suite struct StreamingTests {
    @Test func revisedSnapshotsOrderedFinishAuthoritativeAndCancelFinal() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let pipeline = StreamingPipeline(pipeline: BatchPipeline(backend: backend, cleanup: DemoCleanup()))
        try await pipeline.start()
        let chunk = try PCM16k([Float](repeating: 0, count: 320))
        #expect(try await pipeline.append(chunk)?.text == "Thursday")
        #expect(try await pipeline.append(chunk)?.text == "Friday.")
        let finalAudio = try PCM16k([Float](repeating: 0, count: 640))
        #expect(try await pipeline.finish(audio: finalAudio) == "Demo dictation. This is fabricated text.")
        await #expect(throws: AppError.protocolViolation) { try await pipeline.finish(audio: finalAudio) }
        let session = try await backend.makeSession()
        await #expect(throws: AppError.protocolViolation) { try await session.append(chunk, startingAt: 1) }
        await session.cancel()
        await #expect(throws: AppError.protocolViolation) { try await session.finish() }
    }
}
@Suite struct StreamingCancellationTests {
    @Test func streamingFallbackKeepsConfiguredBatchDeadline() async throws {
        var configuration = FakeASRConfiguration()
        configuration.inferenceDelay = .milliseconds(50)
        let backend = FakeASRBackend(configuration)
        try await backend.prepare()
        var batch = BatchPipeline(backend: backend, cleanup: DemoCleanup())
        batch.asrDeadline = .milliseconds(5)
        let pipeline = StreamingPipeline(pipeline: batch)
        try await pipeline.start()
        _ = try await pipeline.append(PCM16k([0.1]))
        await #expect(throws: AppError.deadline("ASR")) {
            try await pipeline.finish(audio: PCM16k([0.1]))
        }
    }

    @Test func retainedCaptureAudioIsAuthoritativeWhenChunkCountDiffers() async throws {
        let backend = FinishGatedBackend(gate: AsyncGate())
        let pipeline = StreamingPipeline(pipeline: BatchPipeline(backend: backend, cleanup: DemoCleanup()))
        try await pipeline.start()
        _ = try await pipeline.append(PCM16k([0.1]))
        #expect(try await pipeline.finish(audio: PCM16k([0.1, 0.2])) == "Synthetic words")
    }

    @Test func cancellationWhileFinishAwaitsSuppressesLateFinal() async throws {
        let gate = AsyncGate()
        let backend = FinishGatedBackend(gate: gate); try await backend.prepare()
        let pipeline = StreamingPipeline(pipeline: BatchPipeline(backend: backend, cleanup: DemoCleanup()))
        try await pipeline.start()
        _ = try await pipeline.append(PCM16k([0.1]))
        let final = Task { try await pipeline.finish(audio: PCM16k([0.1])) }
        await gate.waitUntilEntered()
        await pipeline.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await final.value }
    }
}

private actor FinishGatedBackend: ASRBackend {
    nonisolated let capabilities = ASRCapabilities(streaming: true)
    private let gate: AsyncGate
    init(gate: AsyncGate) { self.gate = gate }
    func prepare() async throws {}
    func readiness() async -> BackendReadiness { .ready }
    func transcribe(_ audio: PCM16k) async throws -> ASRResult { .init(text: "Synthetic words", audioDuration: audio.duration) }
    func makeSession() async throws -> any ASRSession { FinishGatedSession(gate: gate) }
}
private actor FinishGatedSession: ASRSession {
    private let gate: AsyncGate
    init(gate: AsyncGate) { self.gate = gate }
    func append(_ audio: PCM16k, startingAt offset: Int) async throws {}
    func partial() async throws -> PartialSnapshot? { nil }
    func finish() async throws -> ASRResult {
        await gate.enterAndWait()
        return .init(text: "Synthetic words", audioDuration: 0.1)
    }
    func cancel() async {}
}
@MainActor @Suite struct StreamingLifecycleTests {
    @Test func appDrainsFinalChunkReleasesMediaAndInsertsOnlyFinal() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let cleanup = CountingCleanup()
        let insertion = FakeInsertion(), media = FakeMedia()
        let coordinator = DictationCoordinator(capture: FakeStreamCapture(), insertion: insertion, media: media,
                                               pipeline: .init(backend: backend, cleanup: cleanup))
        coordinator.ready = true; coordinator.streamingEnabled = true
        coordinator.press(); coordinator.release()
        for _ in 0..<500 { if coordinator.state == .idle { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(insertion.texts == ["Demo dictation. This is fabricated text."])
        #expect(await cleanup.calls == 1)
        #expect(media.begins == media.ends)
    }

}
