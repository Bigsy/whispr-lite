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
        #if PARAKEET_STREAMING_CANDIDATE
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
            guard BackendFactory.hasParakeetCore else { throw AppError.unsupported }
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
