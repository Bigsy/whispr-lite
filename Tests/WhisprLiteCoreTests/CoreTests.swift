import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@Suite struct BackendTests {
    @Test func pcmValidatesFiniteAndLimit() throws {
        #expect(throws: AppError.invalidAudio) { try PCM16k([.nan]) }
        #expect(throws: AppError.audioLimit) { try PCM16k([Float](repeating: 0, count: PCM16k.maximumSamples + 1)) }
        #expect(try PCM16k([1.5, -2]).samples == [1.5, -2])
        #expect(try PCM16k([]).duration == 0)
    }
    @Test func fakeRequiresPreparationAndReturnsActualDuration() async throws {
        let fake = FakeASRBackend()
        await #expect(throws: AppError.notReady) { try await fake.transcribe(PCM16k([0])) }
        try await fake.prepare()
        #expect(await fake.readiness() == .ready)
        #expect(try await fake.transcribe(PCM16k([Float](repeating: 0, count: 100))).audioDuration == 0.00625)
    }
    @Test func wavAndMultipartHaveRealContainerAndCorrectLengths() throws {
        let pcm = try PCM16k([-1, 0, 1])
        let wav = WAVEncoder.encode(pcm)
        #expect(wav.count == 50)
        #expect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        #expect(Array(wav.suffix(6)) == [1, 128, 0, 0, 255, 127])
        let request = HTTPASRBackend.request(audio: pcm, endpoint: try LocalEndpoint("http://127.0.0.1:11435"), boundary: "fixture")
        #expect(request.url?.path == "/v1/audio/transcriptions")
        #expect(request.httpBody!.range(of: wav) != nil)
        #expect(request.httpBody!.suffix(13) == Data("--fixture--\r\n".utf8))
    }
    @Test func cleanupRequestIsDeterministicAndRejectsOverflow() throws {
        let cleanup = HTTPCleanup(.init(endpoint: try LocalEndpoint("http://127.0.0.1:11434"), prompt: "Synthetic prompt", dictionary: "Parakeet"))
        let request = try cleanup.request("hello")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["temperature"] as? Int == 0)
        #expect(body["max_tokens"] as? Int == 512)
        let bounded = try #require(JSONSerialization.jsonObject(with: cleanup.request("hello", maxTokens: 128).httpBody!) as? [String: Any])
        #expect(bounded["max_tokens"] as? Int == 128)
        // Proportional output: short input is capped tight, a long dictation gets more than 512.
        #expect(HTTPCleanup.outputLimit(for: "send it by friday") == 128)
        #expect(HTTPCleanup.outputLimit(for: String(repeating: "word ", count: 300)) == 814)
        #expect(HTTPCleanup.outputLimit(for: String(repeating: "x", count: 4000)) == 1024)
        #expect(body["stream"] as? Bool == false)
        #expect((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
        #expect(throws: AppError.contextLimit) { try cleanup.request(String(repeating: "x", count: 16_384)) }
        #expect(throws: AppError.unsupported) { try LocalEndpoint("https://example.org") }
        #expect(throws: AppError.unsupported) { try LocalEndpoint("http://user:secret@localhost:11434") }
    }
    @Test func emptySkipsCleanupAndFailuresPreserveRaw() async throws {
        var config = FakeASRConfiguration(); config.text = " \n"
        let empty = FakeASRBackend(config); try await empty.prepare()
        let counter = CountingCleanup()
        #expect(try await BatchPipeline(backend: empty, cleanup: counter).run(PCM16k([0])) == nil)
        #expect(await counter.calls == 0)
        config.text = "synthetic raw"
        let fake = FakeASRBackend(config); try await fake.prepare()
        do {
            _ = try await BatchPipeline(backend: fake, cleanup: FailingCleanup()).run(PCM16k([0]))
            Issue.record("Expected cleanup failure")
        } catch let error as PipelineFailure { #expect(error.rawText == "synthetic raw") }
    }
    @Test func deadlineDoesNotWaitForIgnoringWorker() async throws {
        let start = ContinuousClock.now
        await #expect(throws: AppError.deadline("ASR")) {
            try await withDeadline(.milliseconds(5), stage: "ASR") {
                await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value
                return "late"
            }
        }
        #expect(start.duration(to: .now) < .milliseconds(150))
    }
    @Test func cancellingDeadlineReturnsImmediately() async throws {
        let task = Task {
            try await withDeadline(.seconds(5), stage: "test") {
                await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                return 1
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
actor CountingCleanup: TextCleanup {
    var calls = 0
    func clean(_ text: String) -> String { calls += 1; return text }
}
actor RecordingCleanup: TextCleanup {
    var inputs: [String] = []
    func clean(_ text: String) -> String { inputs.append(text); return text }
}
actor SlowRecordingCleanup: TextCleanup {
    var started = false
    func clean(_ text: String) async throws -> String {
        started = true
        try await Task.sleep(for: .milliseconds(80))
        return text
    }
}
struct FailingCleanup: TextCleanup { func clean(_ text: String) throws -> String { throw AppError.cleanup } }

@MainActor final class FakeCapture: CaptureDriver {
    var begins = 0; var ends = 0; var suspended = 0
    func begin() { begins += 1 }
    func end() async throws -> PCM16k { ends += 1; return try PCM16k([0.1]) }
    func suspend() { suspended += 1 }
}
@MainActor final class EarlyCapture: CaptureDriver {
    var ends = 0
    private var stream: AsyncThrowingStream<PCM16k, any Error>?
    private var continuation: AsyncThrowingStream<PCM16k, any Error>.Continuation?
    func begin() {
        let pair = AsyncThrowingStream<PCM16k, any Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    func completedChunks() -> AsyncThrowingStream<PCM16k, any Error>? { stream }
    func publish() throws { continuation?.yield(try PCM16k([0.1])) }
    func end() throws -> PCM16k { ends += 1; continuation?.finish(); return try PCM16k([0.1, 0.2]) }
    func suspend() {}
}
private actor EarlyBackend: ASRBackend {
    nonisolated let capabilities = ASRCapabilities()
    func prepare() async throws {}
    func readiness() async -> BackendReadiness { .ready }
    func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        .init(text: audio.samples.count == 1 ? "First sentence." : "First sentence. Second sentence.", audioDuration: audio.duration)
    }
}
@MainActor final class FakeInsertion: InsertionDriver {
    var texts: [String] = []; var shouldFail = false
    func snapshot() -> UUID { UUID() }
    func insert(_ text: String, target: UUID) throws {
        try Task.checkCancellation()
        if shouldFail { throw AppError.targetChanged }
        texts.append(text)
    }
}
@MainActor final class OrderedInsertion: InsertionDriver {
    let capture: FakeCapture; var beginsAtSnapshot: [Int] = []
    init(_ capture: FakeCapture) { self.capture = capture }
    func snapshot() -> UUID { beginsAtSnapshot.append(capture.begins); return UUID() }
    func insert(_ text: String, target: UUID) throws {}
}
@MainActor final class FakeMedia: MediaDriver {
    var begins: [UUID] = []; var ends: [UUID] = []
    func begin(_ session: UUID) { begins.append(session) }
    func end(_ session: UUID) { ends.append(session) }
}
private actor WarmupBackend: PressWarmableASRBackend {
    nonisolated let capabilities = ASRCapabilities()
    private(set) var warmCalls = 0
    private(set) var finalBeforeWarmSettled = false
    private var warmSettled = false
    func prepare() async throws {}
    func readiness() async -> BackendReadiness { .ready }
    func warmForRecording() async throws {
        warmCalls += 1
        try await Task.sleep(for: .milliseconds(80))
        warmSettled = true
    }
    func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        if !warmSettled { finalBeforeWarmSettled = true }
        return .init(text: "Synthetic words", audioDuration: audio.duration)
    }
}
@MainActor @Suite struct LifecycleTests {
    @Test func longRecordingReusesEarlyCleanupAndInsertsOnce() async throws {
        let capture = EarlyCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let cleanup = RecordingCleanup()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: EarlyBackend(), cleanup: cleanup))
        coordinator.ready = true
        coordinator.press(); try capture.publish()
        for _ in 0..<500 {
            if await cleanup.inputs.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await cleanup.inputs == ["First sentence."])
        coordinator.release()
        try await waitUntil { coordinator.state == .idle }
        #expect(await cleanup.inputs == ["First sentence.", "Second sentence."])
        #expect(insertion.texts == ["First sentence. Second sentence."])
        #expect(capture.ends == 1 && media.ends.count == 1)
    }
    @Test func cancellingDuringEarlyCleanupWaitsAndNeverInserts() async throws {
        let capture = EarlyCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let cleanup = SlowRecordingCleanup()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: EarlyBackend(), cleanup: cleanup))
        coordinator.ready = true
        coordinator.press(); try capture.publish()
        for _ in 0..<500 {
            if await cleanup.started { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await cleanup.started)
        coordinator.cancel()
        try await waitUntil { coordinator.state == .idle }
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
    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        Issue.record("Lifecycle did not settle")
    }
    @Test func releaseFinalizesAndInsertsExactlyOnce() async throws {
        let (coordinator, capture, insertion, media) = try await fixture()
        coordinator.press(); coordinator.press(); coordinator.release(); coordinator.release()
        try await waitUntil { coordinator.state == .idle }
        #expect(capture.begins == 1 && capture.ends == 1)
        #expect(insertion.texts.count == 1)
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
        try await waitUntil { coordinator.state == .idle }
        coordinator.press(); coordinator.release(); coordinator.cancel()
        try await waitUntil { coordinator.state == .idle }
        try await Task.sleep(for: .milliseconds(100)) // Past the cancelled inference.
        await history.flush()
        let lines = try String(contentsOf: directory.appendingPathComponent(DictationHistory.fileName), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1 && insertion.texts.count == 1)
    }
    @Test func busyPressIsIgnoredThroughItsRelease() async throws {
        let (coordinator, capture, _, _) = try await fixture()
        coordinator.press(); coordinator.release(); coordinator.press()
        try await waitUntil { coordinator.state == .idle }
        coordinator.release()
        #expect(capture.begins == 1)
    }
    @Test func cancelledLateCompletionCannotPasteAndMediaEndsBeforeInference() async throws {
        var config = FakeASRConfiguration(); config.ignoresCancellation = true; config.inferenceDelay = .milliseconds(150)
        let (coordinator, _, insertion, media) = try await fixture(config)
        coordinator.press(); coordinator.release()
        try await waitUntil { media.ends.count == 1 }
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(180))
        #expect(insertion.texts.isEmpty)
        #expect(media.ends.count == 1)
        #expect(coordinator.state == .idle)
    }
    @Test func escapeRecordingAndRepeatedEndAreHarmless() async throws {
        let (coordinator, capture, insertion, media) = try await fixture()
        coordinator.press(); coordinator.cancel(); coordinator.release()
        try await waitUntil { coordinator.state == .idle }
        #expect(capture.ends == 1 && media.ends.count == 1)
        #expect(insertion.texts.isEmpty)
    }
    @Test func ceilingFinalizesOnceAndOffersCopy() async throws {
        let (coordinator, capture, insertion, media) = try await fixture()
        coordinator.safetyDuration = .milliseconds(5)
        coordinator.press()
        try await waitUntil { coordinator.state == .error }
        coordinator.release()
        #expect(capture.ends == 1 && media.ends.count == 1)
        #expect(insertion.texts.isEmpty)
        #expect(coordinator.recoveryText != nil)
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
        try await waitUntil { coordinator.state == .error }
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
        try await waitUntil { coordinator.state == .idle && insertion.texts.count == 1 }
        let held = await backend.warmCalls
        #expect(held >= 2)
        #expect(await backend.finalBeforeWarmSettled == false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await backend.warmCalls == held)
        coordinator.holdWarmupInterval = nil
        coordinator.press(); coordinator.release()
        try await waitUntil { coordinator.state == .idle && insertion.texts.count == 2 }
        #expect(await backend.warmCalls == held)
    }
    @Test func cancelledPressWarmupSettlesBeforeNextFinalASR() async throws {
        let backend = WarmupBackend(), capture = FakeCapture(), insertion = FakeInsertion(), media = FakeMedia()
        let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: media,
            pipeline: .init(backend: backend, cleanup: DemoCleanup()))
        coordinator.ready = true
        coordinator.press(); coordinator.cancel()
        try await waitUntil { coordinator.state == .idle }
        coordinator.press(); coordinator.release()
        try await waitUntil { coordinator.state == .idle && insertion.texts.count == 1 }
        await coordinator.settlePressWarmup()
        #expect(await backend.warmCalls == 1)
        #expect(await backend.finalBeforeWarmSettled == false)
        #expect(insertion.texts == ["Synthetic words"])
    }
}

