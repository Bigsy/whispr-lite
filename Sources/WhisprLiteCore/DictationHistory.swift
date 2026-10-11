import Foundation
import CryptoKit

/// Local dictation history, kept to train a better local cleanup model. Nothing here is uploaded:
/// raw/cleaned text pairs go to one private JSONL file (0600 in a 0700 folder excluded from
/// backups), written on a utility queue so dictation never waits for disk. Audio is not kept.
public final class DictationHistory: @unchecked Sendable {
    public static let maximumTextCharacters = 32_768
    public static let defaultMaximumBytes = 16 * 1024 * 1024
    public static let maximumStorageBytes = 2 * defaultMaximumBytes
    struct Entry: Codable, Sendable, Equatable {
        var schema = 1
        let timestamp: Date
        let raw: String
        let cleaned: String
        /// Which speech model and prompt produced the pair; the prompt itself is not stored.
        let asr: String
        let promptSHA256: String
        enum CodingKeys: String, CodingKey { case schema, timestamp, raw, cleaned, asr, promptSHA256 = "prompt_sha256" }
    }
    static let fileName = "dictations.jsonl"
    static let previousFileName = "dictations.previous.jsonl"
    public let directory: URL
    private let queue = DispatchQueue(label: "WhisprLite.history", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private var failed = false
    private var pending = 0
    private var asr = ""
    private var promptSHA256 = ""
    private let writer: PrivateJSONLWriter<Entry>
    /// Two rotating files of `maximumBytes` each; the oldest file is dropped when both are full.
    public init(directory: URL, maximumBytes: Int = DictationHistory.defaultMaximumBytes, maximumPending: Int = 64) {
        self.directory = directory
        writer = .init(directory: directory, fileName: Self.fileName, previousFileName: Self.previousFileName,
                       maximumBytes: maximumBytes, maximumPending: maximumPending,
                       excludeFromBackup: true, oversize: .skip)
    }
    public var isEnabled: Bool { lock.withLock { enabled && !failed } }
    public var hasFailed: Bool { lock.withLock { failed } }
    public func configure(enabled value: Bool, asr: String, prompt: String) {
        let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            if value { failed = false } // Each save or readiness check retries after a file error.
            enabled = value; self.asr = asr; promptSHA256 = String(digest.prefix(16))
        }
        if !value { queue.async { self.writer.close() } }
    }
    /// Called just before insertion, so it only enqueues; encoding and disk work happen on the queue.
    public func record(_ dictation: DictationText) {
        let timestamp = Date()
        lock.lock(); defer { lock.unlock() }
        guard enabled, !failed, pending < writer.maximumPending else { return }
        let asr = asr, promptSHA256 = promptSHA256
        pending += 1
        queue.async {
            let entry = Entry(timestamp: timestamp, raw: String(dictation.raw.prefix(Self.maximumTextCharacters)),
                              cleaned: String(dictation.cleaned.prefix(Self.maximumTextCharacters)), asr: asr, promptSHA256: promptSHA256)
            do { try self.writer.write(entry) }
            catch { self.lock.withLock { self.failed = true }; self.writer.close() }
            self.lock.withLock { self.pending -= 1 }
        }
    }
    /// Permanently removes every saved entry. Saving continues afterwards while enabled.
    public func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.writer.deleteAll()
                    self.lock.withLock { self.failed = false }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Explicit tests/deletion only; normal dictation never waits for disk.
    public func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
