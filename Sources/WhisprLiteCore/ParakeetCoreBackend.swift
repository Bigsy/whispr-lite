import Foundation
#if PARAKEET_CORE
import ParakeetCore

/// Direct PCM integration with the pinned library; models are prepared before recording.
public actor ParakeetCoreBackend: PressWarmableASRBackend {
    public nonisolated let capabilities = ASRCapabilities()
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
    public func prepare(progress: @escaping @Sendable (BackendPreparation) -> Void) async throws {
        try await engine.prepare { update in
            let stage: BackendPreparation = switch update.stage {
            case .checkingCache: .checkingCache
            case .downloading: .downloading
            case .loading: .loading
            case .warmingUp: .warmingUp
            case .ready: .ready
            }
            progress(stage)
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
            return .init(text: result.text, audioDuration: result.actualAudioDuration)
        } catch ParakeetError.cancelled { throw CancellationError() }
    }
    public func warmForRecording() async throws {
        let silence = try PCM16k([Float](repeating: 0, count: PCM16k.rate))
        guard try await transcribe(silence).text.isEmpty else { throw AppError.inference }
    }
}
#endif

public enum BackendFactory {
    public static var hasParakeetCore: Bool {
        #if PARAKEET_CORE
        true
        #else
        false
        #endif
    }
    public static func make(mode: BackendMode, endpoint: String, cacheRoot: URL? = nil,
                            allowDownloads: Bool = false, model: ParakeetModel = .unified) throws -> any ASRBackend {
        switch mode {
        case .demo: return FakeASRBackend()
        case .http: return HTTPASRBackend(endpoint: try LocalEndpoint(endpoint))
        case .parakeet:
            #if PARAKEET_CORE
            return ParakeetCoreBackend(cacheRoot: cacheRoot, allowDownloads: allowDownloads, model: model)
            #else
            throw AppError.unsupported
            #endif
        }
    }
}
