import Foundation

/// App-owned preparation for M8. One sender orders calls across await; no provisional insertion.
public actor StreamingPipeline {
    private static let appendDeadline: Duration = .seconds(1)
    private let pipeline: BatchPipeline
    private var session: (any ASRSession)?
    private var nextOffset = 0
    private var revision = 0
    private var fallback = false
    private var finished = false
    private var cancelled = false
    private var delivering = false
    public init(pipeline: BatchPipeline) { self.pipeline = pipeline }
    public func start() async throws {
        guard !delivering, session == nil, !finished else { throw AppError.protocolViolation }
        guard pipeline.backend.capabilities.streaming, await pipeline.backend.readiness() == .ready else { throw AppError.unsupported }
        delivering = true; defer { delivering = false }
        session = try await pipeline.backend.makeSession()
    }
    public func append(_ audio: PCM16k) async throws -> PartialSnapshot? {
        guard !finished, !delivering, audio.samples.count <= PCM16k.streamingChunkSamples,
              audio.samples.count <= PCM16k.maximumSamples - nextOffset else { throw AppError.overflow }
        guard let session else { throw AppError.notReady }
        delivering = true; defer { delivering = false }
        let offset = nextOffset; nextOffset += audio.samples.count
        guard !fallback else { return nil }
        do {
            try await withDeadline(Self.appendDeadline, stage: "Streaming append") { try await session.append(audio, startingAt: offset) }
            guard !finished else { throw CancellationError() }
            if let snapshot = try await session.partial(), snapshot.revision > revision {
                revision = snapshot.revision; return snapshot
            }
            return nil
        } catch is CancellationError { throw CancellationError() }
        catch { fallback = true; await session.cancel(); return nil }
    }
    public func finish(audio: PCM16k) async throws -> String? {
        guard !finished, !delivering, let session else { throw AppError.protocolViolation }
        finished = true
        defer { self.session = nil }
        if fallback || audio.samples.count != nextOffset {
            await session.cancel()
            let text = try await pipeline.run(audio)
            guard !cancelled else { throw CancellationError() }; return text
        }
        let result: ASRResult
        do { result = try await withDeadline(pipeline.asrDeadline, stage: "Streaming finish") { try await session.finish() } }
        catch is CancellationError { await session.cancel(); throw CancellationError() }
        catch {
            await session.cancel()
            guard !cancelled else { throw CancellationError() }
            let text = try await pipeline.run(audio)
            guard !cancelled else { throw CancellationError() }; return text
        }
        guard !cancelled else { throw CancellationError() }
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let text = try await pipeline.finish(raw).cleaned
        guard !cancelled else { throw CancellationError() }
        return text
    }
    public func cancel() async { cancelled = true; finished = true; await session?.cancel(); session = nil }
}
