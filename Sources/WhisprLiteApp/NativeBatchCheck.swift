import AppKit
import ApplicationServices
import WhisprLiteCore

/// Opt-in synthetic integration check in the signed app. No microphone or saved app settings.
@MainActor enum NativeBatchCheck {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 5 else { throw CheckFailure("Batch-flow check requires five arguments") }
        guard AXIsProcessTrusted() else {
            print("batch-flow blocked: enable Accessibility for this signed Whispr Lite app, then retry")
            throw CheckFailure("Accessibility permission is required for native insertion")
        }
        let cache = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let corpus = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let privateDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[4])
        let store = try SettingsStore(directory: privateDirectory)
        struct Import: Decodable { let cleanupInputFormat: CleanupInputFormat; let cleanupDictionaryPrefix: String }
        let metadataURL = privateDirectory.appendingPathComponent("cleanup-import.json")
        guard try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map({ $0 <= 65_536 }) == true else {
            throw CheckFailure("Cleanup import metadata is missing or too large")
        }
        let metadata = try JSONDecoder().decode(Import.self, from: Data(contentsOf: metadataURL))
        var preferences = store.preferences
        preferences.cleanupEndpoint = arguments[3]
        preferences.cleanupInputFormat = metadata.cleanupInputFormat
        preferences.cleanupDictionaryPrefix = metadata.cleanupDictionaryPrefix
        let cleanup = HTTPCleanup(try .init(preferences: preferences, prompt: store.prompt(), dictionary: store.dictionary()))
        try await cleanup.checkReadiness()
        let backend = ParakeetCoreBackend(cacheRoot: cache)
        try await backend.prepare()
        let pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        guard try await pipeline.run(PCM16k([])) == nil,
              try await pipeline.run(PCM16k([Float](repeating: 0, count: PCM16k.rate / 2))) == nil else {
            throw CheckFailure("Batch-flow empty or silence check failed")
        }
        let files = try PCM16k.corpus(in: corpus)
        guard files.count == 6 else { throw CheckFailure("Batch-flow corpus must contain six WAV fixtures") }
        let audio = try files.map { try PCM16k(contentsOfWAV: $0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Whispr Lite: synthetic batch check"
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 20, y: 20, width: 610, height: 200))
        field.font = .systemFont(ofSize: 18)
        window.contentView?.addSubview(field); window.center()
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
                for _ in 0..<100 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                       window.isKeyWindow, window.firstResponder === field { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
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
                    print("batch-flow insertion failed round=\(repetition) fixture=\(files[index].lastPathComponent) own-focus=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier) key-window=\(window.isKeyWindow) own-responder=\(window.firstResponder === field)")
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
        try JSONReport.write(report, to: output)
    }
}
