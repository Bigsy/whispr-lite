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
    @Test func privatePreferencesVersionAndOldConfigDefaultSafely() throws {
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(defaults == Preferences())
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1,\"backend\":\"http\"}".utf8))
        #expect(!old.streamingDemo && old.warmCapture && old.pauseMedia)
        #expect(old.cleanupInputFormat == .plain)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        var preferences = Preferences(); preferences.backend = .demo
        try store.save(preferences, prompt: "synthetic prompt", dictionary: "synthetic dictionary")
        #expect(try store.privateText(.dictionary) == "synthetic dictionary")
        #expect(try SettingsStore(directory: root).preferences.backend == .demo)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("dictionary.txt").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
    @Test func bundledBenchmarkPromptMatchesAppDefault() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("Resources/cleanup-prompt.txt"), encoding: .utf8)
        #expect(file.trimmingCharacters(in: .newlines) == SettingsStore.defaultPrompt.trimmingCharacters(in: .newlines))
    }
    @Test func invalidSettingsIdentifyTheirFieldBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        let store = try SettingsStore(directory: root)
        var preferences = Preferences()
        preferences.asrTimeoutSeconds = 0
        #expect(throws: SettingsValidationError(.asrTimeout, "Speech recognition deadline must be 1–120 seconds.")) {
            try store.save(preferences, prompt: nil, dictionary: nil)
        }
        preferences.asrTimeoutSeconds = 10
        preferences.cleanupEndpoint = "https://example.com"
        #expect(throws: SettingsValidationError(.cleanupEndpoint, "Cleanup URL must be a local HTTP address.")) {
            try store.save(preferences, prompt: nil, dictionary: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func unreadablePromptIsPreservedWhenOtherSettingsAreSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        try store.save(Preferences(), prompt: "synthetic prompt", dictionary: "synthetic dictionary")
        let promptURL = root.appendingPathComponent("prompt.txt")
        let oversized = Data(repeating: 65, count: 16_385)
        try oversized.write(to: promptURL)
        #expect(throws: AppError.contextLimit) { try store.privateText(.prompt) }
        var preferences = store.preferences
        preferences.pauseMedia = false
        try store.save(preferences, prompt: nil, dictionary: "updated synthetic dictionary")
        #expect(try Data(contentsOf: promptURL) == oversized)
        #expect(try store.privateText(.dictionary) == "updated synthetic dictionary")
        #expect(try SettingsStore(directory: root).preferences.pauseMedia == false)
    }
    @Test func settingsRejectSymlinkAndTightenExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        try Data("synthetic outside".utf8).write(to: outside)
        let store = try SettingsStore(directory: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("prompt.txt"), withDestinationURL: outside)
        #expect(throws: CocoaError.self) { try store.save(Preferences(), prompt: "synthetic prompt", dictionary: nil) }
        #expect(throws: CocoaError.self) { try store.privateText(.prompt) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "synthetic outside")
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.json").path))
    }
}
