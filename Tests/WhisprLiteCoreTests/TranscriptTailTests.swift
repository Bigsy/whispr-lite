import Testing
import Foundation
import ParakeetCore
@testable import WhisprLiteCore

/// A 250 Hz tone stands in for speech over a quiet alternating floor; no real audio. Built
/// from repeated periods, so long clips stay cheap beside timing-sensitive tests.
private func clip(seconds: Double, speech: [ClosedRange<Double>]) throws -> PCM16k {
    let tone = (0..<64).map { Float(0.1 * sin(2 * .pi * Double($0) / 64)) }
    var samples = [Float](repeating: 0.001, count: Int(seconds * Double(PCM16k.rate)))
    samples.withUnsafeMutableBufferPointer { buffer in
        for index in stride(from: 1, to: buffer.count, by: 2) { buffer[index] = -0.001 }
        for range in speech {
            let start = Int(range.lowerBound * Double(PCM16k.rate)) / 64 * 64
            let end = min(buffer.count, Int(range.upperBound * Double(PCM16k.rate)) / 64 * 64)
            for index in start..<max(start, end) { buffer[index] = tone[index % 64] }
        }
    }
    return try PCM16k(samples)
}
private func word(_ text: String, _ start: Double, confidence: Float = 0.9) -> TimedWord {
    .init(text: text, start: start, end: start + 0.3, confidence: confidence)
}
private actor CoverageBackend: ASRBackend {
    func prepare() {}
    func readiness() -> BackendReadiness { .ready }
    func transcribe(_ audio: PCM16k) -> ASRResult {
        .init(text: "Synthetic words.", audioDuration: audio.duration, coverage: .init(.covered, audioSeconds: audio.duration))
    }
}

@Suite struct TranscriptTailTests {
    @Test func speechThresholdFollowsFluidAudioClamp() throws {
        #expect(TranscriptTail.speechThreshold([Float](repeating: 0, count: PCM16k.rate)) == 0.008)
        #expect(TranscriptTail.speechThreshold(try clip(seconds: 2, speech: [0...2]).samples) == 0.008)
        #expect(TranscriptTail.speechThreshold(try clip(seconds: 2, speech: []).samples) == 0.0005)
        let audio = try clip(seconds: 4, speech: [0.96...2.96]) // whole 80 ms frames
        #expect(TranscriptTail.speechSeconds(audio.samples, from: 0, threshold: 0.008) == 2.0)
        #expect(TranscriptTail.speechSeconds(audio.samples, from: 3 * PCM16k.rate, threshold: 0.008) == 0)
    }

    @Test func coveredShortOrUntimedTranscriptsAreNotDecodedAgain() async throws {
        var decodes = 0
        func decode(_ audio: PCM16k) async throws -> [TimedWord]? { decodes += 1; return [] }
        let long = try clip(seconds: 20, speech: [1...10])
        let untimed = try await TranscriptTail.complete(long, text: "Kept.", words: nil, redecode: decode)
        #expect(untimed.text == "Kept." && untimed.coverage == .init(.unavailable, audioSeconds: 20))
        #expect(try await TranscriptTail.complete(long, text: "", words: [], redecode: decode).coverage?.outcome == .noWords)
        let covered = try await TranscriptTail.complete(long, text: "Kept.", words: [word("Kept.", 9.7)], redecode: decode)
        #expect(covered.text == "Kept." && covered.coverage?.outcome == .covered)
        #expect(abs((covered.coverage?.lastWordEndSeconds ?? 0) - 10) < 1e-9 && covered.coverage?.speechAfterSeconds == 0)
        let single = try await TranscriptTail.complete(try clip(seconds: 10, speech: [0...10]), text: "Kept.",
                                                       words: [word("Kept.", 5.7)], redecode: decode)
        #expect(single.text == "Kept." && single.coverage?.outcome == .uncovered)
        #expect((single.coverage?.speechAfterSeconds ?? 0) > 3.5 && single.coverage?.fallbackMS == nil)
        #expect(decodes == 0)
    }
    @Test func emptyTranscriptsDoNotCallAQuietNoiseFloorMissingSpeech() async throws {
        let quiet = try await TranscriptTail.complete(clip(seconds: 2, speech: []), text: "", words: []) { _ in [] }
        let active = try await TranscriptTail.complete(clip(seconds: 2, speech: [0...2]), text: "", words: []) { _ in [] }
        #expect(quiet.coverage?.needsReview == false)
        #expect(active.coverage?.needsReview == true)
    }

    @Test func missingTailIsDecodedOnceFromItsOwnWindowAndOnlyNewWordsAreAppended() async throws {
        let audio = try clip(seconds: 30, speech: [0...28])
        var windows: [Int] = []
        let result = try await TranscriptTail.complete(audio, text: "Earlier words.",
                                                       words: [word("Earlier", 18.6), word("words.", 19.4)]) { tail in
            windows.append(tail.samples.count)
            // The window starts 2 s before the last word ends, frame aligned at 17.68 s.
            return [word("Earlier", 0.92), word("words.", 1.96), word("What", 2.5), word("next?", 3.0)]
        }
        #expect(result.text == "Earlier words. What next?")
        #expect(windows == [audio.samples.count - 282_880])
        let coverage = try #require(result.coverage)
        // The decode saw the end, yet stopped early: recovered words do not verify
        // the remaining speech. Keep the text and report a partial recovery.
        #expect(coverage.outcome == .partial && coverage.needsReview && coverage.recoveredWords == 2 && coverage.fallbackMS != nil)
        #expect((coverage.speechAfterSeconds ?? 0) > 6)
        #expect(result.words?.count == 4)

        var capped: [Int] = []
        _ = try await TranscriptTail.complete(audio, text: "Early.", words: [word("Early.", 4.7)]) { tail in
            capped.append(tail.samples.count); return []
        }
        #expect(capped == [TranscriptTail.windowSamples])
    }

