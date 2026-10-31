import Accelerate
import Foundation
import ParakeetCore

/// One per final transcription: whether the words reach the end of the speech, and what
/// the tail fallback did. Seconds and counts only, so there is no route for words or audio.
public struct TranscriptCoverage: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// unavailable: the backend reports no word timings. noWords: an empty transcript.
        /// covered: no clear speech after the last word. uncovered: some, in a clip a single
        /// ASR window holds, left as is. recovered/unrecovered: the tail was decoded again
        /// and did or did not add words. partial: added words but possible speech remains.
        case unavailable, noWords, covered, uncovered, recovered, unrecovered, partial
    }
    /// Possible missing speech, never a claim that RMS activity proves lost words.
    public var needsReview: Bool {
        switch outcome {
        case .uncovered, .unrecovered, .partial: true
        case .noWords: (speechAfterSeconds ?? 0) >= TranscriptTail.minimumSpeechSeconds
        default: false
        }
    }
    public var outcome: Outcome
    public var audioSeconds: Double
    public var lastWordEndSeconds: Double?
    /// Speech-level audio after the last word, by FluidAudio's adaptive RMS rule.
    public var speechAfterSeconds: Double?
    public var recoveredWords: Int?
    /// Total recovery time, when recovery ran.
    public var fallbackMS: Double?
    public var fallbackAttempts: Int?
    public init(_ outcome: Outcome, audioSeconds: Double) { self.outcome = outcome; self.audioSeconds = audioSeconds }
}
public typealias CoverageReport = @Sendable (TranscriptCoverage) -> Void

/// Long recordings are decoded in ~15 s windows and stitched together. A window can decode
/// its new audio to nothing (FluidAudio #909), and neither FluidAudio's seam repair (gaps
/// between words only) nor its empty-window recovery (windows with no tokens at all)
/// covers speech after the last word. When clear speech follows the last word of a
/// stitched transcript, decode that tail with a different cut and append only credible new words. Reassess
/// coverage after each pass, with retries bounded by recording length and the ASR deadline.
public enum TranscriptTail {
    /// FluidAudio's 80 ms encoder frame.
    static let frameSamples = 1_280
    /// FluidAudio's audio per window (14.96 s); longer recordings are stitched.
    static let windowSamples = 239_360
    /// Synthetic complete transcripts measured 0 to 0.08 s after the last word; a removed
    /// five-word final sentence measured 1.1 to 1.3 s. A false trigger normally costs one
    /// decode; longer recovery requires credible progress and remains deadline bounded.
    static let minimumSpeechSeconds = 0.8
    /// Audio before the last word's end, so the tail decode starts with context.
    static let contextSeconds = 2.0
    /// FluidAudio's bar for accepting a recovered decode (#909).
    static let minimumConfidence: Float = 0.7