@Suite struct HotkeyTests {
    @Test func fnShortcutPassesThroughAndCancelsRecording() {
        var machine = HotkeyMachine(.init())
        #expect(machine.consume(.init(.flags, code: 63, flags: HotkeyMachine.fnMask)).0 == .press)
        let shortcut = machine.consume(.init(.down, code: 123, flags: HotkeyMachine.fnMask))
        #expect(shortcut.0 == .cancel && !shortcut.1)
        #expect(machine.consume(.init(.flags, code: 63)).0 == nil)
    }
    @Test func repeatInjectedAndModifierChangesDoNotRetrigger() {
        var machine = HotkeyMachine(.init(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue))
        #expect(machine.consume(.init(.down, code: 49, flags: CGEventFlags.maskControl.rawValue, injected: true)).0 == nil)
        #expect(machine.consume(.init(.down, code: 49, flags: CGEventFlags.maskControl.rawValue)).0 == .press)
        #expect(machine.consume(.init(.down, code: 49, flags: CGEventFlags.maskControl.rawValue, repeated: true)).0 == nil)
        #expect(machine.consume(.init(.up, code: 49)).0 == .release)
    }
}
@MainActor final class MemoryClipboard: ClipboardAccess {
    var changeCount = 0; var text: String? = "original"
    var content = ClipboardSnapshot(items: [["text": Data("original".utf8)], ["image": Data([1, 2, 3])]])
    func snapshot() -> ClipboardSnapshot { content }
    var reader: (@MainActor () -> Void)?
    func write(_ text: String) { self.text = text; changeCount += 1 }
    func write(_ text: String, onRead: @escaping @MainActor () -> Void) { write(text); reader = onRead }
    func restore(_ snapshot: ClipboardSnapshot) { content = snapshot; text = "restored"; changeCount += 1 }
}
@MainActor @Suite struct ClipboardTests {
    @Test func newerCopyWinsEvenIfItHasSameText() throws {
        let clipboard = MemoryClipboard(), transaction = ClipboardTransaction(MemoryClipboard())
        _ = transaction
        let owner = ClipboardTransaction(clipboard)
        try owner.write("dictation"); clipboard.write("dictation")
        owner.settle()
        #expect(clipboard.text == "dictation")
    }
    @Test func consecutiveTransactionsPreserveOriginalRichItems() throws {
        let clipboard = MemoryClipboard(); let original = clipboard.content
        let owner = ClipboardTransaction(clipboard)
        try owner.write("first"); try owner.write("second"); owner.settle()
        #expect(clipboard.content == original)
        #expect(clipboard.changeCount == 4)
    }
    @Test func targetReadRestoresAfterGraceNotTheFallbackTimeout() async throws {
        let clipboard = MemoryClipboard(); let original = clipboard.content
        let owner = ClipboardTransaction(clipboard)
        try owner.write("result", delay: .seconds(30), afterRead: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(20))
        #expect(clipboard.text == "result")
        clipboard.reader?()
        for _ in 0..<200 where clipboard.text != "restored" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clipboard.content == original && clipboard.text == "restored")
        // A stale read callback from an earlier transaction cannot restore a newer one early.
        let stale = clipboard.reader
        try owner.write("second", delay: .seconds(30), afterRead: .milliseconds(5))
        stale?()
        try await Task.sleep(for: .milliseconds(30))
        #expect(clipboard.text == "second")
        owner.settle()
    }
    @Test func cancelledDelayedRestoreCannotClobberNewCopy() async throws {
        let clipboard = MemoryClipboard(); let owner = ClipboardTransaction(clipboard)
        try owner.write("result", delay: .milliseconds(5)); clipboard.write("user copy")
        try await Task.sleep(for: .milliseconds(20))
        #expect(clipboard.text == "user copy")
    }
}
@Suite struct ProtocolTests {
    @Test func fragmentsAndOversizeMalformedOrOldSchema() throws {
        var decoder = JSONLineDecoder()
        let line = Data("{\"version\":1,\"type\":\"ready\",\"generation\":\"g\",\"request\":\"\",\"session\":\"\"}\n".utf8)
        #expect(try decoder.append(line.prefix(9)).isEmpty)
        #expect(try decoder.append(line.dropFirst(9)).count == 1)
        try decoder.finish()
        #expect(throws: (any Error).self) { try decoder.append(Data("nope\n".utf8)) }
        var huge = JSONLineDecoder()
        #expect(throws: AppError.protocolViolation) { try huge.append(Data(repeating: 65, count: 8193)) }
        var unfinished = JSONLineDecoder(); _ = try unfinished.append(Data("{".utf8))
        #expect(throws: AppError.protocolViolation) { try unfinished.finish() }
    }
}
@Suite struct AudioTests {
    @Test func longCapturePublishesCompletedChunksWithoutChangingFinalAudio() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        try worker.begin(warm: false, earlyChunks: true)
        let stream = try #require(worker.completedChunks())
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
        #expect(Array(full.samples.prefix(chunks.flatMap(\.samples).count)) == chunks.flatMap(\.samples))
    }
    @MainActor @Test func engineTapCallbackRunsOffMainActorWithOwnedAudio() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        try worker.begin(warm: false)
        // Construct the production tap on MainActor, invoke it as AVAudioEngine does.
        let callback = AudioTap(worker).callback()
        try await Task.detached {
            #expect(pthread_main_np() == 0)
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
            buffer.frameLength = 320
            for i in 0..<320 { buffer.floatChannelData![0][i] = 0.25 }
            callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            // Source buffers can be reused as soon as the callback returns.
            for i in 0..<320 { buffer.floatChannelData![0][i] = 0 }
        }.value
        let result = try await worker.end()
        #expect(result.samples.count == 320)
        #expect(result.samples.allSatisfy { abs($0 - 0.25) < 0.001 })
    }
    @Test(arguments: [16_000.0, 44_100.0, 48_000.0]) func conversionPreservesTailAndDuration(rate: Double) async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let worker = try AudioWorker(format: format)
        try worker.begin(warm: false)
        // 40 ms, with an audible ending marker; no hardware/microphone permission.
        let frames = Int(rate * 0.04)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        for channel in 0..<2 { for i in 0..<frames { buffer.floatChannelData![channel][i] = i >= frames - Int(rate * 0.01) ? 0.5 : 0 } }
        worker.receive(buffer)
        let result = try await worker.end()
        #expect(abs(result.samples.count - 640) <= 2)
        #expect(result.samples.suffix(80).contains { abs($0) > 0.1 })
    }
    @Test func warmPrerollIsBoundedAndNotDuplicated() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200)); buffer.frameLength = 3200
        for i in 0..<3200 { buffer.floatChannelData![0][i] = 0.1 }
        worker.receive(buffer)
        try worker.begin(warm: true)
        let result = try await worker.end()
        #expect(result.samples.count == 2400)
        try worker.begin(warm: true)
        #expect(try await worker.end().samples.isEmpty)
    }
    @Test(arguments: [44_100.0, 96_000.0, 192_000.0]) func hardwareSizedInputPacketDoesNotOverflowWarmCapture(rate: Double) async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        // Taps deliver ~100 ms packets despite a 512-frame request: 4,410 frames at 44.1 kHz on this Mac.
        let frames = AVAudioFrameCount(rate / 10)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.25 }
        worker.receive(buffer)
        try worker.begin(warm: true)
        let audio = try await worker.end()
        #expect(abs(audio.samples.count - 1600) <= 2)
        #expect(audio.samples.suffix(100).contains { abs($0) > 0.1 })
    }
}
@Suite struct EarlyCleanupTests {
    @Test func completedSentenceReusesCleanupAndOnlyCleansTail() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let cleanup = RecordingCleanup()
        let pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        let early = [DictationText(raw: "First sentence.", cleaned: "First sentence.")]
        let result = try await pipeline.finish("First sentence. Second sentence.", early: early)
        #expect(result.cleaned == "First sentence. Second sentence.")
        #expect(await cleanup.inputs == ["Second sentence."])
    }
    @Test func mismatchOrUnfinishedSentenceFallsBackToFullCleanup() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let cleanup = RecordingCleanup()
        let pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        let mismatch = [DictationText(raw: "First mistake.", cleaned: "First mistake.")]
        let unfinished = [DictationText(raw: "First sentence", cleaned: "First sentence")]
        _ = try await pipeline.finish("First sentence. Second sentence.", early: mismatch)
        _ = try await pipeline.finish("First sentence. Second sentence.", early: unfinished)
        #expect(await cleanup.inputs == ["First sentence. Second sentence.", "First sentence. Second sentence."])
    }
}
@Suite struct LowLatencyCaptureTests {
    func feed(_ callback: AVAudioSinkNodeReceiverBlock, packets: Int, rate: Double, gapAfter: Int? = nil) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)); buffer.frameLength = 512
        for i in 0..<512 { buffer.floatChannelData![0][i] = 0.2 }
        var sample = 0.0
        for packet in 0..<packets {
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = sample; stamp.mHostTime = AVAudioTime.hostTime(forSeconds: 10 + sample / rate)
            stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            _ = callback(&stamp, 512, buffer.audioBufferList)
            sample += packet == gapAfter ? 1024 : 512
        }
    }
    @Test func ioCyclePacketsTrimToTheReleaseBoundary() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        try worker.begin(warm: false)
        // Ten 11.6 ms I/O cycles, as this Mac delivers; release 50 ms in.
        try feed(callback, packets: 10, rate: 44_100)
        let audio = try await worker.end(at: AVAudioTime.seconds(forHostTime: AVAudioTime.hostTime(forSeconds: 10.05)))
        #expect(abs(audio.samples.count - 800) <= 16)
        #expect(!worker.lastDrainTimedOut())
    }
    @Test func missingIOCycleStillFailsInsteadOfSplicingAudio() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        try worker.begin(warm: false)
        try feed(callback, packets: 6, rate: 48_000, gapAfter: 2)
        await #expect(throws: AppError.overflow) { try await worker.end() }
    }
    @Test func smallSlotsStillAbsorbAWorkerStall() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format, lowLatency: true)
        let callback = AudioTap(worker).sinkCallback()
        try worker.begin(warm: false)
        let gate = DispatchSemaphore(value: 0)
        worker.queue.async { gate.wait() }
        // About 1.4 s of I/O cycles while the worker is stalled.
        try feed(callback, packets: 120, rate: 44_100)
        gate.signal()
        let audio = try await worker.end()
        #expect(abs(audio.samples.count - 120 * 512 * 16_000 / 44_100) <= 16)
    }
}
@Suite struct AudioPoolTests {
    @Test func exhaustedPoolOverflowsWithoutBlockingAndReturnsEverySlot() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)); packet.frameLength = 320
        let gate = DispatchSemaphore(value: 0)
        worker.queue.async { gate.wait() }
        // 16 slots: the 17th callback finds none and returns at once rather than waiting.
        for _ in 0..<17 { worker.receive(packet) }
        gate.signal()
        #expect(throws: AppError.overflow) { try worker.begin(warm: false) }
        try worker.begin(warm: false)
        for _ in 0..<40 { worker.receive(packet); worker.queue.sync {} }
        #expect(try await worker.end().samples.count == 12_800)
    }
}
@Suite struct StreamingTests {
    @Test func revisedSnapshotsOrderedFinishAuthoritativeAndCancelFinal() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let pipeline = StreamingPipeline(backend: backend); try await pipeline.start()
        let chunk = try PCM16k([Float](repeating: 0, count: 320))
        #expect(try await pipeline.append(chunk)?.text == "Thursday")
        #expect(try await pipeline.append(chunk)?.text == "Friday.")
        #expect(try await pipeline.finish(cleanup: DemoCleanup()) == "Demo dictation. This is fabricated text.")
        await #expect(throws: AppError.protocolViolation) { try await pipeline.finish(cleanup: DemoCleanup()) }
        let session = try await backend.makeSession()
        await #expect(throws: AppError.protocolViolation) { try await session.append(chunk, startingAt: 1) }
        await session.cancel()
        await #expect(throws: AppError.protocolViolation) { try await session.finish() }
    }
}