    @Test func tailLongerThanOneWindowIsReassessedUntilCovered() async throws {
        let audio = try clip(seconds: 50, speech: [0...48])
        var windows: [Double] = []
        let result = try await TranscriptTail.complete(audio, text: "Start.", words: [word("Start.", 4.7)]) { tail in
            windows.append(tail.duration)
            return [word("Next.", tail.duration - 0.4)]
        }
        #expect(windows.count == 4 && windows.allSatisfy { $0 <= 14.96 })
        #expect(result.coverage?.outcome == .recovered && result.coverage?.needsReview == false)
        #expect(result.coverage?.recoveredWords == 4 && result.coverage?.fallbackAttempts == 4)
        #expect(result.words?.count == 5 && (result.words?.last?.end ?? 0) > 49)
        #expect(result.text == "Start. Next. Next. Next. Next.")
    }

    @Test func noProgressAndInvalidTimingStopWithoutRepeatingWindows() async throws {
        let audio = try clip(seconds: 50, speech: [0...48])
        for tail in [[word("Start.", 1.7)], [word("Invalid", .nan)], [word("Beyond", 20)]] {
            var attempts = 0
            let result = try await TranscriptTail.complete(audio, text: "Start.", words: [word("Start.", 4.7)]) { _ in
                attempts += 1; return tail
            }
            #expect(attempts == 1 && result.text == "Start.")
            #expect(result.coverage?.outcome == .unrecovered && result.coverage?.needsReview == true)
        }
    }

    @Test func smallProgressHasARecordingLengthBoundAndStaysUncertain() async throws {
        let audio = try clip(seconds: 50, speech: [0...48])
        var attempts = 0
        let result = try await TranscriptTail.complete(audio, text: "Start.", words: [word("Start.", 4.7)]) { _ in
            attempts += 1; return [word("Advance", 2.2)]
        }
        #expect(attempts <= 4)
        #expect(result.coverage?.outcome == .partial && result.coverage?.needsReview == true)
    }

    @Test func cancellationBeforeRecoveryDoesNoDecode() async throws {
        let audio = try clip(seconds: 50, speech: [0...48])
        let decodes = LockedCounter()
        let gate = AsyncGate()
        let task = Task {
            await gate.enterAndWait()
            return try await TranscriptTail.complete(audio, text: "Start.", words: [word("Start.", 4.7)]) { _ in
                decodes.increment(); throw CancellationError()
            }
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(decodes.value == 0)
    }

    @Test func lowConfidenceOrRepeatedTailLeavesTranscriptUnchanged() async throws {
        let audio = try clip(seconds: 30, speech: [0...28])
        let words = [word("Earlier", 18.6), word("words.", 19.4)]
        let doubtful = try await TranscriptTail.complete(audio, text: "Earlier words.", words: words) { _ in
            [word("Hmm", 2.5, confidence: 0.4), word("what", 3.0, confidence: 0.6)]
        }
        #expect(doubtful.text == "Earlier words." && doubtful.coverage?.outcome == .unrecovered)
        #expect(doubtful.coverage?.recoveredWords == 0)
        let missing = TranscriptTail.missingWords(after: [word("the", 9.2), word("other", 9.6), word("one.", 10.0)],
            in: [word("other", 10.25), word("one.", 10.3), word("What", 11.0)], offset: 0)
        #expect(missing.map(\.text) == ["What"])
        await #expect(throws: CancellationError.self) {
            try await TranscriptTail.complete(audio, text: "Earlier words.", words: words) { _ in throw CancellationError() }
        }
    }

    @Test func pipelineReportsCoverageAndDiagnosticsCarryOnlyNumbers() async throws {
        let reports = LockedCounter()
        let audio = try PCM16k([Float](repeating: 0.1, count: PCM16k.rate))
        let report: CoverageReport = { _ in reports.increment() }
        _ = try await BatchPipeline(backend: CoverageBackend(), cleanup: DemoCleanup()).transcribe(audio, report: report)
        let fake = FakeASRBackend(); try await fake.prepare()
        _ = try await BatchPipeline(backend: fake, cleanup: DemoCleanup()).transcribe(audio, report: report)
        #expect(reports.value == 1)

        var coverage = TranscriptCoverage(.recovered, audioSeconds: 50.8)
        coverage.lastWordEndSeconds = 44; coverage.speechAfterSeconds = 4.2
        coverage.recoveredWords = 9; coverage.fallbackMS = 41.5
        let data = try JSONEncoder().encode(DiagnosticRecord(.coverage, session: UUID(), coverage: coverage))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try #require(object["coverage"] as? [String: Any])
        #expect(object["kind"] as? String == "coverage")
        #expect(Set(fields.keys) == ["outcome", "audioSeconds", "lastWordEndSeconds", "speechAfterSeconds",
                                     "recoveredWords", "fallbackMS"])
        #expect(fields.values.allSatisfy { $0 is NSNumber || TranscriptCoverage.Outcome(rawValue: $0 as? String ?? "") != nil })
    }
}
