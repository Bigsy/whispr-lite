import AVFoundation
import Foundation
import Testing
@testable import WhisprLiteCore

private let evaluationEnvironment = ProcessInfo.processInfo.environment
private let evaluationRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let evaluationHarnessSHA256 = (try? Data(contentsOf: URL(fileURLWithPath: #filePath)))
    .map { CleanupFiles.digest($0) } ?? "unrecorded"

private struct AccuracyCase: Decodable {
    let id: String
    let raw: String
    let expected: [String]
    let category: String
    var dictionary: String? = nil
    var early: [String]? = nil
}
private struct AccuracyCorpus: Decodable {
    let schema: Int
    let version: String
    let provenance: String
    let cases: [AccuracyCase]
}
private struct ReviewedCleanupCase: Decodable {
    let id: String
    let raw: String
    let expected: String
    let review: String
}
private func reviewedCleanupCases() throws -> [ReviewedCleanupCase] {
    try JSONDecoder().decode([ReviewedCleanupCase].self,
        from: Data(contentsOf: evaluationRoot.appendingPathComponent("Resources/cleanup-fixtures.json")))
}
private func accuracyCorpus() throws -> AccuracyCorpus {
    try JSONDecoder().decode(AccuracyCorpus.self,
        from: Data(contentsOf: evaluationRoot.appendingPathComponent("Resources/accuracy-corpus-v1.json")))
}
private func percentiles(_ times: [Double]) -> [String: Any] {
    ["n": times.count, "p50_ms": ReportStatistics.median(times) ?? 0,
     "p95_ms": ReportStatistics.nearestRank(times, fraction: 0.95) ?? 0]
}
/// Levenshtein errors on normalized Unicode words. Cleanup scores are kept separate
/// from ASR WER; punctuation and valid paraphrases still need review.
private func wordErrors(_ reference: String, _ hypothesis: String) -> Int {
    let expected = WordTokens.words(reference), actual = WordTokens.words(hypothesis)
    var row = Array(0...actual.count)
    for (i, word) in expected.enumerated() {
        var next = [i + 1] + [Int](repeating: 0, count: actual.count)
        for (j, other) in actual.enumerated() {
            next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (word == other ? 0 : 1))
        }
        row = next
    }
    return row.last!
}
private func milliseconds(_ operation: () async throws -> Void) async rethrows -> Double {
    let start = ContinuousClock.now
    try await operation()
    return start.duration(to: .now).milliseconds
}
/// Frozen pre-plan word-only reuse, for measuring the cost and errors of refusing it.
private func previousReuse(_ full: String, chunks: [DictationText]) -> (cleaned: String, tail: String)? {
    let prefix = chunks.flatMap { WordTokens.words($0.raw) }
    guard !prefix.isEmpty, chunks.allSatisfy({ $0.raw.endsSentence && $0.cleaned.endsSentence }),
          WordTokens.words(full).starts(with: prefix) else { return nil }
    let matches = WordTokens.pattern.matches(in: full, range: NSRange(full.startIndex..<full.endIndex, in: full))
    var start = Range(matches[prefix.count - 1].range, in: full)!.upperBound
    while start < full.endIndex, ".!?".contains(full[start]) || full[start].isWhitespace { start = full.index(after: start) }
    return (chunks.map(\.cleaned).joined(separator: " "), String(full[start...]))
}
private func report(_ fields: [String: Any], name: String) throws {
    // No raw text, model replies, private paths, prompts, names or dictionaries.
    var fields = fields
    fields["schema"] = 1
    fields["visible_text_measured"] = false
    fields["physical_capture_measured"] = false
    fields["private_content_recorded"] = false
    fields["created_utc"] = ISO8601DateFormatter().string(from: Date())
    fields["runtime_label"] = evaluationEnvironment["WHISPR_CLEANUP_RUNTIME"] ?? "unrecorded"
    fields["build_revision"] = evaluationEnvironment["WHISPR_BUILD_REVISION"] ?? "unrecorded"
    fields["swift_version"] = evaluationEnvironment["WHISPR_SWIFT_VERSION"] ?? "unrecorded"
    fields["harness_sha256"] = evaluationHarnessSHA256
    fields["cleanup_stack_sha256"] = CleanupFiles.digest(try Data(contentsOf:
        evaluationRoot.appendingPathComponent("Resources/cleanup-stack.json")))
    fields["package_resolved_sha256"] = CleanupFiles.digest(try Data(contentsOf:
        evaluationRoot.appendingPathComponent("Package.resolved")))
    fields["prompt_sha256"] = CleanupFiles.digest(Data(SettingsStore.defaultPrompt.utf8))
    try JSONReport.write(fields, to: evaluationRoot.appendingPathComponent(".build/\(name).json"))
}

@Suite(.serialized) struct AccuracyEvaluationTests {
    @Test func versionedCorpusHasReviewedOutputsAndAllRequiredCategories() throws {
        let corpus = try accuracyCorpus()
        #expect(corpus.schema == 1 && corpus.version == "accuracy-v1" && !corpus.provenance.isEmpty)
        #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count)
        #expect(corpus.cases.allSatisfy { !$0.expected.isEmpty && $0.expected.allSatisfy { !$0.isEmpty } })
        #expect(Set(corpus.cases.map(\.category)).isSuperset(of:
            ["correction", "numbers", "names", "dictionary", "punctuation", "multilingual", "instructions", "independent"]))
        #expect(wordErrors("one two three", "one four three five") == 2)
        #expect(wordErrors("one two three", "one three") == 1)
        #expect(wordErrors("", "one") == 1)
        let realistic = try reviewedCleanupCases()
        #expect(realistic.count == 24 && realistic.allSatisfy { !$0.expected.isEmpty && !$0.review.isEmpty })
    }

    @Test(.enabled(if: evaluationEnvironment["WHISPR_EVALUATE"] == "1"))
    func localCleanupAccuracyAndSeamLatency() async throws {
        let corpus = try accuracyCorpus()
        let rounds = min(30, max(1, Int(evaluationEnvironment["WHISPR_EVALUATION_ROUNDS"] ?? "3") ?? 3))
        let endpoint = try LocalEndpoint(evaluationEnvironment["WHISPR_CLEANUP_ENDPOINT"] ?? Preferences().cleanupEndpoint)
        var observations: [[String: Any]] = []
        var fullTimes: [Double] = [], seamTimes: [Double] = [], previousTimes: [Double] = []
        var review: [[String: Any]] = [] // Synthetic inputs/replies only, never the private speech set.
        var oldReusable = 0, reusable = 0, seamCases = 0
        let fixtures = corpus.cases + (try reviewedCleanupCases()).map {
            AccuracyCase(id: $0.id, raw: $0.raw, expected: [$0.expected], category: "realistic")
        }
        for (index, fixture) in fixtures.enumerated() {
            FileHandle.standardError.write(Data("Evaluating synthetic fixture \(index + 1)/\(fixtures.count)\n".utf8))
            let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: SettingsStore.defaultPrompt,
                                           dictionary: fixture.dictionary ?? ""))
            try await cleanup.checkReadiness()
            try await cleanup.preparePrefix()
            let pipeline = BatchPipeline(backend: FakeASRBackend(), cleanup: cleanup)
            var early: [DictationText] = []
            for raw in fixture.early ?? [] { early.append(try await pipeline.finish(raw)) }
            if !early.isEmpty {
                seamCases += 1
                if previousReuse(fixture.raw, chunks: early) != nil { oldReusable += 1 }
                if BatchPipeline.reusablePrefix(in: fixture.raw, chunks: early) != nil { reusable += 1 }
            }
            // Interleave order. Early preparation is excluded from release work, but a
            // shared service/prompt cache means this is only a sequential local comparison.
            for round in 0..<rounds {
                var outputs: [String: String] = [:]
                var times: [String: Double] = [:]
                let order = ["full", "previous", "seams"]
                for offset in 0..<order.count {
                    let condition = order[(round + offset) % order.count]
                    times[condition] = try await milliseconds {
                        if condition == "previous", let reuse = previousReuse(fixture.raw, chunks: early) {
                            let tail = reuse.tail
                            outputs[condition] = tail.isEmpty ? reuse.cleaned : reuse.cleaned + " "
                                + (try await withDeadline(pipeline.cleanupDeadline, stage: "Cleanup") { try await cleanup.clean(tail) })
                        } else {
                            outputs[condition] = try await pipeline.finish(fixture.raw, early: condition == "seams" ? early : []).cleaned
                        }
                    }
                }
                let output = outputs["seams"]!
                let exact = fixture.expected.contains(output)
                let errors = fixture.expected.map { wordErrors($0, output) }.min()!
                observations.append(["case": fixture.id, "category": fixture.category, "round": round,
                    "exact_match": exact, "cleanup_word_errors": errors,
                    "review_required": !exact, "seam_changed_output": outputs["full"] != output,
                    "previous_word_errors": fixture.expected.map { wordErrors($0, outputs["previous"]!) }.min()!,
                    "full_word_errors": fixture.expected.map { wordErrors($0, outputs["full"]!) }.min()!,
                    "full_ms": times["full"]!, "seams_ms": times["seams"]!, "previous_ms": times["previous"]!])
                fullTimes.append(times["full"]!); seamTimes.append(times["seams"]!)
                previousTimes.append(times["previous"]!)
                if round == 0 {
                    review.append(["case": fixture.id, "raw": fixture.raw, "expected": fixture.expected,
                                   "full": outputs["full"]!, "previous": outputs["previous"]!, "seams": output])
                }
            }
        }
        try report(["corpus": corpus.version, "rounds": rounds,
                    "corpus_sha256": CleanupFiles.digest(try Data(contentsOf: evaluationRoot.appendingPathComponent("Resources/accuracy-corpus-v1.json"))),
                    "realistic_sha256": CleanupFiles.digest(try Data(contentsOf: evaluationRoot.appendingPathComponent("Resources/cleanup-fixtures.json"))),
                    "mode": "sequential-synthetic-cleanup", "model": CleanupConfiguration.defaultModel,
                    "full": percentiles(fullTimes), "seams": percentiles(seamTimes), "previous": percentiles(previousTimes),
                    "seam_cases": seamCases, "previous_reusable": oldReusable, "reusable": reusable,
                    "observations": observations], name: "accuracy-cleanup")
        try JSONReport.write(["synthetic_only": true, "cases": review],
            to: evaluationRoot.appendingPathComponent(".build/accuracy-synthetic-review.json"))
    }

    @Test(.enabled(if: evaluationEnvironment["WHISPR_BENCHMARK_SEAMS"] == "1"))
    func seamDecisionCost() throws {
        let corpus = try accuracyCorpus()
        var times: [Double] = []
        var decisions = 0
        for _ in 0..<1000 {
            let start = ContinuousClock.now
            for fixture in corpus.cases {
                let chunks = (fixture.early ?? []).map { DictationText(raw: $0, cleaned: $0) }
                if BatchPipeline.reusablePrefix(in: fixture.raw, chunks: chunks) != nil { decisions += 1 }
            }
            times.append(start.duration(to: .now).milliseconds)
        }
        try report(["mode": "synthetic-seam-decision", "corpus": corpus.version,
                    "all_cases": percentiles(times), "decisions": decisions], name: "seam-decision-cost")
    }

    @Test(.enabled(if: evaluationEnvironment["WHISPR_EVALUATE"] == "1"
                    && evaluationEnvironment["WHISPR_SPEECH_MANIFEST"] != nil))
    func consentedLocalSpeechSeparatesASRAndCleanupErrors() async throws {
        do { try await evaluateLocalSpeech() }
        catch { throw AppError.inference } // Never print a private transcript/path in a test error.
    }
    private func evaluateLocalSpeech() async throws {
        let url = URL(fileURLWithPath: evaluationEnvironment["WHISPR_SPEECH_MANIFEST"]!).resolvingSymlinksInPath()
        guard !url.path.hasPrefix(evaluationRoot.path + "/") else { throw AppError.unsupported }
        let manifest = try JSONDecoder().decode(SpeechManifest.self, from: Data(contentsOf: url))
        guard manifest.schema == 1, manifest.consent, !manifest.provenance.isEmpty,
              !manifest.cases.isEmpty, manifest.cases.allSatisfy({ !$0.reference.isEmpty
                  && !$0.expected.isEmpty && $0.expected.allSatisfy({ !$0.isEmpty }) }) else { throw AppError.unsupported }
        let model = ParakeetModel(rawValue: evaluationEnvironment["WHISPR_ASR_MODEL"] ?? "ultra") ?? .ultra
        let cache = evaluationEnvironment["WHISPR_ASR_CACHE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let backend = ParakeetCoreBackend(cacheRoot: cache, allowDownloads: false, model: model)
        try await backend.prepare()
        let cleanup = HTTPCleanup(.init(endpoint: try .init(evaluationEnvironment["WHISPR_CLEANUP_ENDPOINT"]
            ?? Preferences().cleanupEndpoint), prompt: SettingsStore.defaultPrompt))
        try await cleanup.preparePrefix()
        var observations: [[String: Any]] = []
        for (index, fixture) in manifest.cases.enumerated() {
            let file = url.deletingLastPathComponent().appendingPathComponent(fixture.wav).resolvingSymlinksInPath()
            guard file.path.hasPrefix(url.deletingLastPathComponent().path + "/") else { throw AppError.unsupported }
            let audio = try speechPCM(file)
            let result = try await backend.transcribe(audio)
            let cleaned = try await cleanup.clean(result.text)
            observations.append(["case_index": index, "asr_word_errors": wordErrors(fixture.reference, result.text),
                "asr_reference_words": WordTokens.words(fixture.reference).count,
                "cleanup_word_errors": fixture.expected.map { wordErrors($0, cleaned) }.min() ?? 0,
                "cleanup_review_required": !fixture.expected.contains(cleaned),
                "audio_uncertain": result.coverage?.needsReview ?? false, "seconds": audio.duration])
        }
        try await backend.unload()
        try report(["mode": "consented-local-speech", "model": model.rawValue, "observations": observations], name: "accuracy-speech")
    }
}

private struct SpeechManifest: Decodable {
    let schema: Int
    let consent: Bool
    let provenance: String
    let cases: [Case]
    struct Case: Decodable {
        let wav: String
        let reference: String
        let expected: [String]
    }
}
private func speechPCM(_ url: URL) throws -> PCM16k {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == Double(PCM16k.rate), file.processingFormat.channelCount == 1,
          file.length > 0, file.length <= PCM16k.maximumSamples,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw AppError.invalidAudio
    }
    try file.read(into: buffer)
    guard let floats = buffer.floatChannelData?[0] else { throw AppError.invalidAudio }
    return try PCM16k(Array(UnsafeBufferPointer(start: floats, count: Int(buffer.frameLength))))
}
