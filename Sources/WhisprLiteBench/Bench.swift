import Foundation
import AVFoundation
import WhisprLiteCore

@main struct Bench {
    static func main() async {
        do { try await run() }
        catch {
            print("Check failed: " + error.localizedDescription)
            exit(1)
        }
    }
    static func run() async throws {
        if CommandLine.arguments.contains("--cleanup-prefill-check") {
            try await cleanupPrefillCheck()
            return
        }
        if CommandLine.arguments.contains("--dictionary-check") {
            try await dictionaryCheck()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--press-warmup-prototype"), CommandLine.arguments.count > index + 3 {
            let repeatIndex = CommandLine.arguments.firstIndex(of: "--repetitions")
            let idleIndex = CommandLine.arguments.firstIndex(of: "--idle-seconds")
            let repetitions = repeatIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 30
            let idleSeconds = idleIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 1
            guard repetitions > 0, (0...1_500).contains(idleSeconds) else { throw AppError.invalidAudio }
            try await pressWarmupPrototype(cache: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true),
                corpus: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true),
                output: URL(fileURLWithPath: CommandLine.arguments[index + 3]),
                repetitions: repetitions, idleSeconds: idleSeconds)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--vad-trim-prototype"), CommandLine.arguments.count > index + 4 {
            let repeatIndex = CommandLine.arguments.firstIndex(of: "--repetitions")
            let thresholdIndex = CommandLine.arguments.firstIndex(of: "--vad-threshold")
            let repetitions = repeatIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 30
            let threshold = thresholdIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Float(CommandLine.arguments[$0 + 1]) : nil } ?? 0.5
            guard repetitions > 0, (0.05...0.95).contains(threshold) else { throw AppError.invalidAudio }
            try await vadTrimPrototype(asrCache: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true),
                vadCache: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true),
                corpus: URL(fileURLWithPath: CommandLine.arguments[index + 3], isDirectory: true),
                output: URL(fileURLWithPath: CommandLine.arguments[index + 4]), repetitions: repetitions,
                threshold: threshold, allowDownloads: CommandLine.arguments.contains("--allow-model-downloads"))
            return
        }
        #if PARAKEET_STREAMING_CANDIDATE
        if let index = CommandLine.arguments.firstIndex(of: "--streaming-prototype"), CommandLine.arguments.count > index + 3 {
            let repeatIndex = CommandLine.arguments.firstIndex(of: "--repetitions")
            let repetitions = repeatIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 30
            guard repetitions > 0 else { throw AppError.invalidAudio }
            try await streamingPrototype(cache: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true),
                corpus: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true),
                output: URL(fileURLWithPath: CommandLine.arguments[index + 3]), repetitions: repetitions)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--streaming-check"), CommandLine.arguments.count > index + 3 {
            try await realStreaming(cache: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true),
                corpus: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true),
                output: URL(fileURLWithPath: CommandLine.arguments[index + 3]))
            return
        }
        #endif
        if let index = CommandLine.arguments.firstIndex(of: "--parakeet-check"),
           CommandLine.arguments.count > index + 3 {
            let modelIndex = CommandLine.arguments.firstIndex(of: "--model")
            let model: ParakeetModel
            if let modelIndex {
                guard CommandLine.arguments.count > modelIndex + 1,
                      let selected = ParakeetModel(rawValue: CommandLine.arguments[modelIndex + 1]) else { throw AppError.unsupported }
                model = selected
            } else { model = .unified }
            try await realBatch(cache: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true),
                                corpus: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true),
                                output: URL(fileURLWithPath: CommandLine.arguments[index + 3]), model: model,
                                allowDownloads: CommandLine.arguments.contains("--allow-model-downloads"))
            return
        }
        if CommandLine.arguments.contains("--candidate-check") {
            let cache = ProcessInfo.processInfo.environment["PARAKEET_MODEL_CACHE"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let backend = try BackendFactory.make(mode: .parakeet, endpoint: "http://127.0.0.1:11435", cacheRoot: cache)
            try await backend.prepare()
            let result = try await backend.transcribe(PCM16k([Float](repeating: 0, count: 16_000)))
            print("candidate ready=\(await backend.readiness() == .ready) audio-seconds=\(result.audioDuration)")
            return
        }
        let backend = FakeASRBackend(); try await backend.prepare()
        let pipeline = BatchPipeline(backend: backend, cleanup: DemoCleanup())
        let audio = try PCM16k((0..<128_000).map { 0.05 * sin(Float($0) * 0.04) })
        var samples: [Double] = []
        _ = try await pipeline.run(audio)
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = try await pipeline.run(audio)
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        let sorted = samples.sorted()
        let result: [String: Any] = ["schema": 1, "mode": "fake-orchestration-only", "count": samples.count,
            "audio_seconds": audio.duration, "raw_ms": samples, "median_ms": sorted[15],
            "p90_ms": sorted[26], "p95_ms": sorted[28], "visible_text_measured": false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
    @MainActor static func cleanupPrefillCheck() async throws {
        let store = try SettingsStore()
        let preferences = store.preferences
        let cleanup = HTTPCleanup(.init(endpoint: try LocalEndpoint(preferences.cleanupEndpoint),
            prompt: try store.privateText("prompt.txt") ?? SettingsStore.defaultPrompt,
            dictionary: try store.privateText("dictionary.txt") ?? "", inputFormat: preferences.cleanupInputFormat,
            dictionaryPrefix: preferences.cleanupDictionaryPrefix))
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
        let dictionary = try store.privateText("dictionary.txt") ?? ""
        guard DictionaryCorrections(dictionary).apply(to: "dochler") == "Doccla" else { throw AppError.notReady }
        let cleanup = HTTPCleanup(.init(endpoint: try LocalEndpoint(preferences.cleanupEndpoint),
            prompt: try store.privateText("prompt.txt") ?? SettingsStore.defaultPrompt,
            dictionary: dictionary + "\nhappy fire > hapi fhir", inputFormat: preferences.cleanupInputFormat,
            dictionaryPrefix: preferences.cleanupDictionaryPrefix))
        let fixtures = ["i work at dochler", "send the report to dochler", "dochler", "the doctor called me", "we use happy fire"]
        var passed = 0
        for (index, input) in fixtures.enumerated() {
            let output = try await cleanup.clean(input)
            let correct: Bool
            if index == 3 {
                correct = output.localizedCaseInsensitiveContains("doctor") && !output.contains("Doccla")
            } else if index == 4 {
                correct = output.contains("hapi fhir") && !output.localizedCaseInsensitiveContains("happy fire")
            } else {
                correct = output.contains("Doccla") && !output.localizedCaseInsensitiveContains("dochler")
            }
            guard correct else { throw AppError.cleanup }
            passed += 1
        }
        print("Dictionary check: \(passed)/\(fixtures.count) synthetic cases passed; private text not recorded.")
    }
    static func readPCM(_ file: URL) throws -> PCM16k {
        let input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.processingFormat.sampleRate == 16_000, input.processingFormat.channelCount == 1,
              input.length <= PCM16k.maximumSamples,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))
        else { throw AppError.invalidAudio }
        try input.read(into: buffer)
        guard let samples = buffer.floatChannelData else { throw AppError.invalidAudio }
        return try PCM16k(Array(UnsafeBufferPointer(start: samples[0], count: Int(buffer.frameLength))))
    }
    static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
    static func pressWarmupPrototype(cache: URL, corpus: URL, output: URL,
                                     repetitions: Int, idleSeconds: Double) async throws {
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw AppError.invalidAudio }
        let backend = ParakeetCoreBackend(cacheRoot: cache)
        try await backend.prepare()
        let silence = try PCM16k([Float](repeating: 0, count: 16_000))
        var fixtures: [[String: Any]] = []
        for file in files {
            let audio = try readPCM(file)
            let expected = try await backend.transcribe(audio)
            guard !expected.text.isEmpty else { throw AppError.inference }
            var observations: [[String: Any]] = []
            for repetition in 0..<repetitions {
                for candidate in repetition.isMultiple(of: 2) ? [false, true] : [true, false] {
                    if idleSeconds > 0 {
                        try await Task.sleep(for: .milliseconds(Int((idleSeconds * 1_000).rounded(.up))))
                    }
                    let press = ContinuousClock.now
                    let warmup = candidate ? Task {
                        let started = ContinuousClock.now
                        let result = try await backend.transcribe(silence)
                        guard result.text.isEmpty else { throw AppError.inference }
                        return milliseconds(started.duration(to: .now))
                    } : nil
                    let releaseMS = audio.duration * 1_000
                    // Keep capture active on a 40 ms schedule. A single long sleep
                    // can overshoot release and confound an idle warm-up comparison.
                    while true {
                        let remaining = releaseMS - milliseconds(press.duration(to: .now))
                        if remaining <= 0 { break }
                        try await Task.sleep(for: .milliseconds(max(1, min(40, Int(remaining.rounded(.up))))))
                    }
                    let release = ContinuousClock.now
                    let warmupMS = try await warmup?.value ?? 0
                    let warmupWaitMS = milliseconds(release.duration(to: .now))
                    let finalStarted = ContinuousClock.now
                    let result = try await backend.transcribe(audio)
                    let finalASRMS = milliseconds(finalStarted.duration(to: .now))
                    guard result == expected else { throw AppError.inference }
                    observations.append(["repetition": repetition, "condition": candidate ? "press_warmup" : "baseline",
                        "release_to_asr_ms": max(0, milliseconds(press.duration(to: .now)) - releaseMS),
                        "release_tick_lag_ms": max(0, milliseconds(press.duration(to: release)) - releaseMS),
                        "final_asr_ms": finalASRMS, "warmup_ms": warmupMS,
                        "warmup_wait_after_release_ms": warmupWaitMS])
                }
                print("press-warmup fixture=\(file.lastPathComponent) round=\(repetition + 1)/\(repetitions)")
                fflush(stdout)
            }
            fixtures.append(["fixture": file.lastPathComponent, "audio_seconds": audio.duration,
                "synthetic_transcript": expected.text, "observations": observations])
        }
        let report: [String: Any] = ["schema": 1, "mode": "press-warmup-asr-prototype",
            "repetitions_per_condition": repetitions, "idle_seconds_before_press": idleSeconds,
            "capture_simulated_by_40ms_ticks": true, "model_prepared_before_timing": true,
            "cleanup_measured": false, "physical_capture_or_insertion_measured": false,
            "fixtures": fixtures]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("press-warmup result=\(output.path)")
    }
    static func realBatch(cache: URL, corpus: URL, output: URL, model: ParakeetModel = .unified, allowDownloads: Bool = false) async throws {
        let backend = ParakeetCoreBackend(cacheRoot: cache, allowDownloads: allowDownloads, model: model)
        print("Preparing \(backend.modelID); downloads=\(allowDownloads)", terminator: "\n")
        let started = ContinuousClock.now
        try await backend.prepare()
        let preparation = milliseconds(started.duration(to: .now))
        guard await backend.readiness() == .ready else { throw AppError.notReady }
        try await backend.prepare() // Repeated preparation must remain ready.
        let empty = try await backend.transcribe(PCM16k([]))
        guard empty.text.isEmpty, empty.audioDuration == 0 else { throw AppError.inference }
        let silence = try await backend.transcribe(PCM16k([Float](repeating: 0, count: 16_000)))
        guard silence.text.isEmpty else { throw AppError.inference }
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw AppError.invalidAudio }
        var observations: [[String: Any]] = []
        var longest: PCM16k?
        var shortest: PCM16k?
        var shortestText = ""
        for file in files {
            let audio = try readPCM(file)
            if longest == nil || audio.duration > longest!.duration { longest = audio }
            let expected = try await backend.transcribe(audio)
            guard !expected.text.isEmpty, expected.audioDuration == audio.duration else { throw AppError.inference }
            if shortest == nil || audio.duration < shortest!.duration { shortest = audio; shortestText = expected.text }
            var raw: [Double] = []
            for _ in 0..<30 {
                let start = ContinuousClock.now
                let result = try await backend.transcribe(audio)
                raw.append(milliseconds(start.duration(to: .now)))
                guard result == expected else { throw AppError.inference }
            }
            let sorted = raw.sorted()
            observations.append(["fixture": file.lastPathComponent, "audio_seconds": audio.duration,
                                 "synthetic_transcript": expected.text, "count": raw.count, "raw_ms": raw,
                                 "median_ms": sorted[15], "p90_ms": sorted[26], "p95_ms": sorted[28],
                                 "repeat_text_parity": true])
            print("\(model.rawValue): \(file.lastPathComponent) median-ms=\(sorted[15])")
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
            "model": model.rawValue, "model_id": backend.modelID, "downloads_allowed": allowDownloads,
            "empty_and_silence": "passed", "cancel_settle_reuse": "passed", "unload_reprepare": "passed",
            "visible_text_measured": false, "ground_truth_accuracy_measured": false, "fixtures": observations]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("real-batch fixtures=\(files.count) warm-observations=\(files.count * 30) cancellation=ok unload=ok")
    }
    #if PARAKEET_STREAMING_CANDIDATE
    static func streamingPrototype(cache: URL, corpus: URL, output: URL, repetitions: Int) async throws {
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw AppError.invalidAudio }
        let backend = ParakeetStreamingBackend(cacheRoot: cache)
        try await backend.prepare()
        var observations: [[String: Any]] = []
        for file in files {
            let audio = try readPCM(file)
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
                var offset = 0
                var firstPartialMS: Double?
                var partials = 0
                var revision = 0
                var partialSnapshots: [[String: Any]] = []
                var maximumAppendLagMS = 0.0
                while offset < audio.samples.count {
                    let targetMS = Double(offset) / 16
                    let elapsedMS = milliseconds(started.duration(to: .now))
                    if targetMS > elapsedMS {
                        try await Task.sleep(for: .milliseconds(Int((targetMS - elapsedMS).rounded(.up))))
                    }
                    let end = min(offset + 640, audio.samples.count)
                    try await session.append(PCM16k(Array(audio.samples[offset..<end])), startingAt: offset)
                    offset = end
                    maximumAppendLagMS = max(maximumAppendLagMS,
                        milliseconds(started.duration(to: .now)) - Double(offset) / 16)
                    if let update = try await session.partial(), update.revision > revision {
                        revision = update.revision; partials += 1
                        if firstPartialMS == nil { firstPartialMS = milliseconds(started.duration(to: .now)) }
                        if repetitions <= 2 {
                            partialSnapshots.append(["at_ms": milliseconds(started.duration(to: .now)), "text": update.text])
                        }
                    }
                }
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
                    "maximum_append_lag_ms": maximumAppendLagMS, "first_partial_ms": firstPartialMS as Any? ?? NSNull(),
                    "partial_revisions": partials, "partial_snapshots": partialSnapshots,
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
        let cancellation = try await backend.makeSession()
        try await cancellation.append(PCM16k([Float](repeating: 0, count: 640)), startingAt: 0)
        await cancellation.cancel()
        let fallbackStarted = ContinuousClock.now
        _ = try await backend.transcribe(readPCM(files[0]))
        let fallbackMS = milliseconds(fallbackStarted.duration(to: .now))
        let resetStarted = ContinuousClock.now
        let reset = try await backend.makeSession()
        let resetMS = milliseconds(resetStarted.duration(to: .now))
        await reset.cancel()
        let result: [String: Any] = ["schema": 1, "mode": "unified-paced-streaming-prototype",
            "repetitions": repetitions, "capture_paced": true, "cleanup_measured": false,
            "visible_text_measured": false, "ground_truth_accuracy_measured": false,
            "fallback_switch_and_batch_ms": fallbackMS, "batch_to_streaming_reset_ms": resetMS,
            "fixtures": observations]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("paced-streaming result=\(output.path)")
    }
    static func realStreaming(cache: URL, corpus: URL, output: URL) async throws {
        let batch = ParakeetCoreBackend(cacheRoot: cache)
        try await batch.prepare()
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw AppError.invalidAudio }
        var references: [String: ASRResult] = [:]
        for file in files { references[file.lastPathComponent] = try await batch.transcribe(readPCM(file)) }
        try await batch.unload()
        let backend = ParakeetStreamingBackend(cacheRoot: cache)
        try await backend.prepare()
        var observations: [[String: Any]] = []
        for file in files {
            let audio = try readPCM(file)
            let session = try await backend.makeSession()
            var offset = 0
            var revision = 0
            var partials = 0
            while offset < audio.samples.count {
                let end = min(offset + 640, audio.samples.count)
                try await session.append(PCM16k(Array(audio.samples[offset..<end])), startingAt: offset)
                offset = end
                if let update = try await session.partial(), update.revision > revision {
                    revision = update.revision; partials += 1
                }
            }
            let start = ContinuousClock.now
            let final = try await session.finish()
            let finishMS = milliseconds(start.duration(to: .now))
            guard final.audioDuration == audio.duration, !final.text.isEmpty else { throw AppError.inference }
            let reference = references[file.lastPathComponent]!
            let words: (String) -> [String] = { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
            observations.append(["fixture": file.lastPathComponent, "audio_seconds": audio.duration,
                "synthetic_transcript": final.text, "batch_text_equal": final.text == reference.text,
                "batch_words_equal": words(final.text) == words(reference.text), "partial_revisions": partials,
                "adapter_finish_ms": finishMS])
        }
        let cancelled = try await backend.makeSession()
        try await cancelled.append(PCM16k([Float](repeating: 0, count: 640)), startingAt: 0)
        await cancelled.cancel()
        do { _ = try await cancelled.finish(); throw AppError.inference }
        catch is CancellationError {}
        // Switching to retained-audio batch fallback must settle the cancelled session first.
        let audio = try readPCM(files[0])
        guard try await backend.transcribe(audio) == references[files[0].lastPathComponent] else { throw AppError.inference }
        let reset = try await backend.makeSession() // Batch -> streaming mode must prepare again.
        let empty = try await reset.finish()
        guard empty.text.isEmpty, empty.audioDuration == 0 else { throw AppError.inference }
        let result: [String: Any] = ["schema": 1, "mode": "real-parakeet-streaming-synthetic",
            "cancel_settle_batch_fallback": "passed", "batch_to_streaming_reset": "passed",
            "capture_paced": false, "ground_truth_accuracy_measured": false, "fixtures": observations]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("real-streaming fixtures=\(files.count) cancellation-fallback-reset=ok")
    }
    #endif
}
