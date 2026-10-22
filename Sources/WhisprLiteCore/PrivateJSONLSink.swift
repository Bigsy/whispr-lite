import Foundation

/// Bounded, asynchronous writes to one private JSONL file pair, for the diagnostic log and
/// dictation history. Callers never touch disk: an accepted value is built and written on a
/// serial utility queue, a full queue drops it, and the first write failure stops writing
/// until the owner clears it.
final class PrivateJSONLSink<Value: Encodable & Sendable>: @unchecked Sendable {
    struct State {
        var enabled = false
        var failed = false
        /// Values refused because the queue was full.
        fileprivate(set) var dropped = 0
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var state = State()
    private var pending = 0
    private let maximumPending: Int
    private var failureObserver: (@Sendable () -> Void)?
    private let writer: PrivateJSONLWriter<Value> // Queue only.

    init(label: String, directory: URL, fileName: String, previousFileName: String, maximumBytes: Int,
         maximumPending: Int, excludeFromBackup: Bool, oversize: PrivateJSONLWriter<Value>.OversizePolicy) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.maximumPending = max(1, maximumPending)
        writer = .init(directory: directory, fileName: fileName, previousFileName: previousFileName,
                       maximumBytes: maximumBytes, excludeFromBackup: excludeFromBackup, oversize: oversize)
    }

    var isEnabled: Bool { lock.withLock { state.enabled && !state.failed } }
    var hasFailed: Bool { lock.withLock { state.failed } }
    var dropped: Int { lock.withLock { state.dropped } }
    func setFailureObserver(_ observer: (@Sendable () -> Void)?) {
        lock.withLock { failureObserver = observer }
    }

    /// Under the lock, `decide` may change the state and returns how to build the value to
    /// write, or nil to write nothing. The value is built and written on the queue, after
    /// everything enqueued before it. `decide` must not call back into the sink.
    func enqueue(_ decide: (inout State) -> (@Sendable () -> Value)?) {
        lock.lock(); defer { lock.unlock() }
        guard let make = decide(&state) else { return }
        guard pending < maximumPending else { state.dropped += 1; return }
        pending += 1
        queue.async { [self] in
            do { try writer.write(make()) }
            catch {
                let observer = lock.withLock { () -> (@Sendable () -> Void)? in
                    guard !state.failed else { return nil }
                    state.failed = true
                    return failureObserver
                }
                observer?()
                writer.close()
            }
            lock.withLock { pending -= 1 }
        }
    }
    func update(_ change: (inout State) -> Void) { enqueue { change(&$0); return nil } }
    /// Closes the file after the writes already queued; the next write reopens it.
    func close() { queue.async { [self] in writer.close() } }
    /// Removes both files after the writes already queued and clears a failure.
    func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try writer.deleteAll()
                    lock.withLock { state.failed = false }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Explicit tests, deletion and shutdown only; normal dictation never waits for disk.
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