@Suite struct AudioBoundaryTests {
    @Test func releaseInsideNextPacketIncludesOnlyTheFinalSamples() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        func packet(_ value: Float) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)); buffer.frameLength = 320
            for i in 0..<320 { buffer.floatChannelData![0][i] = value }
            return buffer
        }
        try worker.begin(warm: false)
        worker.receive(try packet(0.1), hostSeconds: 10)
        let finish = Task { try await worker.end(at: 10.025) }
        try await Task.sleep(for: .milliseconds(5))
        worker.receive(try packet(0.9), hostSeconds: 10.02)
        let result = try await finish.value
        #expect(result.samples.count == 400)
        #expect(result.samples.suffix(80).allSatisfy { abs($0 - 0.9) < 0.001 })
    }
    @Test func lateReleasePacketKeepsCapturedAudio() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)); packet.frameLength = 320
        for i in 0..<320 { packet.floatChannelData![0][i] = 0.3 }
        try worker.begin(warm: false)
        worker.receive(packet, hostSeconds: 10)
        // The packet covering the release never arrives: keep what was captured, flag the tail.
        let result = try await worker.end(at: 10.5)
        #expect(result.samples.count == 320)
        #expect(worker.lastDrainTimedOut())
        try worker.begin(warm: false)
        worker.receive(packet)
        _ = try await worker.end()
        #expect(!worker.lastDrainTimedOut())
    }
}

