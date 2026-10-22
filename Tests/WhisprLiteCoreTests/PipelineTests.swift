import Testing
import Foundation
import CoreGraphics
import AVFoundation
import ParakeetCore
@testable import WhisprLiteCore

@Suite struct EarlyCleanupTests {
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
