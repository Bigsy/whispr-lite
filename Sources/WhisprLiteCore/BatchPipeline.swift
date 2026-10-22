import Foundation
import ParakeetCore

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
extension String {
    var endsSentence: Bool { last.map { ".!?".contains($0) } == true }
}
/// Why cleanup produced no usable reply. Codes only; the reply never leaves the pipeline.
public enum CleanupFailure: String, Error, Codable, Sendable, LocalizedError {
    /// length: the reply reached its token limit, usually an answer instead of a cleanup.
    /// unfinished: any other stop. empty: only whitespace. status: a non-2xx or oversized
    /// response. connection: the request failed. invalidResponse: the reply did not decode.
    case length, unfinished, empty, status, connection, invalidResponse
    /// Cleanup runs at temperature zero, so the same text gets the same reply again.
    var repeats: Bool { self == .length || self == .unfinished || self == .empty }
    public var errorDescription: String? { AppError.cleanup.errorDescription }
}
public struct PipelineFailure: Error, Sendable {
    public let reason: AppError
    public let rawText: String?
    public var cleanupFailure: CleanupFailure? = nil
}
public struct BatchPipeline: Sendable {
    public let backend: any ASRBackend
    public let cleanup: any TextCleanup
    public var asrDeadline: Duration = .seconds(10)
    public var cleanupDeadline: Duration = .seconds(10)
    public init(backend: any ASRBackend, cleanup: any TextCleanup) { self.backend = backend; self.cleanup = cleanup }
    public func run(_ audio: PCM16k, mark: StageMark? = nil) async throws -> String? {
        try await process(audio, mark: mark)?.cleaned
    }
    public func process(_ audio: PCM16k, mark: StageMark? = nil) async throws -> DictationText? {
        guard let raw = try await transcribe(audio, mark: mark) else { return nil }
        return try await finish(raw, mark: mark)
    }
    public func transcribe(_ audio: PCM16k, mark: StageMark? = nil, report: CoverageReport? = nil) async throws -> String? {
        try await recognize(audio, mark: mark, report: report)?.text
    }
    /// The trimmed transcript with any word timings, or nil when ASR heard nothing.
    func recognize(_ audio: PCM16k, mark: StageMark? = nil, report: CoverageReport? = nil) async throws -> ASRResult? {
        await mark?(.asrStart)
        let result = try await withDeadline(asrDeadline, stage: "ASR") { try await backend.transcribe(audio) }
        await mark?(.asrEnd)
        try Task.checkCancellation()
        if let coverage = result.coverage { report?(coverage) }
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : .init(text: raw, audioDuration: result.audioDuration, coverage: result.coverage,
                                         words: result.words)
    }
    /// An early chunk's longest prefix that ends a sentence, and the audio after it to carry
    /// into the next chunk. The cut falls midway between that sentence's last word and the
    /// next. Nil when no word ends a sentence (or there are no word timings).
    static func sentencePrefix(of heard: ASRResult, audio: PCM16k) -> (text: String, rest: [Float])? {
        if heard.text.endsSentence { return (heard.text, []) }
        guard let words = heard.words,
              let last = words.lastIndex(where: { $0.text.trimmingCharacters(in: .whitespaces).endsSentence }),
              last + 1 < words.count else { return nil }
        let cut = (words[last].end + words[last + 1].start) / 2 * Double(PCM16k.rate)
        let start = min(audio.samples.count, max(0, Int(cut.rounded())))
        let text = words[...last].map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return (text, Array(audio.samples[start...]))
    }
    /// Reuse cleanup completed during a long recording only when every chunk is a
    /// word-for-word prefix of the authoritative full ASR and ends at a sentence.
    /// Otherwise the ordinary full cleanup remains the single source of output.
    /// `refused` is an early chunk's failed cleanup: when the text to clean is that chunk's
    /// text and the reply would repeat, it fails the same way without a second request.
    public func finish(_ raw: String, early: [DictationText] = [], refused: PipelineFailure? = nil,
                       mark: StageMark? = nil) async throws -> DictationText {
        func clean(_ text: String) async throws -> String {
            if let refused, let failure = refused.cleanupFailure, failure.repeats, refused.rawText == text { throw failure }
            return try await withDeadline(cleanupDeadline, stage: "Cleanup") { try await cleanup.clean(text) }
        }
        do {
            await mark?(.cleanupStart)
            let cleaned: String
            if let reuse = Self.reusablePrefix(in: raw, chunks: early) {
                let tail = reuse.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty { cleaned = reuse.cleaned }
                else {
                    let suffixText = try await clean(tail).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !suffixText.isEmpty else { throw CleanupFailure.empty }
                    cleaned = reuse.cleaned + " " + suffixText
                }
            } else {
                cleaned = try await clean(raw)
            }
            await mark?(.cleanupEnd)
            try Task.checkCancellation()
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CleanupFailure.empty }
            return DictationText(raw: raw, cleaned: cleaned)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as CleanupFailure { throw PipelineFailure(reason: .cleanup, rawText: raw, cleanupFailure: failure) }
        catch { throw PipelineFailure(reason: error as? AppError ?? .cleanup, rawText: raw) }
    }
    static func reusablePrefix(in full: String, chunks: [DictationText]) -> (cleaned: String, tail: String)? {
        guard !chunks.isEmpty else { return nil }
        let fullMatches = WordTokens.pattern.matches(in: full, range: NSRange(full.startIndex..<full.endIndex, in: full))
        let fullWords = fullMatches.compactMap { match in
            Range(match.range, in: full).map { WordTokens.normalize(String(full[$0])) }
        }
        var prefix: [String] = []
        for chunk in chunks {
            let raw = chunk.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = chunk.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.endsSentence, clean.endsSentence else { return nil }
            let chunkWords = WordTokens.words(raw)
            guard !chunkWords.isEmpty else { return nil }
            prefix.append(contentsOf: chunkWords)
        }
        guard fullWords.starts(with: prefix) else { return nil }
        let tail: String
        if prefix.count == fullMatches.count { tail = "" }
        else {
            guard let end = Range(fullMatches[prefix.count - 1].range, in: full)?.upperBound else { return nil }
            var start = end
            while start < full.endIndex, ".!?".contains(full[start]) || full[start].isWhitespace {
                start = full.index(after: start)
            }
            tail = String(full[start...])
        }
        return (chunks.map { $0.cleaned.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " "), tail)
    }
}
