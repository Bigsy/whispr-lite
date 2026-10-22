import Foundation
import os
import ParakeetCore

/// Direct PCM integration with the pinned library; models are prepared before recording.
public actor ParakeetCoreBackend: HoldWarmableASRBackend {
    private static let warmupSilence = try! PCM16k([Float](repeating: 0, count: PCM16k.rate))
    public nonisolated var modelID: String { engine.modelID }
    private let engine: ParakeetEngine
    public init(cacheRoot: URL? = nil, allowDownloads: Bool = false, model: ParakeetModel = .unified) {
        let choice: ModelChoice = switch model {
        case .unified: .unified
        case .ultra: .ultra
        case .v2: .v2
        case .v3: .v3
        }
        engine = ParakeetEngine(configuration: .init(model: choice, mode: .batch,
            cacheRoot: cacheRoot, downloadPolicy: allowDownloads ? .allow : .requireCached, queueCapacity: 1,
            queueWaitTimeout: .seconds(10), inferenceTimeout: .seconds(10)))
    }
    public func prepare() async throws { try await engine.prepare() }
    public func prepare(progress: @escaping @Sendable (BackendPreparation, Double?) -> Void) async throws {
        // Downloads report per chunk; forward only a stage change or a whole-percent step.
        let last = OSAllocatedUnfairLock<(BackendPreparation, Int?)?>(initialState: nil)
        try await engine.prepare { update in
            let stage: BackendPreparation = switch update.stage {
            case .checkingCache: .checkingCache
            case .downloading: .downloading
            case .loading: .loading
            case .warmingUp: .warmingUp
            case .ready: .ready
            }
            let fraction = update.fractionCompleted.map { min(max($0, 0), 1) }
            let step = fraction.map { Int($0 * 100) }
            let changed = last.withLock { previous in
                guard previous?.0 != stage || previous?.1 != step else { return false }
                previous = (stage, step); return true
            }
            if changed { progress(stage, fraction) }
        }
    }
    public func unload() async throws { try await engine.unload() }
    public func readiness() async -> BackendReadiness {
        switch await engine.state {
        case .unloaded: .unloaded
        case .preparing: .preparing
        case .ready: .ready
        case .failed: .failed
        }
    }
    public func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        do {
            let result = try await engine.transcribe(PCM16kMono(samples: audio.samples))
            // A tail decode, when needed, queues behind this one; the caller's ASR deadline covers both.
            return try await TranscriptTail.complete(audio, text: result.text, words: result.words) { tail in
                try await engine.transcribe(PCM16kMono(samples: tail.samples)).words
            }
        } catch ParakeetError.cancelled { throw CancellationError() }
    }
    public func warmForRecording() async throws {
        guard try await transcribe(Self.warmupSilence).text.isEmpty else { throw AppError.inference }
    }
}

public enum BackendFactory {
    public static func make(mode: BackendMode, endpoint: String, cacheRoot: URL? = nil,
                            allowDownloads: Bool = false, model: ParakeetModel = .unified) throws -> any ASRBackend {
        switch mode {
        case .demo: return FakeASRBackend()
        case .http: return HTTPASRBackend(endpoint: try LocalEndpoint(endpoint))
        case .parakeet:
            return ParakeetCoreBackend(cacheRoot: cacheRoot, allowDownloads: allowDownloads, model: model)
        }
    }
}
