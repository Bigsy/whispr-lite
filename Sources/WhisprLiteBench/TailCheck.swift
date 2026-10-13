import Foundation
import ParakeetCore
import WhisprLiteCore

/// Synthetic only: exercises the app's tail fallback against the real model. Each clip over
/// one window is transcribed in full, then its final sentence's words are removed, as a final
/// window that decoded to nothing would leave it, and `TranscriptTail` must put them back.
extension Bench {
    static func tailCheck(cache: URL, corpus: URL, output: URL, model: ParakeetModel, repetitions: Int) async throws {
        guard let choice = ModelChoice(rawValue: model.rawValue) else { throw BenchFailure("Unsupported ASR model", exitCode: 2) }
        let engine = ParakeetEngine(configuration: .init(model: choice, mode: .batch, cacheRoot: cache,
            downloadPolicy: .requireCached, queueCapacity: 1))
        print("Preparing \(engine.modelID); downloads=false")
        try await engine.prepare()
        let redecode: (PCM16k) async throws -> [TimedWord]? = {
            try await engine.transcribe(PCM16kMono(samples: $0.samples)).words
        }
        var observations: [[String: Any]] = []
        for file in try PCM16k.corpus(in: corpus) {
            let audio = try PCM16k(contentsOfWAV: file)
            guard audio.duration > 15 else { continue }
            let full = try await engine.transcribe(PCM16kMono(samples: audio.samples))
            guard let words = full.words, !words.isEmpty else { throw BenchFailure("Real ASR returned no word timings") }
            let baseline = try await TranscriptTail.complete(audio, text: full.text, words: words, redecode: redecode)
            guard let before = baseline.coverage, [.covered, .uncovered].contains(before.outcome) else {
                throw BenchFailure("Tail fallback ran on a complete synthetic transcript")
            }
            guard let cut = words.dropLast().lastIndex(where: { $0.text.last.map { ".?!".contains($0) } == true }) else { continue }
            let kept = Array(words[...cut])
            var fallbackMS: [Double] = []
            var recovered: ASRResult?
            for _ in 0..<repetitions {
                let result = try await TranscriptTail.complete(audio, text: kept.map(\.text).joined(separator: " "),
                                                               words: kept, redecode: redecode)
                guard result.coverage?.outcome == .recovered, let milliseconds = result.coverage?.fallbackMS else {
                    throw BenchFailure("Tail fallback did not recover the removed sentence in \(file.lastPathComponent): "
                        + "\(result.coverage?.outcome.rawValue ?? "none"), "
                        + "speech after cut \(result.coverage?.speechAfterSeconds ?? 0) s")
                }
                guard recovered == nil || recovered?.text == result.text else { throw BenchFailure("Repeated tail recovery changed") }
                fallbackMS.append(milliseconds); recovered = result
            }
            guard let recovered, let coverage = recovered.coverage else { throw BenchFailure("Invalid repetition count", exitCode: 2) }
            let restored = WordTokens.words(recovered.text) == WordTokens.words(full.text)
            let median = ReportStatistics.median(fallbackMS)!
            observations.append(["fixture": file.lastPathComponent, "audio_seconds": audio.duration,
                                 "baseline_outcome": before.outcome.rawValue,
                                 "baseline_speech_after_seconds": before.speechAfterSeconds.map { $0 as Any } ?? NSNull(),
                                 "removed_words": words.count - kept.count, "speech_after_seconds": coverage.speechAfterSeconds.map { $0 as Any } ?? NSNull(),
                                 "recovered_words": coverage.recoveredWords ?? 0, "words_restored": restored,
                                 "synthetic_transcript": full.text, "recovered_transcript": recovered.text,
                                 "fallback_ms": fallbackMS, "median_ms": median,
                                 "p90_ms": ReportStatistics.nearestRank(fallbackMS, fraction: 0.9)!])
            print("\(model.rawValue): \(file.lastPathComponent) removed=\(words.count - kept.count) "
                  + "recovered=\(coverage.recoveredWords ?? 0) restored=\(restored) median-ms=\(median)")
        }
        try await engine.unload()
        guard !observations.isEmpty else {
            throw BenchFailure("No synthetic clip over 15 s with an earlier sentence end was found")
        }
        try JSONReport.write(["schema": 1, "mode": "real-parakeet-tail-synthetic", "model": model.rawValue,
                              "model_id": engine.modelID, "repetitions": repetitions, "downloads_allowed": false,
                              "visible_text_measured": false, "ground_truth_accuracy_measured": false,
                              "fixtures": observations], to: output)
        print("tail-check fixtures=\(observations.count) recovered=all")
    }
}
