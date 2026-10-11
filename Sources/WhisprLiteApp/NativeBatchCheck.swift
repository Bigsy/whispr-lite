import AppKit
import WhisprLiteCore

/// Opt-in synthetic integration check in the signed app. No microphone or saved app settings.
@MainActor enum NativeBatchCheck {
    private static let expectedFixtureCount = 6
    static func run(arguments: BatchFlowArguments) async throws {
        guard PermissionStatus.current.accessibility else {
            print("batch-flow blocked: enable Accessibility for this signed Whispr Lite app, then retry")
            throw CheckFailure("Accessibility permission is required for native insertion")
        }
        let store = try SettingsStore(directory: arguments.privateDirectory)
        struct Import: Decodable { let cleanupInputFormat: CleanupInputFormat; let cleanupDictionaryPrefix: String }
        let metadataURL = arguments.privateDirectory.appendingPathComponent("cleanup-import.json")
        guard try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map({ $0 <= 65_536 }) == true else {
            throw CheckFailure("Cleanup import metadata is missing or too large")
        }
        let metadata = try JSONDecoder().decode(Import.self, from: Data(contentsOf: metadataURL))
        let cleanup = HTTPCleanup(.init(endpoint: arguments.endpoint,
            prompt: try store.prompt(), dictionary: try store.dictionary(),
            inputFormat: metadata.cleanupInputFormat,
            dictionaryPrefix: metadata.cleanupDictionaryPrefix))
        try await cleanup.checkReadiness()
        let backend = ParakeetCoreBackend(cacheRoot: arguments.cache)
        try await backend.prepare()
        let pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        guard try await pipeline.run(PCM16k([])) == nil,
              try await pipeline.run(PCM16k([Float](repeating: 0, count: PCM16k.rate / 2))) == nil else {
            throw CheckFailure("Batch-flow empty or silence check failed")
        }
        let files = try PCM16k.corpus(in: arguments.corpus)
        guard files.count == Self.expectedFixtureCount else {
            throw CheckFailure("Batch-flow corpus must contain \(Self.expectedFixtureCount) WAV fixtures")
        }
        let audio = try files.map { try PCM16k(contentsOfWAV: $0) }
        let field = NSTextView(frame: NSRect(x: 20, y: 20, width: 610, height: 200))
        field.font = .systemFont(ofSize: 18)
        let window = BenchmarkTextWindow.make(title: "Whispr Lite: synthetic batch check",
            size: NSSize(width: 650, height: 240), field: field)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
        defer { window.close() }
        let insertion = TextInserter()
        defer { insertion.clipboard.settle() }
        var observations: [[String: Any]] = []
        var references: [Int: String] = [:]
        let clock = ContinuousClock()
        let stages = LatencyRecorder(enabled: true)
        for repetition in 0...30 {
            for index in files.indices {
                field.string = ""; field.setSelectedRange(NSRange(location: 0, length: 0))
                // Give the initial activation/focus notifications a bounded chance to settle.
                _ = try await BenchmarkTextWindow.waitForFocus(window: window, field: field)
                let session = UUID()
                let target = insertion.snapshot(session: session)
                let start = clock.now
                guard let text = try await pipeline.run(audio[index], mark: { stage in
                    await stages.mark(stage, session: session)
                }) else { throw CheckFailure("Synthetic batch pipeline produced no text") }
                let resultTime = clock.now
                if let reference = references[index] {
                    guard reference == text else { throw CheckFailure("Synthetic batch output changed across rounds") }
                }
                else { references[index] = text }
                do { try await insertion.insert(text, target: target) }
                catch {
                    let ownFocus = BenchmarkTextWindow.ownsFocus(window: window, field: field)
                    print("batch-flow insertion failed round=\(repetition) " +
                        "fixture=\(files[index].lastPathComponent) own-focus=\(ownFocus) " +
                        "key-window=\(window.isKeyWindow) own-responder=\(window.firstResponder === field)")
                    throw error
                }
                let until = clock.now.advanced(by: .seconds(1))
                while field.string != text && clock.now < until { try await Task.sleep(for: .milliseconds(2)) }
                guard field.string == text else {
                    print("batch-flow native update did not match round=\(repetition)")
                    throw CheckFailure("Native text update did not match the synthetic result")
                }
                field.displayIfNeeded(); window.displayIfNeeded()
                let end = clock.now
                func span(_ first: TimingStage, _ last: TimingStage) throws -> Double {
                    guard let value = stages.span(from: first, to: last, session: session) else {
                        throw CheckFailure("Batch-flow timing span is missing")
                    }
                    return value
                }
                observations.append(["fixture": files[index].lastPathComponent, "condition": repetition == 0 ? "warmup" : "warm",
                    "audio_seconds": audio[index].duration, "asr_ms": try span(.asrStart, .asrEnd),
                    "cleanup_ms": try span(.cleanupStart, .cleanupEnd),
                    "pipeline_ms": start.duration(to: resultTime).milliseconds,
                    "result_to_native_update_ms": resultTime.duration(to: end).milliseconds,
                    "synthetic_pcm_to_native_update_ms": start.duration(to: end).milliseconds, "text_equal": true])
            }
            print("batch-flow round=\(repetition) native-text-updates=\(observations.count)")
        }
        try await backend.unload()
        let report: [String: Any] = ["schema": 2, "mode": "signed-native-synthetic-batch-flow", "observations": observations,
            "empty_silence": "passed", "repeat_output_parity": true, "native_text_update_and_draw": true,
            "physical_release_capture_measured": false, "display_compositor_latency_measured": false,
            "third_party_insertion_measured": false, "private_content_recorded": false]
        try JSONReport.write(report, to: arguments.output)
    }
}
