#if PARAKEET_STREAMING
import Foundation
import ParakeetCore
import WhisprLiteCore

/// Bench-only integration with the pinned ParakeetCore streaming session API.
public actor ParakeetStreamingBackend: ASRBackend {
    public nonisolated let capabilities = ASRCapabilities(streaming: true)
    private var engine: ParakeetEngine
    private let cacheRoot: URL?
    private var mode: EngineMode = .streaming
    private var active: StreamingSession?
    private var switching = false
    public init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot
        engine = ParakeetEngine(configuration: .init(mode: .streaming, cacheRoot: cacheRoot, downloadPolicy: .requireCached,
            queueCapacity: 1, queueWaitTimeout: .seconds(10), inferenceTimeout: .seconds(10), maximumStreamingChunkSamples: PCM16k.streamingChunkSamples))
    }
    public func prepare() async throws { try await engine.prepare() }
    public func readiness() async -> BackendReadiness {
        switch await engine.state {
        case .unloaded: .unloaded
        case .preparing: .preparing
        case .ready: .ready
        case .failed: .failed
        }
    }
    private func select(_ desired: EngineMode) async throws {
        guard !switching else { throw AppError.notReady }
        switching = true; defer { switching = false }
        if let active { await active.cancel(); await active.waitForSettlement(); self.active = nil }
        if mode != desired {
            try await engine.unload()
            engine = ParakeetEngine(configuration: .init(mode: desired, cacheRoot: cacheRoot, downloadPolicy: .requireCached,
                queueCapacity: 1, queueWaitTimeout: .seconds(10), inferenceTimeout: .seconds(10), maximumStreamingChunkSamples: PCM16k.streamingChunkSamples))
            mode = desired; try await engine.prepare()
        }
    }
    public func makeSession() async throws -> any ASRSession {
        try await select(.streaming)
        let session = try await engine.startStreaming(); active = session
        return ParakeetSessionBridge(session)
    }
    public func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        // A failed stream must settle/reset before batch fallback can reuse engine resources.
        try await select(.batch)
        let result = try await engine.transcribe(PCM16kMono(samples: audio.samples))
        return .init(text: result.text, audioDuration: result.actualAudioDuration)
    }
}
private actor ParakeetSessionBridge: ASRSession {
    private let session: StreamingSession
    private var latest: PartialSnapshot?
    private var observer: Task<Void, Never>?
    private var cancelled = false
    init(_ session: StreamingSession) { self.session = session }
    private func observe() {
        guard observer == nil else { return }
        observer = Task {
            do {
                for try await update in session.updates {
                    guard !cancelled, update.sessionID == session.id,
                          update.revision <= UInt64(Int.max) else { continue }
                    latest = .init(revision: Int(update.revision), text: update.fullTranscript)
                }
            } catch {}
        }
    }
    func append(_ audio: PCM16k, startingAt offset: Int) async throws {
        guard !cancelled else { throw CancellationError() }
        observe()
        do { try await session.append(PCM16kMono(samples: audio.samples), startingAt: offset) }
        catch ParakeetError.cancelled { throw CancellationError() }
    }
    func partial() -> PartialSnapshot? { latest }
    func finish() async throws -> ASRResult {
        guard !cancelled else { throw CancellationError() }
        let result = try await session.finish()
        observer?.cancel(); observer = nil
        guard !cancelled else { throw CancellationError() }
        return .init(text: result.text, audioDuration: result.actualAudioDuration)
    }
    func cancel() async {
        cancelled = true; latest = nil; observer?.cancel(); observer = nil
        await session.cancel()
        // The backend waits for settlement before fallback or changing modes.
    }
}
#endif
