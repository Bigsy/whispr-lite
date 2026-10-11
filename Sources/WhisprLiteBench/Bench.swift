import Foundation
import WhisprLiteCore

@main struct Bench {
    static func main() async {
        do { try await run() }
        catch let failure as BenchFailure {
            fputs("Check failed: \(failure.message)\n", stderr)
            exit(failure.exitCode)
        }
        catch {
            print("Check failed: " + error.localizedDescription)
            exit(1)
        }
    }
    static func run() async throws {
        let args = try BenchArguments(Array(CommandLine.arguments.dropFirst()))
        switch args.mode {
        case "--cleanup-prefill-check":
            try await cleanupPrefillCheck()
        case "--dictionary-check":
            try await dictionaryCheck()
        case "--vad-trim-prototype":
            let repetitions = try args.int("--repetitions", default: 30)
            let threshold = try args.float("--vad-threshold", default: 0.5)
            guard repetitions > 0, (0.05...0.95).contains(threshold) else {
                throw BenchFailure("Invalid VAD benchmark bounds", exitCode: 2)
            }
            try await vadTrimPrototype(asrCache: args.path(0, directory: true),
                vadCache: args.path(1, directory: true), corpus: args.path(2, directory: true),
                output: args.path(3), repetitions: repetitions, threshold: threshold,
                allowDownloads: args.has("--allow-model-downloads"))
        #if PARAKEET_STREAMING
        case "--streaming-prototype":
            let repetitions = try args.int("--repetitions", default: 30)
            guard repetitions > 0 else { throw BenchFailure("Invalid repetition count", exitCode: 2) }
            try await streamingPrototype(cache: args.path(0, directory: true),
                corpus: args.path(1, directory: true), output: args.path(2),
                repetitions: repetitions, recordPartials: args.has("--record-partials"))
        case "--streaming-check":
            try await realStreaming(cache: args.path(0, directory: true),
                                    corpus: args.path(1, directory: true), output: args.path(2))
        #endif
        case "--parakeet-check":
            let model: ParakeetModel
            if let selected = args.string("--model") {
                guard let parsed = ParakeetModel(rawValue: selected) else {
                    throw BenchFailure("Unsupported ASR model", exitCode: 2)
                }
                model = parsed
            } else { model = .unified }
            let repetitions = try args.int("--repetitions", default: 30)
            guard repetitions > 0 else { throw BenchFailure("Invalid repetition count", exitCode: 2) }
            try await parakeetCheck(cache: args.path(0, directory: true),
                                    corpus: args.path(1, directory: true), output: args.path(2),
                                    model: model, repetitions: repetitions,
                                    allowDownloads: args.has("--allow-model-downloads"))
        case "--candidate-check":
            let cache = ProcessInfo.processInfo.environment["PARAKEET_MODEL_CACHE"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let backend = try BackendFactory.make(mode: .parakeet, endpoint: "http://127.0.0.1:11435", cacheRoot: cache)
            try await backend.prepare()
            let result = try await backend.transcribe(PCM16k([Float](repeating: 0, count: PCM16k.rate)))
            print("candidate ready=\(await backend.readiness() == .ready) audio-seconds=\(result.audioDuration)")
        default:
            throw BenchFailure("Unsupported benchmark mode", exitCode: 2)
        }
    }
    @MainActor static func cleanupPrefillCheck() async throws {
        let store = try SettingsStore()
        let preferences = store.preferences
        let cleanup = HTTPCleanup(try .init(preferences: preferences, prompt: store.prompt(), dictionary: store.dictionary()))
        let fixtures = ["what's the capital of france", "send it by thursday no wait friday period",
                        "i think it was about fifteen pounds but i'm not sure"]
        for input in fixtures {
            let baseline = try await cleanup.clean(input)
            try await cleanup.preparePrefix()
            guard try await cleanup.clean(input) == baseline else { throw AppError.cleanup }
        }
        print("Cleanup prefill: \(fixtures.count)/\(fixtures.count) synthetic outputs equal; private text not recorded. Timing not measured.")
    }
    @MainActor static func dictionaryCheck() async throws {
        let store = try SettingsStore()
        let preferences = store.preferences
        let dictionary = try store.dictionary()
        guard DictionaryCorrections(dictionary).apply(to: "dochler") == "Doccla" else { throw AppError.notReady }
        let cleanup = HTTPCleanup(try .init(preferences: preferences, prompt: store.prompt(),
                                            dictionary: dictionary + "\nhappy fire > hapi fhir"))
        let doccla: (String) -> Bool = {
            $0.contains("Doccla") && !$0.localizedCaseInsensitiveContains("dochler")
        }
        let fixtures: [(input: String, accepts: (String) -> Bool)] = [
            ("i work at dochler", doccla),
            ("send the report to dochler", doccla),
            ("dochler", doccla),
            ("the doctor called me", { $0.localizedCaseInsensitiveContains("doctor") && !$0.contains("Doccla") }),
            ("we use happy fire", { $0.contains("hapi fhir") && !$0.localizedCaseInsensitiveContains("happy fire") })
        ]
        var passed = 0
        for fixture in fixtures {
            let output = try await cleanup.clean(fixture.input)
            guard fixture.accepts(output) else { throw AppError.cleanup }
            passed += 1
        }
        print("Dictionary check: \(passed)/\(fixtures.count) synthetic cases passed; private text not recorded.")
    }
    static func milliseconds(_ duration: Duration) -> Double {
        duration.milliseconds
    }
    static func parakeetCheck(cache: URL, corpus: URL, output: URL, model: ParakeetModel,
                              repetitions: Int, allowDownloads: Bool) async throws {
        let backend = ParakeetCoreBackend(cacheRoot: cache, allowDownloads: allowDownloads, model: model)
        print("Preparing \(backend.modelID); downloads=\(allowDownloads)", terminator: "\n")
        let started = ContinuousClock.now
        try await backend.prepare()
        let preparation = milliseconds(started.duration(to: .now))
        guard await backend.readiness() == .ready else { throw AppError.notReady }
        try await backend.prepare() // Repeated preparation must remain ready.
        let empty = try await backend.transcribe(PCM16k([]))
        guard empty.text.isEmpty, empty.audioDuration == 0 else { throw AppError.inference }
        let silence = try await backend.transcribe(PCM16k([Float](repeating: 0, count: PCM16k.rate)))
        guard silence.text.isEmpty else { throw AppError.inference }
        let files = try PCM16k.corpus(in: corpus)
        var observations: [[String: Any]] = []
        var longest: PCM16k?
        var shortest: PCM16k?
        var shortestText = ""
        for file in files {
            let audio = try PCM16k(contentsOfWAV: file)
            if longest == nil || audio.duration > longest!.duration { longest = audio }
            let expected = try await backend.transcribe(audio)
            guard !expected.text.isEmpty, expected.audioDuration == audio.duration else { throw AppError.inference }
            if shortest == nil || audio.duration < shortest!.duration { shortest = audio; shortestText = expected.text }
            var raw: [Double] = []
            for _ in 0..<repetitions {
                let start = ContinuousClock.now
                let result = try await backend.transcribe(audio)
                raw.append(milliseconds(start.duration(to: .now)))
                guard result == expected else { throw AppError.inference }
            }
            let median = ReportStatistics.median(raw)!
            observations.append(["fixture": file.lastPathComponent, "audio_seconds": audio.duration,
                                 "synthetic_transcript": expected.text, "count": raw.count, "raw_ms": raw,
                                 "median_ms": median,
                                 "p90_ms": ReportStatistics.nearestRank(raw, fraction: 0.9)!,
                                 "p95_ms": ReportStatistics.nearestRank(raw, fraction: 0.95)!,
                                 "repeat_text_parity": true])
            print("\(model.rawValue): \(file.lastPathComponent) median-ms=\(median)")
        }
        guard let longest, let shortest else { throw AppError.invalidAudio }
        let cancelled = Task { try await backend.transcribe(longest) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do { _ = try await cancelled.value; throw AppError.inference }
        catch is CancellationError {}
        catch { throw error }
        // The library must retain model ownership until cancelled work settles, then admit reuse.
        guard try await backend.transcribe(shortest).text == shortestText else { throw AppError.inference }
        try await backend.unload()
        guard await backend.readiness() == .unloaded else { throw AppError.inference }
        try await backend.prepare()
        guard try await backend.transcribe(shortest).text == shortestText else { throw AppError.inference }
        try await backend.unload()
        let result: [String: Any] = ["schema": 1, "mode": "real-parakeet-batch-synthetic", "preparation_ms": preparation,
            "repetitions": repetitions,
            "model": model.rawValue, "model_id": backend.modelID, "downloads_allowed": allowDownloads,
            "empty_and_silence": "passed", "cancel_settle_reuse": "passed", "unload_reprepare": "passed",
            "visible_text_measured": false, "ground_truth_accuracy_measured": false, "fixtures": observations]
        try JSONReport.write(result, to: output)
        print("real-batch fixtures=\(files.count) warm-observations=\(files.count * repetitions) cancellation=ok unload=ok")
    }
    #if PARAKEET_STREAMING
    private static let streamingChunkSamples = PCM16k.streamingChunkSamples
    private static let samplesPerMillisecond = Double(PCM16k.rate) / 1_000
    private struct StreamingFeed {
        var firstPartialMS: Double?
        var partialRevisions = 0
        var snapshots: [[String: Any]] = []
        var maximumAppendLagMS = 0.0
    }
    private static func feed(_ audio: PCM16k, into session: any ASRSession,
                             pacedFrom start: ContinuousClock.Instant? = nil,
                             recordPartials: Bool = false) async throws -> StreamingFeed {
        var stats = StreamingFeed()
        var offset = 0
        var revision = 0
        while offset < audio.samples.count {
            if let start {
                let targetMS = Double(offset) / samplesPerMillisecond
                let elapsedMS = start.duration(to: .now).milliseconds
                if targetMS > elapsedMS {
                    try await Task.sleep(for: .milliseconds(Int((targetMS - elapsedMS).rounded(.up))))
                }
            }
            let end = min(offset + streamingChunkSamples, audio.samples.count)
            try await session.append(PCM16k(Array(audio.samples[offset..<end])), startingAt: offset)
            offset = end
            if let start {
                stats.maximumAppendLagMS = max(stats.maximumAppendLagMS,
                    start.duration(to: .now).milliseconds - Double(offset) / samplesPerMillisecond)
            }
            if let update = try await session.partial(), update.revision > revision {
                revision = update.revision
                stats.partialRevisions += 1
                if let start {
                    let atMS = start.duration(to: .now).milliseconds
                    if stats.firstPartialMS == nil { stats.firstPartialMS = atMS }
                    if recordPartials { stats.snapshots.append(["at_ms": atMS, "text": update.text]) }
                }
            }
        }
        return stats
    }
    private static func cancelFallbackAndReset(_ backend: ParakeetStreamingBackend,
                                                audio: PCM16k) async throws -> (ASRResult, Double, Double) {
        let cancelled = try await backend.makeSession()
        try await cancelled.append(PCM16k([Float](repeating: 0, count: streamingChunkSamples)), startingAt: 0)
        await cancelled.cancel()
        do { _ = try await cancelled.finish(); throw AppError.inference }
        catch is CancellationError {}
        let fallbackStarted = ContinuousClock.now
        let result = try await backend.transcribe(audio)
        let fallbackMS = fallbackStarted.duration(to: .now).milliseconds
        let resetStarted = ContinuousClock.now
        let reset = try await backend.makeSession()
        let resetMS = resetStarted.duration(to: .now).milliseconds
        let empty = try await reset.finish()
        guard empty.text.isEmpty, empty.audioDuration == 0 else { throw AppError.inference }
        return (result, fallbackMS, resetMS)
    }
    static func streamingPrototype(cache: URL, corpus: URL, output: URL, repetitions: Int,
                                   recordPartials: Bool) async throws {
        let files = try PCM16k.corpus(in: corpus)
        let backend = ParakeetStreamingBackend(cacheRoot: cache)
        try await backend.prepare()
        var observations: [[String: Any]] = []
        for file in files {
            let audio = try PCM16k(contentsOfWAV: file)
            let reference = try await backend.transcribe(audio)
            var batchMS: [Double] = []
            var streaming: [[String: Any]] = []
            let before = repetitions / 2
            for _ in 0..<before {
                let started = ContinuousClock.now
                let result = try await backend.transcribe(audio)
                batchMS.append(milliseconds(started.duration(to: .now)))
                guard result == reference else { throw AppError.inference }
            }
            // This switch and the first session are outside measured capture/release spans.
            let warm = try await backend.makeSession()
            await warm.cancel()
            for _ in 0..<repetitions {
                let session = try await backend.makeSession()
                let started = ContinuousClock.now
                let feed = try await feed(audio, into: session, pacedFrom: started, recordPartials: recordPartials)
                let releaseMS = audio.duration * 1_000
                let elapsedMS = milliseconds(started.duration(to: .now))
                if releaseMS > elapsedMS {
                    try await Task.sleep(for: .milliseconds(Int((releaseMS - elapsedMS).rounded(.up))))
                }
                let finishStarted = ContinuousClock.now
                let final = try await session.finish()
                let totalMS = milliseconds(started.duration(to: .now))
                guard final.audioDuration == audio.duration else { throw AppError.inference }
                streaming.append(["total_ms": totalMS, "residual_after_release_ms": max(0, totalMS - releaseMS),
                    "finish_call_ms": milliseconds(finishStarted.duration(to: .now)),
                    "maximum_append_lag_ms": feed.maximumAppendLagMS,
                    "first_partial_ms": feed.firstPartialMS as Any? ?? NSNull(),
                    "partial_revisions": feed.partialRevisions, "partial_snapshots": feed.snapshots,
                    "text": final.text, "batch_text_equal": final.text == reference.text])
            }
            // Batch after streaming brackets the streaming run to expose thermal drift.
            _ = try await backend.transcribe(audio) // Switch/prepare outside timed samples.
            for _ in before..<repetitions {
                let started = ContinuousClock.now
                let result = try await backend.transcribe(audio)
                batchMS.append(milliseconds(started.duration(to: .now)))
                guard result == reference else { throw AppError.inference }
            }
            observations.append(["fixture": file.lastPathComponent, "audio_seconds": audio.duration,
                "batch_text": reference.text, "batch_ms": batchMS, "streaming": streaming])
            print("paced-streaming fixture=\(file.lastPathComponent) repetitions=\(repetitions)")
            fflush(stdout)
        }
        let (_, fallbackMS, resetMS) = try await cancelFallbackAndReset(backend, audio: PCM16k(contentsOfWAV: files[0]))
        let result: [String: Any] = ["schema": 1, "mode": "unified-paced-streaming-prototype",
            "repetitions": repetitions, "capture_paced": true, "cleanup_measured": false,
            "visible_text_measured": false, "ground_truth_accuracy_measured": false,
            "fallback_switch_and_batch_ms": fallbackMS, "batch_to_streaming_reset_ms": resetMS,
            "fixtures": observations]
        try JSONReport.write(result, to: output)
        print("paced-streaming result=\(output.path)")
    }
    static func realStreaming(cache: URL, corpus: URL, output: URL) async throws {
        let batch = ParakeetCoreBackend(cacheRoot: cache)
        try await batch.prepare()
        let files = try PCM16k.corpus(in: corpus)
        var references: [String: ASRResult] = [:]
        for file in files { references[file.lastPathComponent] = try await batch.transcribe(PCM16k(contentsOfWAV: file)) }
        try await batch.unload()
        let backend = ParakeetStreamingBackend(cacheRoot: cache)
        try await backend.prepare()
        var observations: [[String: Any]] = []
        for file in files {
            let audio = try PCM16k(contentsOfWAV: file)
            let session = try await backend.makeSession()
            let feed = try await feed(audio, into: session)
            let start = ContinuousClock.now
            let final = try await session.finish()
            let finishMS = milliseconds(start.duration(to: .now))
            guard final.audioDuration == audio.duration, !final.text.isEmpty else { throw AppError.inference }
            let reference = references[file.lastPathComponent]!
            observations.append(["fixture": file.lastPathComponent, "audio_seconds": audio.duration,
                "synthetic_transcript": final.text, "batch_text_equal": final.text == reference.text,
                "batch_words_equal": WordTokens.words(final.text) == WordTokens.words(reference.text),
                "partial_revisions": feed.partialRevisions,
                "adapter_finish_ms": finishMS])
        }
        // Switching to retained-audio batch fallback must settle the cancelled session first.
        let audio = try PCM16k(contentsOfWAV: files[0])
        let (fallback, _, _) = try await cancelFallbackAndReset(backend, audio: audio)
        guard fallback == references[files[0].lastPathComponent] else { throw AppError.inference }
        let result: [String: Any] = ["schema": 1, "mode": "real-parakeet-streaming-synthetic",
            "cancel_settle_batch_fallback": "passed", "batch_to_streaming_reset": "passed",
            "capture_paced": false, "ground_truth_accuracy_measured": false, "fixtures": observations]
        try JSONReport.write(result, to: output)
        print("real-streaming fixtures=\(files.count) cancellation-fallback-reset=ok")
    }
    #endif
}
