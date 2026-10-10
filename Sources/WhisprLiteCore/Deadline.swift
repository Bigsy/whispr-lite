import Foundation

// An uncooperative native operation must not keep the app's lifecycle waiting.
// The worker retains its inputs until it settles; the backend retains model ownership.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var outcome: Result<T, any Error>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func retain(_ task: Task<Void, Never>) {
        lock.lock()
        if outcome != nil { lock.unlock(); task.cancel() }
        else { tasks.append(task); lock.unlock() }
    }
    func settle(_ result: Result<T, any Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = self.continuation; self.continuation = nil
        let tasks = self.tasks; self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
public func withDeadline<T: Sendable>(
    _ duration: Duration, stage: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            race.retain(Task {
                do { race.settle(.success(try await operation())) }
                catch { race.settle(.failure(error)) }
            })
            race.retain(Task {
                do { try await Task.sleep(for: duration); race.settle(.failure(AppError.deadline(stage))) }
                catch {}
            })
        }
    } onCancel: { race.settle(.failure(CancellationError())) }
}
