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
    /// Which speech model and prompt the next entries record. Read and written only inside
    /// sink closures, under its lock, so they change together with enabling.
    private var asr = ""
    private var promptSHA256 = ""
    private let sink: PrivateJSONLSink<Entry>
    /// Two rotating files of `maximumBytes` each; the oldest file is dropped when both are full.
    public init(directory: URL, maximumBytes: Int = DictationHistory.defaultMaximumBytes, maximumPending: Int = 64) {
        self.directory = directory
        sink = .init(label: "WhisprLite.history", directory: directory, fileName: Self.fileName,
                     previousFileName: Self.previousFileName, maximumBytes: maximumBytes,
                     maximumPending: maximumPending, excludeFromBackup: true, oversize: .skip)
    }
    public var isEnabled: Bool { sink.isEnabled }
    public var hasFailed: Bool { sink.hasFailed }
    public func setFailureObserver(_ observer: (@Sendable () -> Void)?) { sink.setFailureObserver(observer) }
    public func configure(enabled value: Bool, asr: String, prompt: String) {
        let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        sink.update { state in
            if value { state.failed = false } // Each save or readiness check retries after a file error.
            state.enabled = value; self.asr = asr; promptSHA256 = String(digest.prefix(16))
        }
        if !value { sink.close() }
    }
    /// Called just before insertion, so it only enqueues; truncation, encoding and disk work
    /// happen on the queue.
    public func record(_ dictation: DictationText) {
        let timestamp = Date()
        sink.enqueue { state in
            guard state.enabled, !state.failed else { return nil }
            let asr = asr, promptSHA256 = promptSHA256
            return {
                Entry(timestamp: timestamp, raw: String(dictation.raw.prefix(Self.maximumTextCharacters)),
                      cleaned: String(dictation.cleaned.prefix(Self.maximumTextCharacters)), asr: asr,
                      promptSHA256: promptSHA256)
            }
        }
    }
    /// Permanently removes every saved entry. Saving continues afterwards while enabled.
    public func deleteAll() async throws { try await sink.deleteAll() }
    /// Explicit tests/deletion only; normal dictation never waits for disk.
    public func flush() async { await sink.flush() }
}
