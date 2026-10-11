import Testing
import Foundation
@testable import WhisprLiteCore

@Suite struct DictationHistoryTests {
    func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func entries(in directory: URL) throws -> [DictationHistory.Entry] {
        try [DictationHistory.previousFileName, DictationHistory.fileName].flatMap { name in
            try decodeJSONLines(directory.appendingPathComponent(name), as: DictationHistory.Entry.self)
        }
    }
    @Test func newAndOldPreferencesKeepHistoryOnByDefault() throws {
        #expect(Preferences().saveDictationHistory)
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1}".utf8)).saveDictationHistory)
        var off = Preferences(); off.saveDictationHistory = false
        #expect(try !JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(off)).saveDictationHistory)
    }
    @Test func savesPairsPrivatelyOutsideBackupsAndDeletes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DictationHistory(directory: directory)
        history.record(.init(raw: "before enabling", cleaned: "Before enabling.")); await history.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        history.configure(enabled: true, asr: "parakeet-unified", prompt: "synthetic prompt")
        history.record(.init(raw: "send it by thursday no wait friday", cleaned: "Send it by Friday."))
        await history.flush()
        let saved = try entries(in: directory)
        #expect(saved.count == 1 && saved[0].raw == "send it by thursday no wait friday" && saved[0].cleaned == "Send it by Friday.")
        #expect(saved[0].asr == "parakeet-unified" && saved[0].promptSHA256.count == 16)
        let file = directory.appendingPathComponent(DictationHistory.fileName)
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("synthetic prompt"))
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        history.configure(enabled: false, asr: "parakeet-unified", prompt: "synthetic prompt")
        history.record(.init(raw: "after disabling", cleaned: "After disabling.")); await history.flush()
        #expect(try entries(in: directory).count == 1)
        try await history.deleteAll()
        #expect(try entries(in: directory).isEmpty)
        history.configure(enabled: true, asr: "parakeet-unified", prompt: "synthetic prompt")
        history.record(.init(raw: "after deleting", cleaned: "After deleting.")); await history.flush()
        #expect(try entries(in: directory).map(\.raw) == ["after deleting"])
    }
    @Test func rotationKeepsTheNewestEntriesInOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DictationHistory(directory: directory, maximumBytes: 1024)
        history.configure(enabled: true, asr: "http", prompt: "")
        for index in 0..<40 {
            history.record(.init(raw: "synthetic \(index)", cleaned: "Synthetic \(index).")); await history.flush()
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        #expect(Set(files.map(\.lastPathComponent)) == [DictationHistory.fileName, DictationHistory.previousFileName])
        for file in files { #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 1024) }
        let indices = try entries(in: directory).map { Int($0.raw.split(separator: " ")[1])! }
        #expect(indices.last == 39 && !indices.contains(0) && indices == indices.sorted())
    }
    @Test func fileErrorStopsSavingWithoutBlockingAndConfigureRetries() async throws {
        let directory = temporaryDirectory()
        try Data().write(to: directory) // A file cannot be the history folder.
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = DictationHistory(directory: directory, maximumPending: 1)
        let failures = LockedCounter()
        history.setFailureObserver { failures.increment() }
        history.configure(enabled: true, asr: "http", prompt: "")
        for _ in 0..<1000 { history.record(.init(raw: "synthetic", cleaned: "Synthetic.")) }
        await history.flush()
        #expect(history.hasFailed && !history.isEnabled)
        #expect(failures.value == 1)
        history.configure(enabled: true, asr: "http", prompt: "")
        #expect(!history.hasFailed && history.isEnabled)
    }
}