    public static func complete(_ audio: PCM16k, text: String, words: [TimedWord]?,
                                isolation: isolated (any Actor)? = #isolation,
                                redecode: (PCM16k) async throws -> [TimedWord]?) async throws -> ASRResult {
        try Task.checkCancellation()
        var coverage = TranscriptCoverage(.unavailable, audioSeconds: audio.duration)
        var transcript = words ?? []
        var output = text
        var validTimings = words != nil
        func result() -> ASRResult {
            .init(text: output, audioDuration: audio.duration, coverage: coverage, words: validTimings ? transcript : nil)
        }
        guard words != nil else { return result() }
        guard transcript.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0
            && $0.end >= $0.start && $0.end <= audio.duration + 0.08 }) else {
            coverage.outcome = .unrecovered; validTimings = false; return result()
        }
        let samples = audio.samples
        let threshold = speechThreshold(samples)
        func assess() -> Double {
            let end = transcript.last?.end ?? 0
            let speech = speechSeconds(samples, from: sample(end), threshold: threshold)
            coverage.lastWordEndSeconds = transcript.last?.end
            coverage.speechAfterSeconds = speech
            return speech
        }
        guard !transcript.isEmpty else {
            coverage.outcome = .noWords
            // With no recognized speech, an adaptive threshold derived only from a
            // quiet noise floor would classify that same floor as speech. Require
            // the upper adaptive clamp before showing an empty-result warning.
            coverage.speechAfterSeconds = speechSeconds(samples, from: 0, threshold: 0.008)
            return result()
        }
        guard assess() >= minimumSpeechSeconds else { coverage.outcome = .covered; return result() }
        guard samples.count > windowSamples else { coverage.outcome = .uncovered; return result() }
        let started = ContinuousClock.now
        var recovered = 0
        var attempts = 0
        // At most one pass per window of new audio, plus the last partial window. Tiny
        // advances cannot create an unbounded retry loop. The caller's ASR deadline also
        // covers all passes, and no retry starts after cancellation.
        let stride = windowSamples - sample(contextSeconds)
        let maximumAttempts = (samples.count + stride - 1) / stride
        var previousStart = -1
        while attempts < maximumAttempts {
            try Task.checkCancellation()
            let last = transcript.last!
            guard last.end.isFinite, last.end >= 0, last.end <= audio.duration else { break }
            let start = sample(last.end - contextSeconds) / frameSamples * frameSamples
            guard start > previousStart, start < samples.count else { break }
            previousStart = start
            let end = min(samples.count, start + windowSamples)
            attempts += 1
            let tail: [TimedWord]
            do { tail = try await redecode(PCM16k(Array(samples[start..<end]))) ?? [] }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); break }
            try Task.checkCancellation()
            let duration = Double(end - start) / Double(PCM16k.rate)
            guard tail.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.confidence.isFinite
                && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.08 }) else { break }
            let missing = missingWords(after: transcript, in: tail, offset: Double(start) / Double(PCM16k.rate))
            guard let final = missing.last, final.end > last.end + Double(frameSamples) / Double(PCM16k.rate),
                  zip(missing, missing.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }) else { break }
            transcript.append(contentsOf: missing)
            output = ([output] + missing.map(\.text)).joined(separator: " ")
            recovered += missing.count
            if assess() < minimumSpeechSeconds { break }
            // Repeating almost the same cut is costly and weak evidence. Keep the new
            // words, but ask for review rather than run another near-identical decode.
            if final.end - last.end < minimumSpeechSeconds { break }
            // This pass already saw the end. Repeating a cut of the same final window
            // adds latency with little new evidence; keep the uncertainty visible.
            if end == samples.count { break }
        }
        coverage.fallbackMS = started.duration(to: .now).milliseconds
        coverage.fallbackAttempts = attempts
        coverage.recoveredWords = recovered
        coverage.outcome = recovered == 0 ? .unrecovered
            : (assess() < minimumSpeechSeconds ? .recovered : .partial)
        return result()
    }

    /// Tail words starting after the transcript's last word ends (one frame of emission
    /// jitter allowed), minus a re-heard copy of up to its last three words. Empty unless
    /// FluidAudio would call the decode credible.
    static func missingWords(after transcript: [TimedWord], in tail: [TimedWord], offset: Double) -> [TimedWord] {
        guard let last = transcript.last else { return [] }
        let jitter = Double(frameSamples) / Double(PCM16k.rate)
        var missing = tail.filter { offset + $0.start >= last.end - jitter && offset + $0.end > last.end }
            .map { TimedWord(text: $0.text, start: offset + $0.start, end: offset + $0.end, confidence: $0.confidence) }
        let key = { (word: TimedWord) in WordTokens.words(word.text) }
        let ending = transcript.suffix(3).map(key)
        for count in stride(from: min(ending.count, missing.count), through: 1, by: -1)
        where Array(ending.suffix(count)) == missing.prefix(count).map(key)
            && missing[count - 1].start <= last.end + jitter * 2 {
            missing.removeFirst(count); break
        }
        guard !missing.isEmpty,
              missing.map(\.confidence).reduce(0, +) / Float(missing.count) >= minimumConfidence else { return [] }
        return missing
    }

    /// FluidAudio 0.17.7 `ChunkProcessor.adaptiveSpeechRmsThreshold`: 0.3 times the 75th
    /// percentile of nonzero frame RMS, clamped to 0.0005...0.008.
    static func speechThreshold(_ samples: [Float]) -> Float {
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameSamples)
        var offset = 0
        while offset + frameSamples <= samples.count {
            let level = rms(samples, at: offset)
            if level > 0 { levels.append(level) }
            offset += frameSamples
        }
        levels.sort()
        return speechThreshold(sortedLevels: levels[...])
    }
    /// The same rule over nonzero frame levels already in ascending order.
    static func speechThreshold(sortedLevels levels: ArraySlice<Float>) -> Float {
        guard !levels.isEmpty else { return 0.008 }
        let upper = levels[levels.startIndex + min(levels.count - 1, Int(Double(levels.count) * 0.75))]
        return min(0.008, max(0.0005, upper * 0.3))
    }

    /// Whole frames from `start` to the end whose RMS exceeds `threshold`, in seconds.
    static func speechSeconds(_ samples: [Float], from start: Int, threshold: Float) -> Double {
        var frames = 0
        var offset = (start + frameSamples - 1) / frameSamples * frameSamples
        while offset + frameSamples <= samples.count {
            if rms(samples, at: offset) > threshold { frames += 1 }
            offset += frameSamples
        }
        return Double(frames * frameSamples) / Double(PCM16k.rate)
    }

    private static func rms(_ samples: [Float], at offset: Int) -> Float {
        var sum: Float = 0
        samples.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + offset, 1, &sum, vDSP_Length(frameSamples)) }
        return (sum / Float(frameSamples)).squareRoot()
    }
    private static func sample(_ seconds: Double) -> Int { max(0, Int(seconds * Double(PCM16k.rate))) }
}
