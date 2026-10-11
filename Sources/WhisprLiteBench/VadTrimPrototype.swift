import Foundation
import CoreML
import FluidAudio
import WhisprLiteCore

/// Bench-only: can Silero VAD silence trimming shorten final batch ASR enough to pay for itself?
/// Unified pads each recording to a fixed 15 s encoder window, so trimming saves only decoder
/// frames unless it removes a whole window. Synthetic audio only; the app is unchanged.
extension Bench {
    struct VadPrototypeError: LocalizedError {
        let errorDescription: String?
    }
    static let vadSegmentation = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.75,
        maxSpeechDuration: .infinity, speechPadding: 0.25)

    static func vadTrimPrototype(asrCache: URL, vadCache: URL, corpus: URL, output: URL,
                                 repetitions: Int, threshold: Float, allowDownloads: Bool) async throws {
        let vad = VadManager(config: VadConfig(defaultThreshold: threshold, computeUnits: .cpuOnly),
                             vadModel: try await loadSileroVAD(cache: vadCache, allowDownloads: allowDownloads))
        let backend = ParakeetCoreBackend(cacheRoot: asrCache)
        try await backend.prepare()
        var fixtures: [(id: String, audio: [Float])] = try FileManager.default
            .contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.deletingPathExtension().lastPathComponent, try readPCM($0).samples) }
        guard !fixtures.isEmpty else { throw AppError.invalidAudio }
        // Under-five-second clips joined by 2 s pauses over a quiet noise floor: a long dictation
        // that crosses one 15 s window boundary untrimmed but not after removing the pauses.
        let short = fixtures.filter { $0.audio.count < 5 * PCM16k.rate && !$0.id.hasSuffix("trailing-silence") }
        if short.count > 1 {
            var joined: [Float] = []
            for (index, clip) in short.enumerated() {
                if index > 0 { joined += [Float](repeating: 0, count: 2 * PCM16k.rate) }
                joined += clip.audio
            }
            fixtures.append(("joined-short-clips-2s-pauses", zip(joined, syntheticNoise(joined.count)).map(+)))
        }
        fixtures.append(("noise-only-3s", syntheticNoise(3 * PCM16k.rate)))

        var observations: [[String: Any]] = []
        for fixture in fixtures {
            let audio = fixture.audio
            _ = try await vad.process(audio) // Warm the CPU model outside timed samples.
            var passMS: [Double] = []
            var chunkMS: [Double] = []
            var reference: [VadResult] = []
            var repeatable = true
            for repetition in 0..<repetitions {
                let started = ContinuousClock.now
                let results = try await vad.process(audio)
                passMS.append(milliseconds(started.duration(to: .now)))
                chunkMS += results.map { $0.processingTime * 1_000 }
                if repetition == 0 { reference = results }
                else if results.map(\.probability) != reference.map(\.probability) { repeatable = false }
            }
            let segments = await vad.segmentSpeech(from: reference, totalSamples: audio.count, config: vadSegmentation)
            let ranges = mergedRanges(segments.map {
                max(0, $0.startSample(sampleRate: PCM16k.rate))..<min(audio.count, $0.endSample(sampleRate: PCM16k.rate))
            })
            let edges = ranges.isEmpty ? [] : Array(audio[ranges.first!.lowerBound..<ranges.last!.upperBound])
            let variants: [(id: String, audio: PCM16k)] = [("original", try PCM16k(audio)),
                ("edges", try PCM16k(edges)), ("pauses", try PCM16k(ranges.flatMap { audio[$0] }))]

            var texts: [String: String] = [:]
            for variant in variants where !variant.audio.samples.isEmpty {
                texts[variant.id] = try await backend.transcribe(variant.audio).text
            }
            var asrMS: [String: [Double]] = [:]
            for repetition in 0..<repetitions {
                // Rotate condition order so drift and thermal state do not favour one variant.
                for offset in variants.indices {
                    let variant = variants[(offset + repetition) % variants.count]
                    guard !variant.audio.samples.isEmpty else { continue } // No speech: ASR is skipped.
                    let started = ContinuousClock.now
                    let text = try await backend.transcribe(variant.audio).text
                    asrMS[variant.id, default: []].append(milliseconds(started.duration(to: .now)))
                    guard text == texts[variant.id] else { throw AppError.inference }
                }
            }
            let words: (String) -> [String] = { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
            let original = asrMS["original"] ?? []
            let vadPass = percentile(passMS, 0.5)
            let vadChunk = percentile(chunkMS, 0.5)
            var conditions: [String: Any] = [:]
            for variant in variants {
                let timings = asrMS[variant.id] ?? []
                var entry: [String: Any] = ["audio_seconds": variant.audio.duration,
                    "unified_windows": unifiedWindows(variant.audio.samples.count),
                    "synthetic_transcript": texts[variant.id] ?? "", "asr_skipped": timings.isEmpty,
                    "asr_median_ms": percentile(timings, 0.5), "asr_p95_ms": percentile(timings, 0.95)]
                if variant.id != "original" {
                    let text = texts[variant.id] ?? ""
                    let saving = original.indices.map { original[$0] - (timings.isEmpty ? 0 : timings[$0]) }
                    let pairedSaving = percentile(saving, 0.5)
                    entry["text_equal_to_original"] = text == texts["original"]
                    entry["words_equal_to_original"] = words(text) == words(texts["original"] ?? "")
                    entry["paired_asr_saving_median_ms"] = pairedSaving
                    // Projections: separately measured VAD cost subtracted from the paired ASR saving.
                    entry["projected_release_saving_vad_at_release_ms"] = pairedSaving - vadPass
                    entry["projected_release_saving_incremental_vad_ms"] = pairedSaving - vadChunk
                }
                conditions[variant.id] = entry
            }
            observations.append(["fixture": fixture.id, "audio_seconds": Double(audio.count) / Double(PCM16k.rate),
                "vad_chunks": reference.count, "vad_repeatable": repeatable,
                "speech_segments": ranges.map { [Double($0.lowerBound) / 16_000, Double($0.upperBound) / 16_000] },
                "vad_pass_median_ms": vadPass, "vad_pass_p95_ms": percentile(passMS, 0.95),
                "vad_chunk_median_ms": vadChunk, "vad_chunk_p95_ms": percentile(chunkMS, 0.95),
                "conditions": conditions])
            let summary = variants.map { variant in
                String(format: "%@=%.2fs/%dw/%.1fms", variant.id, variant.audio.duration,
                       unifiedWindows(variant.audio.samples.count), percentile(asrMS[variant.id] ?? [], 0.5))
            }.joined(separator: " ")
            print(String(format: "vad-trim fixture=%@ vad-pass=%.1fms chunk=%.2fms ", fixture.id, vadPass, vadChunk) + summary
                  + " edges-equal=\(texts["edges"] == texts["original"]) pauses-equal=\(texts["pauses"] == texts["original"])")
            fflush(stdout)
        }
        let report: [String: Any] = ["schema": 1, "mode": "vad-trim-asr-prototype", "repetitions_per_condition": repetitions,
            "vad_model": ModelNames.VAD.sileroVad, "vad_compute_units": "cpuOnly", "vad_threshold": threshold,
            "vad_negative_threshold": vadSegmentation.effectiveNegativeThreshold(baseThreshold: threshold),
            "segmentation": ["min_speech_s": vadSegmentation.minSpeechDuration,
                             "min_silence_s": vadSegmentation.minSilenceDuration,
                             "speech_padding_s": vadSegmentation.speechPadding],
            "asr_model_id": backend.modelID, "models_prepared_before_timing": true,
            "projections_not_observed": true, "cleanup_measured": false,
            "physical_capture_or_insertion_measured": false, "ground_truth_accuracy_measured": false,
            "fixtures": observations]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        try await backend.unload()
        print("vad-trim result=\(output.path)")
    }

    /// Loads the pinned Silero bundle from `cache/silero-vad-coreml`; downloads only when allowed.
    static func loadSileroVAD(cache: URL, allowDownloads: Bool) async throws -> MLModel {
        let bundle = cache.appendingPathComponent(Repo.vad.folderName)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            return try MLModel(contentsOf: bundle, configuration: configuration)
        }
        guard allowDownloads else {
            throw VadPrototypeError(errorDescription: "Silero VAD is not cached at \(bundle.path). Add --allow-model-downloads.")
        }
        let models = try await ModelHub.loadModels(.vad, modelNames: Array(ModelNames.VAD.requiredModels),
                                                   directory: cache, computeUnits: .cpuOnly)
        guard let model = models[ModelNames.VAD.sileroVadFile] else {
            throw VadPrototypeError(errorDescription: "Silero VAD download did not produce \(ModelNames.VAD.sileroVadFile).")
        }
        return model
    }
    static func mergedRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }
    /// Mirrors FluidAudio 0.17.7 `UnifiedBatchLayout`: frame-aligned 15 s windows with 2 s overlap.
    static func unifiedWindows(_ samples: Int) -> Int {
        guard samples > 0 else { return 0 }
        let frame = 1_280
        let chunk = 15 * PCM16k.rate / frame * frame
        let overlap = min(2 * PCM16k.rate, chunk / 2) / frame * frame
        var count = 1
        var start = chunk - overlap
        while start < samples {
            if start + overlap < samples { count += 1 }
            start += chunk - overlap
        }
        return count
    }
    /// Deterministic uniform noise around -55 dBFS RMS, standing in for a quiet room.
    static func syntheticNoise(_ count: Int, amplitude: Float = 0.003) -> [Float] {
        var state: UInt32 = 0x9E37_79B9
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }
}
