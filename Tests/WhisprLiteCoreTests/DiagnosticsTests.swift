import Testing
import Foundation
@testable import WhisprLiteCore

@Suite struct DiagnosticsTests {
    @MainActor @Test func disabledIsLazyAndOldPreferencesKeepLoggingOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logger = DiagnosticLogger(directory: directory)
        var constructed = false
        func record() -> DiagnosticRecord { constructed = true; return .init(.hotkey) }
        logger.record(record()); await logger.flush()
        #expect(!constructed && !FileManager.default.fileExists(atPath: directory.path))
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1}".utf8))
        #expect(!old.debugLogging && old.showAudioActivity)
        var clockReads = 0, callbacks = 0
        let timings = LatencyRecorder(now: { clockReads += 1; return Double(clockReads) })
        timings.onEvent = { _ in callbacks += 1 }
        timings.mark(.press, session: UUID())
        #expect(clockReads == 0 && callbacks == 0 && timings.events.isEmpty)
        timings.setEnabled(true); timings.mark(.press, session: UUID())
        #expect(clockReads == 2 && callbacks == 1 && timings.events.count == 1)
        timings.setEnabled(false); timings.mark(.release, session: UUID())
        #expect(clockReads == 2 && callbacks == 1 && timings.events.isEmpty)
    }
    @Test func safeRecordsRotateAndNeverContainFailurePayloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, maximumBytes: 1024)
        logger.setEnabled(true)
        #expect(MediaDiagnosticReason(rawValue: "PRIVATE MEDIA TITLE") == nil)
        for _ in 0..<20 {
            logger.record(.init(.failure, session: UUID(), code: .failure(.deadline("PRIVATE TRANSCRIPT / PASSWORD / MEDIA TITLE"))))
            await logger.flush()
        }
        var media = DiagnosticRecord(.mediaReply, session: UUID(), code: .skipped)
        media.mediaReason = .itemChanged
        logger.record(media); await logger.flush()
        var keyboard = DiagnosticRecord(.modifierState, session: UUID(), code: .ready)
        keyboard.hardwareModifiers = InsertionModifier.held(in: [.maskControl, .maskAlphaShift])
        keyboard.sessionModifiers = InsertionModifier.held(in: [.maskCommand, .maskControl])
        #expect(keyboard.hardwareModifiers == [.control])
        logger.record(keyboard); await logger.flush()
        logger.setEnabled(false); await logger.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        #expect(Set(files.map(\.lastPathComponent)) == ["debug.jsonl", "debug.previous.jsonl"])
        for file in files {
            #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 1024)
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(!contents.contains("PRIVATE") && !contents.contains("PASSWORD") && !contents.contains("MEDIA TITLE"))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for line in contents.split(separator: "\n") { _ = try decoder.decode(DiagnosticRecord.self, from: Data(line.utf8)) }
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        // Record sizes vary with uptime digits, so the rotation point can put it in either file.
        let logged = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(logged.contains("itemChanged"))
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }
    @Test func saturationAndDiskFailureDoNotBlockCaller() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory) // A file cannot be the log directory.
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(directory: directory, maximumPending: 1)
        logger.setEnabled(true)
        for _ in 0..<1000 { logger.record(.init(.hotkey, code: .press)) }
        await logger.flush()
        #expect(logger.hasFailed && !logger.isEnabled)
        #expect(logger.droppedEvents > 0)
    }
    @MainActor @Test func timingEventsCorrelateSessionsAndCaptureTimestamp() {
        let recorder = LatencyRecorder(enabled: true), session = UUID()
        var observed: [TimingEvent] = []
        recorder.onEvent = { observed.append($0) }
        recorder.mark(.press, session: session)
        let timestamp = ProcessInfo.processInfo.systemUptime
        recorder.mark(.release, session: session)
        recorder.mark(.firstAudio, session: session, uptime: timestamp)
        #expect(observed.count == 3 && observed.allSatisfy { $0.session == session })
        #expect(observed[2].seconds >= observed[0].seconds && observed[2].seconds <= observed[1].seconds)
    }
}