@Suite struct StreamingCancellationTests {
    @Test func cancellationWhileFinishAwaitsSuppressesLateFinal() async throws {
        var configuration = FakeASRConfiguration(); configuration.inferenceDelay = .milliseconds(100)
        let backend = FakeASRBackend(configuration); try await backend.prepare()
        let pipeline = StreamingPipeline(backend: backend); try await pipeline.start()
        _ = try await pipeline.append(PCM16k([0.1]))
        let final = Task { try await pipeline.finish(cleanup: DemoCleanup()) }
        try await Task.sleep(for: .milliseconds(5))
        await pipeline.cancel()
        await #expect(throws: CancellationError.self) { try await final.value }
    }
}

@Suite struct AdditionalHotkeyTests {
    @Test func modifierOnlyAndFnModifierShortcutsKeepOrdinaryShortcuts() {
        let modifiers = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        var machine = HotkeyMachine(.init(modifiers: modifiers))
        #expect(machine.consume(.init(.flags, code: 59, flags: modifiers)).0 == .press)
        #expect(machine.consume(.init(.down, code: 1, flags: modifiers)).0 == .cancel)
        #expect(machine.consume(.init(.flags, code: 59)).0 == nil)
        #expect(machine.consume(.init(.flags, code: 59, flags: modifiers)).0 == .press)
        var fn = HotkeyMachine(.init())
        _ = fn.consume(.init(.flags, code: 63, flags: HotkeyMachine.fnMask))
        let shortcut = fn.consume(.init(.flags, code: 59, flags: HotkeyMachine.fnMask | CGEventFlags.maskControl.rawValue))
        #expect(shortcut.0 == .cancel && !shortcut.1)
    }
}

