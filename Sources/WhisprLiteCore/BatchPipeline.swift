import Foundation

public protocol TextCleanup: Sendable {
    func clean(_ text: String) async throws -> String
}
public struct DemoCleanup: TextCleanup {
    public init() {}
    public func clean(_ text: String) async throws -> String { try Task.checkCancellation(); return text }
}
/// The final transcript and the cleaned text made from it.
public struct DictationText: Sendable, Equatable {
    public let raw: String
    public let cleaned: String
    public init(raw: String, cleaned: String) { self.raw = raw; self.cleaned = cleaned }
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
        try await process(audio, mark: mark)?.cleaned
    }
    public func process(_ audio: PCM16k, mark: (@Sendable (TimingStage) async -> Void)? = nil) async throws -> DictationText? {
        guard let raw = try await transcribe(audio, mark: mark) else { return nil }
        return try await finish(raw, mark: mark)
    }
    public func transcribe(_ audio: PCM16k, mark: (@Sendable (TimingStage) async -> Void)? = nil) async throws -> String? {
        await mark?(.asrStart)
        let result = try await withDeadline(asrDeadline, stage: "ASR") { try await backend.transcribe(audio) }
        await mark?(.asrEnd)
        try Task.checkCancellation()
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
    /// Reuse cleanup completed during a long recording only when every chunk is a
    /// word-for-word prefix of the authoritative full ASR and ends at a sentence.
    /// Otherwise the ordinary full cleanup remains the single source of output.
    public func finish(_ raw: String, early: [DictationText] = [], mark: (@Sendable (TimingStage) async -> Void)? = nil) async throws -> DictationText {
        do {
            await mark?(.cleanupStart)
            let cleaned: String
            if let reuse = Self.reusablePrefix(in: raw, chunks: early) {
                let tail = reuse.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty { cleaned = reuse.cleaned }
                else {
                    let suffix = try await withDeadline(cleanupDeadline, stage: "Cleanup") { try await cleanup.clean(tail) }
                    let suffixText = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !suffixText.isEmpty else { throw AppError.cleanup }
                    cleaned = reuse.cleaned + " " + suffixText
                }
            } else {
                cleaned = try await withDeadline(cleanupDeadline, stage: "Cleanup") { try await cleanup.clean(raw) }
            }
            await mark?(.cleanupEnd)
            try Task.checkCancellation()
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.cleanup }
            return DictationText(raw: raw, cleaned: cleaned)
        } catch is CancellationError { throw CancellationError() }
        catch { throw PipelineFailure(reason: error as? AppError ?? .cleanup, rawText: raw) }
    }
    private static func reusablePrefix(in full: String, chunks: [DictationText]) -> (cleaned: String, tail: String)? {
        guard !chunks.isEmpty else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#)
        func words(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return pattern.matches(in: text, range: range).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]).lowercased() }
            }
        }
        let fullWords = words(full)
        var prefix: [String] = []
        for chunk in chunks {
            let raw = chunk.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = chunk.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.last.map({ ".!?".contains($0) }) == true,
                  clean.last.map({ ".!?".contains($0) }) == true else { return nil }
            let chunkWords = words(raw)
            guard !chunkWords.isEmpty else { return nil }
            prefix.append(contentsOf: chunkWords)
        }
        guard prefix.count <= fullWords.count, Array(fullWords.prefix(prefix.count)) == prefix else { return nil }
        let matches = pattern.matches(in: full, range: NSRange(full.startIndex..<full.endIndex, in: full))
        let tail: String
        if prefix.count == matches.count { tail = "" }
        else {
            guard let start = Range(matches[prefix.count].range, in: full)?.lowerBound else { return nil }
            tail = String(full[start...])
        }
        return (chunks.map { $0.cleaned.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " "), tail)
    }
}
