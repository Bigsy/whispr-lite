import Foundation
import AVFoundation
import Testing
@testable import WhisprLiteCore

@Suite struct DebugRecordingsTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func wavs(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
    }
    @Test func preferencesRequireExplicitOptInAndRoundTrip() throws {
        #expect(!Preferences().saveDebugRecordings)
        #expect(try !JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1}".utf8)).saveDebugRecordings)
        var preferences = Preferences(); preferences.saveDebugRecordings = true
        #expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).saveDebugRecordings)
    }
    @Test func savesPlayablePrivateWAVAndReportsStorage() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordings = DebugRecordings(directory: folder)
        let audio = try PCM16k([0, 0.25, -0.5, 1, -1])
        recordings.record(audio, session: UUID()); await recordings.flush()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        recordings.setEnabled(true)
        let session = UUID()
        recordings.record(audio, session: session); await recordings.flush()
        let file = folder.appendingPathComponent("\(session).wav")
        let reader = try AVAudioFile(forReading: file)
        #expect(reader.fileFormat.sampleRate == 16_000 && reader.fileFormat.channelCount == 1)
        #expect(reader.length == 5)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 5))
        try reader.read(into: buffer)
        for index in audio.samples.indices {
            #expect(abs(buffer.floatChannelData![0][index] - audio.samples[index]) < 0.0001)
        }
        #expect(recordings.snapshot.bytes == 54 && !recordings.snapshot.failed)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        recordings.setEnabled(false)
        recordings.record(audio, session: UUID()); await recordings.flush()
        #expect(try wavs(folder).count == 1)
        let reopened = DebugRecordings(directory: folder)
        reopened.refreshStorage(); await reopened.flush()
        #expect(reopened.snapshot.bytes == 54)
    }
    @Test func evictsOldestBeforeWritingAndOnReenable() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordings = DebugRecordings(directory: folder, maximumBytes: 100)
        recordings.setEnabled(true)
        let audio = try PCM16k([0.1, 0.2, 0.3]) // 50-byte files; at most two fit.
        let first = UUID(), second = UUID(), third = UUID()
        for (index, session) in [first, second].enumerated() {
            recordings.record(audio, session: session); await recordings.flush()
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(index + 1))],
                ofItemAtPath: folder.appendingPathComponent("\(session).wav").path)
        }
        recordings.record(audio, session: third); await recordings.flush()
        #expect(Set(try wavs(folder).map(\.lastPathComponent)) == ["\(second).wav", "\(third).wav"])
        #expect(recordings.snapshot.bytes == 100)
        let smaller = DebugRecordings(directory: folder, maximumBytes: 50)
        smaller.setEnabled(true); await smaller.flush()
        #expect(try wavs(folder).map(\.lastPathComponent) == ["\(third).wav"])
        #expect(smaller.snapshot.bytes == 50)
    }
    @Test func boundedQueueDiscardsPendingAudioWhenDisabled() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordings = DebugRecordings(directory: folder, maximumPending: 1)
        let audio = try PCM16k([0.1])
        recordings.setEnabled(true); await recordings.flush()
        recordings.queue.suspend()
        recordings.record(audio, session: UUID())
        recordings.record(audio, session: UUID())
        #expect(recordings.snapshot.skipped == 1)
        recordings.setEnabled(false)
        recordings.setEnabled(true) // Re-enabling must not revive the old queued recording.
        recordings.queue.resume()
        await recordings.flush()
        #expect(try wavs(folder).isEmpty)
        recordings.record(audio, session: UUID()); await recordings.flush()
        #expect(try wavs(folder).count == 1)
    }
    @Test func deletionDrainsOldWorkAndPreservesUnrelatedFiles() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unrelated = folder.appendingPathComponent("notes.txt")
        try Data("synthetic".utf8).write(to: unrelated)
        let recordings = DebugRecordings(directory: folder)
        recordings.setEnabled(true)
        for _ in 0..<10 { recordings.record(try PCM16k([0.1]), session: UUID()) }
        try await recordings.deleteAll()
        #expect(try wavs(folder).isEmpty)
        #expect(recordings.snapshot.bytes == 0 && recordings.snapshot.skipped == 0)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "synthetic")
        recordings.record(try PCM16k([0.2]), session: UUID()); await recordings.flush()
        #expect(try wavs(folder).count == 1)
    }
    @Test func emptyAndOversizeAudioAreNotWritten() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordings = DebugRecordings(directory: folder, maximumBytes: 46)
        recordings.setEnabled(true)
        recordings.record(try PCM16k([]), session: UUID())
        recordings.record(try PCM16k([0.1, 0.2]), session: UUID()); await recordings.flush()
        #expect(recordings.snapshot.skipped == 1 && !recordings.snapshot.failed)
        #expect(try wavs(folder).isEmpty)
    }
    @Test func fileErrorsStopSavingAndCanBeRetried() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder)
        let recordings = DebugRecordings(directory: folder)
        recordings.setEnabled(true); await recordings.flush()
        #expect(recordings.snapshot.failed)
        try FileManager.default.removeItem(at: folder)
        recordings.record(try PCM16k([0.1]), session: UUID()); await recordings.flush()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        recordings.setEnabled(true)
        recordings.record(try PCM16k([0.1]), session: UUID()); await recordings.flush()
        #expect(!recordings.snapshot.failed && recordings.snapshot.bytes == 46)
    }
    @Test func refusesSymlinkedDirectoryAndSessionFile() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let recordings = DebugRecordings(directory: link)
        recordings.setEnabled(true); await recordings.flush()
        #expect(recordings.snapshot.failed)
        #expect(throws: (any Error).self) { try PrivateFiles.directoryExists(at: link) }
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("\(UUID()).wav"), withDestinationURL: target)
        let other = DebugRecordings(directory: real)
        other.setEnabled(true); await other.flush()
        #expect(other.snapshot.failed)
        do { try await other.deleteAll(); Issue.record("Expected symlink rejection") } catch {}
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    @MainActor @Test func coordinatorSavesReleasedAudioOnSuccessAndCleanupFailure() async throws {
        for failure in [false, true] {
            let folder = directory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recordings = DebugRecordings(directory: folder); recordings.setEnabled(true)
            let insertion = FakeInsertion(), capture = FakeCapture()
            let cleanup: any TextCleanup = failure ? FailingCleanup() : DemoCleanup()
            let coordinator = DictationCoordinator(capture: capture, insertion: insertion, media: FakeMedia(),
                pipeline: .init(backend: EarlyBackend(), cleanup: cleanup))
            coordinator.recordings = recordings; coordinator.ready = true
            coordinator.press(); coordinator.release()
            try await poll { coordinator.state == (failure ? .error : .idle) }
            await recordings.flush()
            let session = try #require(insertion.snapshots.first?.session)
            #expect(try wavs(folder).map(\.lastPathComponent) == ["\(session).wav"])
        }
    }
    @MainActor @Test func coordinatorNeverSavesCancelledCaptureOrCleanup() async throws {
        for duringCleanup in [false, true] {
            let folder = directory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let recordings = DebugRecordings(directory: folder); recordings.setEnabled(true)
            let cleanup = RecordingCleanup(delay: .seconds(30))
            let coordinator = DictationCoordinator(capture: FakeCapture(), insertion: FakeInsertion(), media: FakeMedia(),
                pipeline: .init(backend: EarlyBackend(), cleanup: cleanup))
            coordinator.recordings = recordings; coordinator.ready = true
            coordinator.press()
            if duringCleanup {
                coordinator.release()
                try await poll { await cleanup.started }
            }
            coordinator.cancel()
            try await poll { coordinator.state == .idle }
            await recordings.flush()
            #expect(try wavs(folder).isEmpty)
        }
    }
}
