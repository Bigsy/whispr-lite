import AppKit
import AVFoundation
import ApplicationServices
import WhisprLiteCore

/// Opt-in synthetic integration check in the signed app. No microphone or saved app settings.
@MainActor enum NativeBatchCheck {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 5 else { throw AppError.unsupported }
        guard AXIsProcessTrusted() else {
            print("batch-flow blocked: enable Accessibility for this signed Whispr Lite app, then retry")
            throw AppError.notReady
        }
        let cache = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let corpus = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let privateDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[4])
        let store = try SettingsStore(directory: privateDirectory)
        struct Import: Decodable { let cleanupInputFormat: CleanupInputFormat; let cleanupDictionaryPrefix: String }
        let metadataURL = privateDirectory.appendingPathComponent("cleanup-import.json")
        guard try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map({ $0 <= 65_536 }) == true else { throw AppError.contextLimit }
        let metadata = try JSONDecoder().decode(Import.self, from: Data(contentsOf: metadataURL))
        let cleanup = HTTPCleanup(.init(endpoint: try LocalEndpoint(arguments[3]),
            prompt: try store.privateText("prompt.txt") ?? SettingsStore.defaultPrompt,
            dictionary: try store.privateText("dictionary.txt") ?? "", inputFormat: metadata.cleanupInputFormat,
            dictionaryPrefix: metadata.cleanupDictionaryPrefix))
        try await LocalHTTP.shared.cleanupReadiness(LocalEndpoint(arguments[3]))
        let backend = ParakeetCoreBackend(cacheRoot: cache)
        try await backend.prepare()
        let pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        guard try await pipeline.run(PCM16k([])) == nil,
              try await pipeline.run(PCM16k([Float](repeating: 0, count: 8000))) == nil else { throw AppError.inference }
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count == 6 else { throw AppError.invalidAudio }
        let audio = try files.map { file -> PCM16k in
            let input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard input.processingFormat.sampleRate == 16_000, input.processingFormat.channelCount == 1,
                  input.length <= PCM16k.maximumSamples,
                  let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)) else { throw AppError.invalidAudio }
            try input.read(into: buffer)
            guard let samples = buffer.floatChannelData else { throw AppError.invalidAudio }
            return try PCM16k(Array(UnsafeBufferPointer(start: samples[0], count: Int(buffer.frameLength))))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Whispr Lite — synthetic batch check"
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
                let target = insertion.snapshot()
                let session = UUID()
                let start = clock.now
                guard let text = try await pipeline.run(audio[index], mark: { stage in
                    await stages.mark(stage, session: session)
                }) else { throw AppError.inference }
                let resultTime = clock.now
                if let reference = references[index] { guard reference == text else { throw AppError.cleanup } }
                else { references[index] = text }
                do { try await insertion.insert(text, target: target) }
                catch {
                    print("batch-flow insertion failed round=\(repetition) fixture=\(files[index].lastPathComponent) own-focus=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier) key-window=\(window.isKeyWindow) own-responder=\(window.firstResponder === field)")
                    throw error
                }
                let until = clock.now.advanced(by: .seconds(1))
                while field.string != text && clock.now < until { try await Task.sleep(for: .milliseconds(2)) }
                guard field.string == text else { print("batch-flow native update did not match round=\(repetition)"); throw AppError.targetChanged }
                field.displayIfNeeded(); window.displayIfNeeded()
                let end = clock.now
                let events = stages.events.filter { $0.session == session }
                func span(_ first: TimingStage, _ last: TimingStage) throws -> Double {
                    guard let from = events.first(where: { $0.stage == first }),
                          let to = events.first(where: { $0.stage == last }) else { throw AppError.inference }
                    return (to.seconds - from.seconds) * 1000
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
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