actor PrefillProbe {
    var calls: [Int] = []
    private var first: CheckedContinuation<Void, Never>?
    func evaluate(_ snapshot: PartialSnapshot) async {
        calls.append(snapshot.revision)
        if snapshot.revision == 1 { await withCheckedContinuation { first = $0 } }
    }
    func release() { first?.resume(); first = nil }
}
@Suite struct PrefillTests {
    @Test func coalescesChangedPartialsAndSettlesBeforeFinal() async throws {
        let probe = PrefillProbe()
        let scheduler = PrefillScheduler { await probe.evaluate($0) }
        await scheduler.submit(.init(revision: 1, text: "Thursday"))
        for _ in 0..<500 { if await probe.calls.count == 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
        await scheduler.submit(.init(revision: 2, text: "Thursday afternoon"))
        await scheduler.submit(.init(revision: 3, text: "Friday afternoon"))
        await scheduler.submit(.init(revision: 4, text: "Friday afternoon"))
        await probe.release()
        for _ in 0..<500 { if await probe.calls.count == 2 { break }; try await Task.sleep(for: .milliseconds(1)) }
        await scheduler.stop()
        await scheduler.submit(.init(revision: 5, text: "ignored"))
        #expect(await probe.calls == [1, 3])
    }
}
@MainActor final class FakeStreamCapture: CaptureDriver {
    private var stream: AsyncThrowingStream<PCM16k, any Error>?
    private var continuation: AsyncThrowingStream<PCM16k, any Error>.Continuation?
    func begin() throws {
        let pair = AsyncThrowingStream<PCM16k, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        stream = pair.stream; continuation = pair.continuation
        continuation?.yield(try PCM16k([Float](repeating: 0.1, count: 320)))
    }
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>? { stream }
    func end() async throws -> PCM16k {
        continuation?.yield(try PCM16k([Float](repeating: 0.2, count: 320)))
        continuation?.finish(); continuation = nil
        return try PCM16k([Float](repeating: 0.1, count: 640))
    }
    func suspend() { continuation?.finish(throwing: CancellationError()); continuation = nil }
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
        #expect(coordinator.partial == nil)
    }
    @Test func privatePreferencesVersionAndOldConfigDefaultSafely() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1,\"backend\":\"http\"}".utf8))
        #expect(!old.streamingDemo && old.warmCapture && old.pauseMedia)
        #expect(old.cleanupInputFormat == .plain)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        var preferences = Preferences(); preferences.backend = .demo
        try store.save(preferences, prompt: "synthetic prompt", dictionary: "synthetic dictionary")
        #expect(try store.privateText("dictionary.txt") == "synthetic dictionary")
        #expect(try SettingsStore(directory: root).preferences.backend == .demo)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("dictionary.txt").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
    @Test func unreadablePromptIsPreservedWhenOtherSettingsAreSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        try store.save(Preferences(), prompt: "synthetic prompt", dictionary: "synthetic dictionary")
        let promptURL = root.appendingPathComponent("prompt.txt")
        let oversized = Data(repeating: 65, count: 16_385)
        try oversized.write(to: promptURL)
        #expect(throws: AppError.contextLimit) { try store.privateText("prompt.txt") }
        var preferences = store.preferences
        preferences.pauseMedia = false
        try store.save(preferences, prompt: nil, dictionary: "updated synthetic dictionary")
        #expect(try Data(contentsOf: promptURL) == oversized)
        #expect(try store.privateText("dictionary.txt") == "updated synthetic dictionary")
        #expect(try SettingsStore(directory: root).preferences.pauseMedia == false)
    }
}
@Suite struct StreamingAudioTests {
    @Test func boundedSenderChunksMatchOwnedCaptureAndBackpressureKeepsBatchAudio() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let worker = try AudioWorker(format: format)
        try worker.begin(warm: false, streaming: true)
        let stream = try #require(worker.chunks())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200)); buffer.frameLength = 3200
        for i in 0..<3200 { buffer.floatChannelData![0][i] = 0.1 }
        worker.receive(buffer)
        let audio = try await worker.end()
        var chunks: [Float] = []
        for try await chunk in stream { #expect(chunk.samples.count <= 640); chunks.append(contentsOf: chunk.samples) }
        #expect(chunks == audio.samples)
        try worker.begin(warm: false, streaming: true)
        let overflow = try #require(worker.chunks())
        // Four packets produce 20 chunks, exceeding the fixed 16-chunk sender buffer without a consumer.
        for _ in 0..<4 { worker.receive(buffer); worker.queue.sync {} }
        let retained = try await worker.end()
        #expect(retained.samples.count == 12_800)
        await #expect(throws: AppError.overflow) { for try await _ in overflow {} }
    }
}
