import Testing
import Foundation
import CoreGraphics
import AVFoundation
import ParakeetCore
@testable import WhisprLiteCore

@Suite struct EarlyCleanupTests {
    @Test(arguments: [
        ("Meet on Tuesday. No wait, Wednesday.", ["Meet on Tuesday."]),
        ("Meet on Tuesday. No wait, Wednesday. Bring notes.", ["Meet on Tuesday.", "No wait, Wednesday."]),
        ("Meet on Tuesday, bring notes.", ["Meet on Tuesday."]),
        ("Meet on Tuesday? Bring notes.", ["Meet on Tuesday."]),
        ("First sentence, second sentence. Third sentence.", ["First sentence.", "Second sentence."]),
        ("First sentence, second sentence. Third sentence.", ["First sentence. Second sentence."]),
        ("Meet on Tuesday. Bring notes. Actually, make that Friday.", ["Meet on Tuesday.", "Bring notes."]),
        ("Treffen am Dienstag. Nein, am Mittwoch.", ["Treffen am Dienstag."])
    ]) func questionableSeamsCleanTheWholeTranscript(raw: String, chunks: [String]) async throws {
        let cleanup = RecordingCleanup()
        let pipeline = BatchPipeline(backend: FakeASRBackend(), cleanup: cleanup)
        let early = chunks.map { DictationText(raw: $0, cleaned: $0) }
        _ = try await pipeline.finish(raw, early: early)
        #expect(await cleanup.inputs == [raw])
    }
    @Test func correctionCanReplaceTextAcrossTwoAlreadyCleanedChunks() async throws {
        let raw = "Meet on Tuesday. Bring notes. Scratch that, meet on Friday with slides."
        let cleanup = ContextCorrectionCleanup(raw: raw, expected: "Meet on Friday with slides.")
        let result = try await BatchPipeline(backend: FakeASRBackend(), cleanup: cleanup).finish(raw, early: [
            .init(raw: "Meet on Tuesday.", cleaned: "Meet on Tuesday."),
            .init(raw: "Bring notes.", cleaned: "Bring notes.")
        ])
        #expect(result.cleaned == "Meet on Friday with slides.")
    }
    @Test func independentChunksStillReuseEverySafeSeam() async throws {
        let cleanup = RecordingCleanup()
        let result = try await BatchPipeline(backend: FakeASRBackend(), cleanup: cleanup).finish(
            "First sentence. Second sentence. Third sentence.", early: [
                .init(raw: "First sentence.", cleaned: "First sentence."),
                .init(raw: "Second sentence.", cleaned: "Second sentence.")])
        #expect(result.cleaned == "First sentence. Second sentence. Third sentence.")
        #expect(await cleanup.inputs == ["Third sentence."])
    }
    @Test func sentencePrefixCutsMidwayToTheNextWordAndCarriesTheRest() throws {
        let audio = try PCM16k([Float](repeating: 0, count: 32_000))
        let heard = ASRResult(text: "First sentence. Second", audioDuration: 2, words: SentenceCutBackend.chunkWords)
        let cut = try #require(BatchPipeline.sentencePrefix(of: heard, audio: audio))
        #expect(cut.text == "First sentence." && cut.rest.count == 16_000)
        let whole = ASRResult(text: "Done.", audioDuration: 2)
        #expect(BatchPipeline.sentencePrefix(of: whole, audio: audio)?.rest.isEmpty == true)
        let unfinished = ASRResult(text: "No full stop", audioDuration: 2,
                                   words: [TimedWord(text: "No", start: 0, end: 0.3, confidence: 1)])
        #expect(BatchPipeline.sentencePrefix(of: unfinished, audio: audio) == nil)
        #expect(BatchPipeline.sentencePrefix(of: ASRResult(text: "No timings", audioDuration: 2), audio: audio) == nil)
    }
    @Test func completedSentenceReusesCleanupAndOnlyCleansTail() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let cleanup = RecordingCleanup()
        let pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        let early = [DictationText(raw: "First sentence.", cleaned: "First sentence.")]
        let result = try await pipeline.finish("First sentence. Second sentence.", early: early)
        #expect(result.cleaned == "First sentence. Second sentence.")
        #expect(await cleanup.inputs == ["Second sentence."])
    }
    @Test func reusedPrefixKeepsLeadingSymbolsInTail() async throws {
        let backend = FakeASRBackend(); try await backend.prepare()
        let cleanup = RecordingCleanup()
        let pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        let early = [DictationText(raw: "First sentence.", cleaned: "First sentence.")]
        #expect(try await pipeline.finish("First sentence. £5 is fine.", early: early).cleaned
            == "First sentence. £5 is fine.")
        #expect(try await pipeline.finish("First sentence. “Quoted words.”", early: early).cleaned
            == "First sentence. “Quoted words.”")
        #expect(await cleanup.inputs == ["£5 is fine.", "“Quoted words.”"])
    }
    @Test func symbolsAtTheEndOfAReusedChunkDoNotLeakIntoTheTail() async throws {
        let cleanup = RecordingCleanup()
        let result = try await BatchPipeline(backend: FakeASRBackend(), cleanup: cleanup).finish(
            "We use C++. The build passed.", early: [.init(raw: "We use C++.", cleaned: "We use C++.")])
        #expect(result.cleaned == "We use C++. The build passed.")
        #expect(await cleanup.inputs == ["The build passed."])
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

private struct ContextCorrectionCleanup: TextCleanup {
    let raw: String
    let expected: String
    func clean(_ text: String) -> String { text == raw ? expected : text }
}

@Suite struct RawTranscriptionTests {
    @Test func disabledCleanupNeverCallsTheService() async throws {
        let cleanup = CountingCleanup()
        var pipeline = BatchPipeline(backend: FakeASRBackend(), cleanup: cleanup)
        pipeline.cleanupPolicy = .disabled
        let result = try await pipeline.finish("Raw words", early: [.init(raw: "Raw words", cleaned: "Different.")])
        #expect(result == .init(raw: "Raw words", cleaned: "Raw words", cleanup: .disabled))
        #expect(await cleanup.calls == 0)
    }
    @Test func optionalCleanupFallsBackOnFailureAndRecoversOnNextResult() async throws {
        let cleanup = ReconnectingCleanup()
        var pipeline = BatchPipeline(backend: FakeASRBackend(), cleanup: cleanup)
        pipeline.cleanupPolicy = .whenAvailable
        #expect(try await pipeline.finish("Raw words").cleanup == .unavailable)
        await cleanup.reconnect()
        #expect(try await pipeline.finish("Raw words") == .init(raw: "Raw words", cleaned: "Cleaned words."))
    }
    @Test func fallbackPreservesCancellationAndTheConfiguredDeadline() async throws {
        var pipeline = BatchPipeline(backend: FakeASRBackend(), cleanup: RecordingCleanup(delay: .seconds(5)))
        pipeline.cleanupPolicy = .whenAvailable; pipeline.cleanupDeadline = .milliseconds(10)
        #expect(try await pipeline.finish("Raw words").cleanup == .unavailable)
        let configured = pipeline
        let task = Task { try await configured.finish("Cancelled words") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor ReconnectingCleanup: TextCleanup {
    private var available = false
    func reconnect() { available = true }
    func clean(_ text: String) throws -> String {
        guard available else { throw CleanupFailure.connection }
        return "Cleaned words."
    }
}
