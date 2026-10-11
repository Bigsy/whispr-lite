import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@MainActor @Suite struct LifecycleTests {
    @Test func longRecordingReusesEarlyCleanupAndInsertsOnce() async throws {
        let capture = EarlyCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let cleanup = RecordingCleanup()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: EarlyBackend(), cleanup: cleanup))
        coordinator.ready = true
        coordinator.press(); try capture.publish()
        try await poll { await cleanup.inputs.count == 1 }
        #expect(await cleanup.inputs == ["First sentence."])
        coordinator.release()
        try await poll { coordinator.state == .idle }
        #expect(await cleanup.inputs == ["First sentence.", "Second sentence."])
        #expect(insertion.texts == ["First sentence. Second sentence."])
        #expect(capture.ends == 1 && media.ends.count == 1)
    }
    @Test func cancellingDuringEarlyCleanupWaitsAndNeverInserts() async throws {
        let capture = EarlyCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let cleanup = RecordingCleanup(delay: .milliseconds(80))
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: EarlyBackend(), cleanup: cleanup))
        coordinator.ready = true
        coordinator.press(); try capture.publish()
        try await poll { await cleanup.started }
        #expect(await cleanup.started)
        coordinator.cancel()
        #expect(coordinator.isCancelling && coordinator.state == .processing)
        try await poll { coordinator.state == .idle }
        #expect(!coordinator.isCancelling)
        #expect(insertion.texts.isEmpty && capture.ends == 1 && media.ends.count == 1)
    }
    func fixture(_ config: FakeASRConfiguration = .init()) async throws -> (DictationCoordinator, FakeCapture, FakeInsertion, FakeMedia) {
        let capture = FakeCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let backend = FakeASRBackend(config); try await backend.prepare()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
                                               pipeline: .init(backend: backend, cleanup: DemoCleanup()))
        coordinator.ready = true
        return (coordinator, capture, insertion, media)
    }
    @Test func releaseFinalizesAndInsertsExactlyOnce() async throws {
        let (coordinator, capture, insertion, media) = try await fixture()
        coordinator.press()
        #expect(insertion.snapshots.count == 1)
        coordinator.press(); coordinator.release(); coordinator.release()
        try await poll { coordinator.state == .idle }
        #expect(capture.begins == 1 && capture.ends == 1)
        #expect(insertion.texts.count == 1)
        #expect(insertion.snapshots.count == 1)
        #expect(insertion.snapshots.first?.session == media.begins.first)
        #expect(insertion.insertedTargets == insertion.snapshots.map(\.target))
        #expect(media.begins == media.ends)
    }
    @Test func historySavesCompletedDictationButNotCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DictationHistory(directory: directory)
        history.configure(enabled: true, asr: "test", prompt: "")
        var config = FakeASRConfiguration(); config.inferenceDelay = .milliseconds(60)
        let (coordinator, _, insertion, _) = try await fixture(config)
        coordinator.history = history
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .idle }
        coordinator.press(); coordinator.release(); coordinator.cancel()
        try await poll { coordinator.state == .idle }
        try await Task.sleep(for: .milliseconds(100)) // Past the cancelled inference.
        await history.flush()
        let lines = try String(contentsOf: directory.appendingPathComponent(DictationHistory.fileName), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1 && insertion.texts.count == 1)
    }
    @Test func busyPressIsIgnoredThroughItsRelease() async throws {
        let (coordinator, capture, _, _) = try await fixture()
        coordinator.press(); coordinator.release(); coordinator.press()
        try await poll { coordinator.state == .idle }
        coordinator.release()
        #expect(capture.begins == 1)
    }
    @Test func cancelledLateCompletionCannotPasteAndMediaEndsBeforeInference() async throws {
        var config = FakeASRConfiguration(); config.ignoresCancellation = true; config.inferenceDelay = .milliseconds(150)
        let (coordinator, _, insertion, media) = try await fixture(config)
        coordinator.press(); coordinator.release()
        try await poll { media.ends.count == 1 }
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(180))
        #expect(insertion.texts.isEmpty)
        #expect(media.ends.count == 1)
        #expect(coordinator.state == .idle)
    }
    @Test func escapeRecordingAndRepeatedEndAreHarmless() async throws {
        let (coordinator, capture, insertion, media) = try await fixture()
        coordinator.press(); coordinator.cancel(); coordinator.release()
        try await poll { coordinator.state == .idle }
        #expect(capture.ends == 1 && media.ends.count == 1)
        #expect(insertion.texts.isEmpty)
    }
    @Test func suspendStopsCaptureAndPreventsNewRecording() async throws {
        let (coordinator, capture, insertion, media) = try await fixture()
        coordinator.press()
        coordinator.suspend()
        try await poll { coordinator.state == .idle }
        #expect(capture.suspended == 1 && capture.ends == 1)
        #expect(media.ends.count == 1 && insertion.texts.isEmpty)
        coordinator.press()
        #expect(capture.begins == 1)
    }
    @Test func ceilingFinalizesOnceAndOffersCopy() async throws {
        let (coordinator, capture, insertion, media) = try await fixture()
        coordinator.safetyDuration = .milliseconds(5)
        coordinator.press()
        try await poll { coordinator.state == .error }
        coordinator.release()
        #expect(capture.ends == 1 && media.ends.count == 1)
        #expect(insertion.texts.isEmpty)
        #expect(coordinator.recoveryText != nil)
    }
    @Test func releaseReadsCaptureBoundaryBeforeProcessing() async throws {
        let (coordinator, capture, insertion, _) = try await fixture()
        capture.boundaryValue = 123.45
        capture.onBoundary = { #expect(coordinator.state == .recording) }
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .idle && insertion.texts.count == 1 }
        #expect(capture.endBoundary == 123.45)
    }
    @Test func copyOnlyWithEarlyChunksDismissesStraightToIdle() async throws {
        let capture = EarlyCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: EarlyBackend(), cleanup: DemoCleanup()))
        coordinator.ready = true; coordinator.holdWarmupInterval = nil
        coordinator.safetyDuration = .milliseconds(30)
        coordinator.press()
        try capture.publish()
        try await poll { coordinator.state == .error }
        #expect(coordinator.message.contains("Copy the result"))
        #expect(coordinator.recoveryText != nil && insertion.texts.isEmpty)
        coordinator.cancel()
        #expect(coordinator.state == .idle)
        #expect(coordinator.message == "Ready")
        #expect(media.ends.count == 1)
    }
    @Test func notReadyPressExplainsInsteadOfSilentlySwallowing() async throws {
        let (coordinator, capture, _, _) = try await fixture()
        coordinator.ready = false
        coordinator.press(); coordinator.release()
        #expect(coordinator.state == .error && capture.begins == 0)
        #expect(coordinator.message.contains("isn't ready"))
        coordinator.ready = true
        coordinator.press()
        #expect(coordinator.state == .recording)
    }
    @Test func escapeWhileIdleChangesNothing() async throws {
        let (coordinator, _, _, _) = try await fixture()
        var changes = 0
        coordinator.onChange = { changes += 1 }
        coordinator.cancel(); coordinator.cancel()
        #expect(changes == 0 && coordinator.state == .idle)
        coordinator.ready = false; coordinator.press()
        #expect(coordinator.state == .error)
        coordinator.cancel()
        #expect(coordinator.state == .idle)
    }
    @Test func captureStartsBeforeTargetSnapshot() async throws {
        let capture = FakeCapture(), media = FakeMedia()
        let insertion = OrderedInsertion(capture)
        let backend = FakeASRBackend(); try await backend.prepare()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
                                               pipeline: .init(backend: backend, cleanup: DemoCleanup()))
        coordinator.ready = true
        coordinator.press()
        #expect(insertion.beginsAtSnapshot == [1])
        coordinator.cancel()
    }
    @Test func targetFailureKeepsRecoveryText() async throws {
        let (coordinator, _, insertion, _) = try await fixture()
        insertion.shouldFail = true
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .error }
        #expect(coordinator.recoveryText != nil && insertion.texts.isEmpty)
    }
    @Test func holdWarmupRepeatsWhileHeldAndStopsAtRelease() async throws {
        let backend = WarmupBackend(), capture = FakeCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: backend, cleanup: DemoCleanup()))
        coordinator.ready = true; coordinator.holdWarmupInterval = .milliseconds(10)
        coordinator.press()
        try await Task.sleep(for: .milliseconds(300))
        coordinator.release()
        try await poll { coordinator.state == .idle && insertion.texts.count == 1 }
        let held = await backend.warmCalls
        #expect(held >= 2)
        #expect(await backend.finalBeforeWarmSettled == false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await backend.warmCalls == held)
        coordinator.holdWarmupInterval = nil
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .idle && insertion.texts.count == 2 }
        #expect(await backend.warmCalls == held)
    }
    @Test func cancelledHoldWarmupSettlesBeforeNextFinalASR() async throws {
        let gate = AsyncGate()
        let backend = WarmupBackend(warmGate: gate), capture = FakeCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: backend, cleanup: DemoCleanup()))
        coordinator.ready = true
        coordinator.press()
        await gate.waitUntilEntered()
        coordinator.cancel()
        try await poll { coordinator.state == .idle }
        coordinator.press(); coordinator.release()
        await gate.open()
        try await poll { coordinator.state == .idle && insertion.texts.count == 1 }
        await coordinator.settleBackendWork()
        #expect(await backend.warmCalls == 1)
        #expect(await backend.finalBeforeWarmSettled == false)
        #expect(insertion.texts == ["Synthetic words"])
    }
    @Test func holdWarmupRestartsAfterAnEarlyChunk() async throws {
        let backend = WarmupBackend(), capture = EarlyCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: backend, cleanup: DemoCleanup()))
        coordinator.ready = true; coordinator.holdWarmupInterval = .seconds(2)
        coordinator.press()
        try await poll { await backend.warmCalls >= 1 }
        #expect(await backend.warmCalls == 1)
        try capture.publish()
        try await poll { await backend.warmCalls >= 2 }
        #expect(await backend.warmCalls >= 2)
        coordinator.release()
        try await poll { coordinator.state == .idle && insertion.texts.count == 1 }
        #expect(await backend.transcribedWhileWarming == false)
    }
}
