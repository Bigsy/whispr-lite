import Foundation
import CryptoKit

/// Local dictation history, kept to train a better local cleanup model. Nothing here is uploaded:
/// raw/cleaned text pairs go to one private JSONL file (0600 in a 0700 folder excluded from
/// backups), written on a utility queue so dictation never waits for disk. Audio is not kept.
public final class DictationHistory: @unchecked Sendable {
    public static let maximumTextCharacters = 32_768
    public static let defaultMaximumBytes = 16 * 1024 * 1024
    public static let maximumStorageBytes = 2 * defaultMaximumBytes
    public struct Entry: Codable, Sendable, Equatable {
        public var schema = 1
        public let timestamp: Date
        public let raw: String
        public let cleaned: String
        /// Which speech model and prompt produced the pair; the prompt itself is not stored.
        public let asr: String
        public let promptSHA256: String
        enum CodingKeys: String, CodingKey { case schema, timestamp, raw, cleaned, asr, promptSHA256 = "prompt_sha256" }
    }
    public static let fileName = "dictations.jsonl"
    public static let previousFileName = "dictations.previous.jsonl"
    public let directory: URL
    private let queue = DispatchQueue(label: "WhisprLite.history", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private var failed = false
    private var pending = 0
    private var asr = ""
    private var promptSHA256 = ""
    private let maximumBytes: Int
    private let maximumPending: Int
    private var handle: FileHandle?
    private var bytes = 0
    /// Two rotating files of `maximumBytes` each; the oldest file is dropped when both are full.
    public init(directory: URL, maximumBytes: Int = DictationHistory.defaultMaximumBytes, maximumPending: Int = 64) {
        self.directory = directory; self.maximumBytes = max(1024, maximumBytes); self.maximumPending = max(1, maximumPending)
    }
    public var isEnabled: Bool { lock.withLock { enabled && !failed } }
    public var hasFailed: Bool { lock.withLock { failed } }
    public func configure(enabled value: Bool, asr: String, prompt: String) {
        let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            if value { failed = false } // Each save or readiness check retries after a file error.
            enabled = value; self.asr = asr; promptSHA256 = String(digest.prefix(16))
        }
        if !value { queue.async { try? self.handle?.close(); self.handle = nil } }
    }
    /// Called just before insertion, so it only enqueues; encoding and disk work happen on the queue.
    public func record(_ dictation: DictationText) {
        let timestamp = Date()
        lock.lock(); defer { lock.unlock() }
        guard enabled, !failed, pending < maximumPending else { return }
        let asr = asr, promptSHA256 = promptSHA256
        pending += 1
        queue.async {
            let entry = Entry(timestamp: timestamp, raw: String(dictation.raw.prefix(Self.maximumTextCharacters)),
                              cleaned: String(dictation.cleaned.prefix(Self.maximumTextCharacters)), asr: asr, promptSHA256: promptSHA256)
            do { try self.write(entry) }
            catch { self.lock.withLock { self.failed = true }; try? self.handle?.close(); self.handle = nil }
            self.lock.withLock { self.pending -= 1 }
        }
    }
    /// Permanently removes every saved entry. Saving continues afterwards while enabled.
    public func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                try? self.handle?.close(); self.handle = nil; self.bytes = 0
                do {
                    for name in [Self.fileName, Self.previousFileName] {
                        let file = self.directory.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                    self.lock.withLock { self.failed = false }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Explicit tests/deletion only; normal dictation never waits for disk.
    public func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    private func open() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var folder = directory, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let file = directory.appendingPathComponent(Self.fileName)
        if !manager.fileExists(atPath: file.path) { guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        handle = try FileHandle(forWritingTo: file); bytes = Int(try handle!.seekToEnd())
    }
    private func write(_ entry: Entry) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry); data.append(10)
        guard data.count <= maximumBytes else { return } // Skip one oversized entry rather than stop saving.
        if handle == nil { try open() }
        if bytes + data.count > maximumBytes {
            try handle?.close(); handle = nil
            let current = directory.appendingPathComponent(Self.fileName), previous = directory.appendingPathComponent(Self.previousFileName)
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: current, to: previous)
            try open()
        }
        try handle?.write(contentsOf: data); bytes += data.count
    }
    deinit { try? handle?.close() }
}
