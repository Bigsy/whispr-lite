import Foundation

/// App-owned preparation for M8. One sender orders calls across await; no provisional insertion.
public actor StreamingPipeline {
    private let backend: any ASRBackend
    private var session: (any ASRSession)?
    private var retained: [Float] = []
    private var nextOffset = 0
    private var revision = 0
    private var fallback = false
    private var finished = false
    private var cancelled = false
    private var delivering = false
    public init(backend: any ASRBackend) { self.backend = backend }
    public func start() async throws {
        guard !delivering, session == nil, !finished else { throw AppError.protocolViolation }
        guard backend.capabilities.streaming, await backend.readiness() == .ready else { throw AppError.unsupported }
        delivering = true; defer { delivering = false }
        session = try await backend.makeSession()
        retained.reserveCapacity(PCM16k.maximumSamples)
    }
    public func append(_ audio: PCM16k) async throws -> PartialSnapshot? {
        guard !finished, !delivering, audio.samples.count <= 640,
              audio.samples.count <= PCM16k.maximumSamples - retained.count else { throw AppError.overflow }
        guard let session else { throw AppError.notReady }
        delivering = true; defer { delivering = false }
        retained.append(contentsOf: audio.samples)
        let offset = nextOffset; nextOffset += audio.samples.count
        guard !fallback else { return nil }
        do {
            try await withDeadline(.seconds(1), stage: "Streaming append") { try await session.append(audio, startingAt: offset) }
            guard !finished else { throw CancellationError() }
            if let snapshot = try await session.partial(), snapshot.revision > revision {
                revision = snapshot.revision; return snapshot
            }
            return nil
        } catch is CancellationError { throw CancellationError() }
        catch { fallback = true; await session.cancel(); return nil }
    }
    public func finish(cleanup: any TextCleanup) async throws -> String? {
        guard !finished, !delivering, let session else { throw AppError.protocolViolation }
        finished = true
        defer { retained.removeAll(); self.session = nil }
        let audio = try PCM16k(retained)
        if fallback {
            let text = try await BatchPipeline(backend: backend, cleanup: cleanup).run(audio)
            guard !cancelled else { throw CancellationError() }; return text
        }
        let result: ASRResult
        do { result = try await withDeadline(.seconds(10), stage: "Streaming finish") { try await session.finish() } }
        catch is CancellationError { await session.cancel(); throw CancellationError() }
        catch {
            await session.cancel()
            guard !cancelled else { throw CancellationError() }
            let text = try await BatchPipeline(backend: backend, cleanup: cleanup).run(audio)
            guard !cancelled else { throw CancellationError() }; return text
        }
        guard !cancelled else { throw CancellationError() }
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        do {
            let text = try await withDeadline(.seconds(10), stage: "Cleanup") { try await cleanup.clean(raw) }
            guard !cancelled else { throw CancellationError() }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.cleanup }
            return text
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw PipelineFailure(reason: error as? AppError ?? .cleanup, rawText: raw) }
    }
    public func cancel() async { cancelled = true; finished = true; await session?.cancel(); retained.removeAll(); session = nil }
}
/// Useful changed partials only; one request in flight and latest snapshot coalesced.
/// This schedules an injectable experiment, not an assertion that llama-server supports prefill.
public actor PrefillScheduler {
    private let operation: @Sendable (PartialSnapshot) async throws -> Void
    private var latest: PartialSnapshot?
    private var lastRevision = 0
    private var lastText = ""
    private var worker: Task<Void, Never>?
    private var ended = false
    public init(operation: @escaping @Sendable (PartialSnapshot) async throws -> Void) { self.operation = operation }
    public func submit(_ snapshot: PartialSnapshot) {
        guard !ended, snapshot.revision > lastRevision else { return }
        lastRevision = snapshot.revision
        guard !snapshot.text.isEmpty, snapshot.text != lastText else { return }
        lastText = snapshot.text; latest = snapshot
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }
    private func drain() async {
        while !ended, let snapshot = latest {
            latest = nil
            do { try await withDeadline(.seconds(2), stage: "Prefill") { try await self.operation(snapshot) } }
            catch { latest = nil; break }
        }
        worker = nil
    }
    public func stop() async { ended = true; latest = nil; worker?.cancel(); await worker?.value; worker = nil }
}
