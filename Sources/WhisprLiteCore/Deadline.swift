import Foundation

// An uncooperative native operation must not keep the app's lifecycle waiting.
// The worker retains its inputs until it settles; the backend retains model ownership.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var outcome: Result<T, any Error>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let settled = lock.withLock { () -> Result<T, any Error>? in
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let settled { continuation.resume(with: settled) }
    }
    func retain(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            if outcome != nil { return true }
            tasks.append(task)
            return false
        }
        if shouldCancel { task.cancel() }
    }
    func settle(_ result: Result<T, any Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>])? in
            guard outcome == nil else { return nil }
            outcome = result
            let completion = (continuation, tasks)
            continuation = nil
            tasks = []
            return completion
        }
        guard let (continuation, tasks) = completion else { return }
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
