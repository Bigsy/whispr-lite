import Foundation

/// Opt-in local audio for debugging. The serial utility queue owns all encoding and disk
/// work; the lock only protects admission and snapshots, never file operations.
public final class DebugRecordings: @unchecked Sendable {
    public static let maximumStorageBytes = 500_000_000
    public struct Snapshot: Sendable, Equatable {
        public var bytes: Int?
        public var failed = false
        public var skipped = 0
        public init(bytes: Int? = nil, failed: Bool = false, skipped: Int = 0) {
            self.bytes = bytes; self.failed = failed; self.skipped = skipped
        }
    }
    public let directory: URL
    let queue = DispatchQueue(label: "WhisprLite.debugRecordings", qos: .utility)
    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumPending: Int
    private var enabled = false
    private var epoch: UInt64 = 0
    private var pending = 0
    private var value = Snapshot()
    private var observer: (@Sendable () -> Void)?

    public init(directory: URL, maximumBytes: Int = DebugRecordings.maximumStorageBytes,
                maximumPending: Int = 2) {
        self.directory = directory
        self.maximumBytes = max(44, maximumBytes)
        self.maximumPending = max(1, maximumPending)
    }
    public var snapshot: Snapshot { lock.withLock { value } }
    public func setObserver(_ observer: (@Sendable () -> Void)?) { lock.withLock { self.observer = observer } }

    public func setEnabled(_ enabled: Bool) {
        lock.withLock {
            epoch &+= 1
            self.enabled = enabled
            if enabled { value.failed = false }
            let owner = epoch
            queue.async { [self] in
                do {
                    var files = try inventory()
                    if enabled { try trim(&files, reserving: 0) }
                    update { $0.bytes = files.reduce(0) { $0 + $1.bytes } }
                } catch { fail(owner: owner) }
            }
        }
    }

    /// Admission is bounded to two owned PCM buffers, including the active write. A full
    /// queue skips the recording and reports it in Settings instead of delaying dictation.
    public func record(_ audio: PCM16k, session: UUID) {
        guard !audio.samples.isEmpty else { return }
        let notify: (@Sendable () -> Void)? = lock.withLock {
            guard enabled, !value.failed else { return nil }
            guard pending < maximumPending else { value.skipped += 1; return observer }
            pending += 1
            let owner = epoch
            queue.async { [self] in
                defer { lock.withLock { pending -= 1 } }
                guard lock.withLock({ enabled && !value.failed && epoch == owner }) else { return }
                do {
                    let bytes = 44 + audio.samples.count * 2
                    guard bytes <= maximumBytes else { update { $0.skipped += 1 }; return }
                    try PrivateFiles.ensureDirectory(at: directory)
                    var folder = directory, attributes = URLResourceValues()
                    attributes.isExcludedFromBackup = true
                    try folder.setResourceValues(attributes)
                    var files = try inventory()
                    // Evict first, so even the temporary file stays within the byte budget.
                    try trim(&files, reserving: bytes)
                    let destination = directory.appendingPathComponent("\(session.uuidString).wav")
                    try PrivateFiles.writeAtomically(WAVEncoder.encode(audio), to: destination)
                    // Re-scan also handles replacement of an existing session, without double counting.
                    let total = try inventory().reduce(0) { $0 + $1.bytes }
                    update { $0.bytes = total }
                } catch { fail(owner: owner) }
            }
            return nil
        }
        notify?()
    }

    /// Invalidates queued audio before deleting. New dictations can be saved afterwards.
    public func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                epoch &+= 1
                let owner = epoch
                queue.async { [self] in
                    do {
                        for file in try inventory() { try FileManager.default.removeItem(at: file.url) }
                        update { $0.bytes = 0; $0.failed = false; $0.skipped = 0 }
                        continuation.resume()
                    } catch { fail(owner: owner); continuation.resume(throwing: error) }
                }
            }
        }
    }
    public func refreshStorage() {
        queue.async { [self] in
            do {
                let bytes = try inventory().reduce(0) { $0 + $1.bytes }
                update { $0.bytes = bytes }
            } catch { update { $0.bytes = nil; $0.failed = true } }
        }
    }
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }

    private struct File { let url: URL; let bytes: Int; let date: Date }
    private func inventory() throws -> [File] {
        guard try PrivateFiles.directoryExists(at: directory) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]).compactMap { url in
                // A killed process can leave an atomic write unfinished. Reclaim only our
                // exact temporary filename pattern; the live writer shares this queue.
                let parts = url.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
                if parts.count == 5, parts[0].isEmpty, parts[2] == "wav", parts[4] == "tmp",
                   UUID(uuidString: String(parts[1])) != nil, UUID(uuidString: String(parts[3])) != nil {
                    if try PrivateFiles.regularFileExists(at: url) { try FileManager.default.removeItem(at: url) }
                    return nil
                }
                // Own only session WAVs; never delete unrelated files or follow symlinks.
                guard url.pathExtension == "wav", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return nil }
                guard try PrivateFiles.regularFileExists(at: url) else { return nil }
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return File(url: url, bytes: attributes.fileSize ?? 0, date: attributes.creationDate ?? .distantPast)
            }.sorted { $0.date == $1.date ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.date < $1.date }
    }
    private func trim(_ files: inout [File], reserving bytes: Int) throws {
        var total = files.reduce(0) { $0 + $1.bytes }
        var removed = 0
        for file in files {
            guard total + bytes > maximumBytes else { break }
            try FileManager.default.removeItem(at: file.url)
            total -= file.bytes; removed += 1
        }
        files.removeFirst(removed)
    }
    private func update(_ body: (inout Snapshot) -> Void) {
        let notify = lock.withLock { body(&value); return observer }
        notify?()
    }
    private func fail(owner: UInt64) {
        let notify: (@Sendable () -> Void)? = lock.withLock {
            guard epoch == owner else { return nil }
            value.failed = true; value.bytes = nil
            return observer
        }
        notify?()
    }
}
