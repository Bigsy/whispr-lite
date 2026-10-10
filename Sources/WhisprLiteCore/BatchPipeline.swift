import Foundation

public protocol TextCleanup: Sendable {
    func clean(_ text: String) async throws -> String
}
public struct DemoCleanup: TextCleanup {
    public init() {}
    public func clean(_ text: String) async throws -> String { try Task.checkCancellation(); return text }
}
public struct PipelineFailure: Error, Sendable {
    public let reason: AppError
    public let rawText: String?
}
public struct BatchPipeline: Sendable {
    public let backend: any ASRBackend
    public let cleanup: any TextCleanup
    public var asrDeadline: Duration = .seconds(10)
    public var cleanupDeadline: Duration = .seconds(10)
    public init(backend: any ASRBackend, cleanup: any TextCleanup) { self.backend = backend; self.cleanup = cleanup }
    public func run(_ audio: PCM16k, mark: (@Sendable (TimingStage) async -> Void)? = nil) async throws -> String? {
        await mark?(.asrStart)
        let result = try await withDeadline(asrDeadline, stage: "ASR") { try await backend.transcribe(audio) }
        await mark?(.asrEnd)
        try Task.checkCancellation()
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        do {
            await mark?(.cleanupStart)
            let cleaned = try await withDeadline(cleanupDeadline, stage: "Cleanup") { try await cleanup.clean(raw) }
            await mark?(.cleanupEnd)
            try Task.checkCancellation()
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.cleanup }
            return cleaned
        } catch is CancellationError { throw CancellationError() }
        catch { throw PipelineFailure(reason: error as? AppError ?? .cleanup, rawText: raw) }
    }
}
