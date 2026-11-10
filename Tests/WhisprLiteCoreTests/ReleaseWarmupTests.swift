import Foundation
import Testing
@testable import WhisprLiteCore

private actor ReleaseGate {
    private var opened: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    init(opened: Bool = false) { self.opened = opened }
    func wait() async {
        entered = true
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
private actor ReleaseASR: HoldWarmableASRBackend {
    let gate: ReleaseGate
    let fails: Bool
    init(_ gate: ReleaseGate = .init(opened: true), fails: Bool = false) { self.gate = gate; self.fails = fails }
    func prepare() {}
    func readiness() -> BackendReadiness { .ready }
    func warmForRecording() {}
    func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        await gate.wait()
        try Task.checkCancellation()
        if fails { throw AppError.inference }
        return .init(text: "Raw synthetic words.", audioDuration: audio.duration)
    }
}
private actor ReleaseCleanup: ReleaseWarmableCleanup {
    let gate: ReleaseGate
    let fails: Bool
    private(set) var warmCalls = 0
    private(set) var warmSettled = 0
    private(set) var inputs: [String] = []
    private let cancellations = LockedCounter()
    init(_ gate: ReleaseGate = .init(opened: true), fails: Bool = false) { self.gate = gate; self.fails = fails }
    func warmForRelease() async throws {
        warmCalls += 1
        defer { warmSettled += 1 }
        let cancellations = self.cancellations
        try await withTaskCancellationHandler {
            await gate.wait()
            try Task.checkCancellation()
            if fails { throw CleanupFailure.connection }
        } onCancel: { cancellations.increment() }
    }
    func wasCancelled() -> Bool { cancellations.value > 0 }
    func clean(_ text: String) -> String { inputs.append(text); return "Cleaned synthetic words." }
}
@MainActor private final class ReleaseCapture: CaptureDriver {
    let audio: PCM16k
    var begins = 0
    init(seconds: Double = 2) throws { audio = try PCM16k([Float](repeating: 0, count: Int(seconds * Double(PCM16k.rate)))) }
    func begin() -> EarlyChunks? { begins += 1; return nil }
    func end(at boundary: Double?) async throws -> CapturedAudio { .init(pcm: audio) }
    func suspend() {}
}

@MainActor @Suite struct ReleaseWarmupTests {
    private func fixture(backend: any ASRBackend = ReleaseASR(), cleanup: ReleaseCleanup = .init(),
                         seconds: Double = 2, policy: CleanupPolicy = .required,
                         enabled: Bool = true) throws -> (DictationCoordinator, ReleaseCapture, FakeInsertion) {
        let capture = try ReleaseCapture(seconds: seconds), insertion = FakeInsertion()
        var pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        pipeline.cleanupPolicy = policy
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: FakeMedia(),
            pipeline: pipeline, timings: .init(enabled: true))
        coordinator.ready = true; coordinator.releaseWarmupEnabled = enabled
        coordinator.holdWarmupInterval = nil
        return (coordinator, capture, insertion)
    }
    @Test func warmupOverlapsFinalASRAndNeverBecomesAnInsertedResult() async throws {
        let asr = ReleaseGate(), warm = ReleaseGate(), cleanup = ReleaseCleanup(warm)
        let (coordinator, _, insertion) = try fixture(backend: ReleaseASR(asr), cleanup: cleanup)
        coordinator.press(); coordinator.release()
        try await poll {
            let asrEntered = await asr.entered, warmEntered = await warm.entered
            return asrEntered && warmEntered
        }
        #expect(await cleanup.inputs.isEmpty)
        await warm.open(); await asr.open()
        try await poll { coordinator.state == .idle }
        #expect(await cleanup.warmCalls == 1)
        #expect(await cleanup.warmSettled == 1)
        #expect(await cleanup.inputs == ["Raw synthetic words."])
        #expect(insertion.texts == ["Cleaned synthetic words."] && coordinator.recoveryText == insertion.texts.first)
        #expect(coordinator.timings.events.filter { $0.stage == .cleanupWarmupStart }.count == 1)
        #expect(coordinator.timings.events.filter { $0.stage == .cleanupWarmupEnd }.count == 1)
    }
    @Test func cancellationSettlesWarmupBeforeAllowingAnotherRecording() async throws {
        let asr = ReleaseGate(), warm = ReleaseGate(), cleanup = ReleaseCleanup(warm)
        let (coordinator, capture, insertion) = try fixture(backend: ReleaseASR(asr), cleanup: cleanup)
        coordinator.press(); coordinator.release()
        try await poll {
            let asrEntered = await asr.entered, warmEntered = await warm.entered
            return asrEntered && warmEntered
        }
        coordinator.cancel()
        #expect(await cleanup.wasCancelled())
        #expect(coordinator.isCancelling && coordinator.state == .processing)
        coordinator.press(); coordinator.release()
        #expect(capture.begins == 1 && insertion.texts.isEmpty)
        await asr.open(); await warm.open()
        try await poll { coordinator.state == .idle }
        #expect(await cleanup.warmSettled == 1)
        #expect(await cleanup.inputs.isEmpty)
        #expect(coordinator.recoveryText == nil)
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .idle }
        #expect(capture.begins == 2 && insertion.texts == ["Cleaned synthetic words."])
        #expect(await cleanup.warmCalls == 2)
        #expect(await cleanup.warmSettled == 2)
    }
    @Test func ASRFailureCancelsAndSettlesWarmupBeforeReportingTheFailure() async throws {
        let asr = ReleaseGate(), warm = ReleaseGate(), cleanup = ReleaseCleanup(warm)
        let (coordinator, _, insertion) = try fixture(backend: ReleaseASR(asr, fails: true), cleanup: cleanup)
        coordinator.press(); coordinator.release()
        try await poll {
            let asrEntered = await asr.entered, warmEntered = await warm.entered
            return asrEntered && warmEntered
        }
        await asr.open()
        try await poll { await cleanup.wasCancelled() }
        #expect(coordinator.state == .processing)
        await warm.open()
        try await poll { coordinator.state == .error }
        #expect(await cleanup.warmSettled == 1)
        #expect(await cleanup.inputs.isEmpty)
        #expect(insertion.texts.isEmpty && coordinator.recoveryText == nil)
    }
    @Test(arguments: [CleanupPolicy.required, .whenAvailable])
    func warmupFailureDoesNotChangeTheCleanupPolicy(policy: CleanupPolicy) async throws {
        let cleanup = ReleaseCleanup(fails: true)
        let (coordinator, _, insertion) = try fixture(cleanup: cleanup, policy: policy)
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .idle }
        #expect(await cleanup.warmCalls == 1)
        #expect(await cleanup.inputs == ["Raw synthetic words."])
        #expect(insertion.texts == ["Cleaned synthetic words."] && !coordinator.rawTranscriptionActive)
    }
    @Test(arguments: [(false, 2.0, CleanupPolicy.required), (true, 6.0, .required), (true, 2.0, .disabled)])
    func disabledOrLongRecordingsDoNotWarm(enabled: Bool, seconds: Double, policy: CleanupPolicy) async throws {
        let cleanup = ReleaseCleanup()
        let (coordinator, _, insertion) = try fixture(cleanup: cleanup, seconds: seconds, policy: policy, enabled: enabled)
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .idle }
        #expect(await cleanup.warmCalls == 0)
        #expect(insertion.texts == (policy == .disabled ? ["Raw synthetic words."] : ["Cleaned synthetic words."]))
    }
    @Test func HTTPOrDemoASRDoesNotStartReleaseWarmup() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let cleanup = ReleaseCleanup()
        let (coordinator, _, insertion) = try fixture(backend: backend, cleanup: cleanup)
        coordinator.press(); coordinator.release()
        try await poll { coordinator.state == .idle }
        #expect(await cleanup.warmCalls == 0)
        #expect(insertion.texts.count == 1)
    }
}
