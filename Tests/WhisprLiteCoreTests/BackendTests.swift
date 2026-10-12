import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@Suite struct BackendTests {
    @Test func captureOptionsFollowSavedBackendAndDemoMode() {
        var preferences = Preferences()
        #expect(CaptureOptions(preferences).earlyChunks)
        #expect(!CaptureOptions(preferences).streaming)
        preferences.backend = .demo; preferences.streamingDemo = true
        #expect(CaptureOptions(preferences).streaming)
        #expect(!CaptureOptions(preferences).earlyChunks)
    }
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
        let request = try cleanup.request("hello", maxTokens: 512)
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
        #expect(throws: AppError.contextLimit) { try cleanup.request(String(repeating: "x", count: 16_384), maxTokens: 512) }
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
                await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
                return "late"
            }
        }
        // Waiting for the worker would take 3 s; the margin absorbs slow CI runners.
        #expect(start.duration(to: .now) < .milliseconds(1500))
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
