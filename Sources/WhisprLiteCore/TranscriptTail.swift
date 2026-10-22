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
        /// and did or did not add words.
        case unavailable, noWords, covered, uncovered, recovered, unrecovered
    }
    public var outcome: Outcome
    public var audioSeconds: Double
    public var lastWordEndSeconds: Double?
    /// Speech-level audio after the last word, by FluidAudio's adaptive RMS rule.
    public var speechAfterSeconds: Double?
    public var recoveredWords: Int?
    /// The tail decode, when it ran.
    public var fallbackMS: Double?
    public init(_ outcome: Outcome, audioSeconds: Double) { self.outcome = outcome; self.audioSeconds = audioSeconds }
}
public typealias CoverageReport = @Sendable (TranscriptCoverage) -> Void

/// Long recordings are decoded in ~15 s windows and stitched together. A window can decode
/// its new audio to nothing (FluidAudio #909), and neither FluidAudio's seam repair (gaps
/// between words only) nor its empty-window recovery (windows with no tokens at all)
/// covers speech after the last word. When clear speech follows the last word of a
/// stitched transcript, decode that tail once more as its own shorter window, a different
/// cut from the one that failed, and append only the words it adds.
public enum TranscriptTail {
    /// FluidAudio's 80 ms encoder frame.
    static let frameSamples = 1_280
    /// FluidAudio's audio per window (14.96 s); longer recordings are stitched.
    static let windowSamples = 239_360
    /// Synthetic complete transcripts measured 0 to 0.08 s after the last word; a removed
    /// five-word final sentence measured 1.1 to 1.3 s. A false trigger costs one decode.
    static let minimumSpeechSeconds = 0.8
    /// Audio before the last word's end, so the tail decode starts with context.
    static let contextSeconds = 2.0
    /// FluidAudio's bar for accepting a recovered decode (#909).
    static let minimumConfidence: Float = 0.7

    public static func complete(_ audio: PCM16k, text: String, words: [TimedWord]?,
                                isolation: isolated (any Actor)? = #isolation,
                                redecode: (PCM16k) async throws -> [TimedWord]?) async throws -> ASRResult {
        var coverage = TranscriptCoverage(.unavailable, audioSeconds: audio.duration)
        func result(_ text: String, timed: Bool = true) -> ASRResult {
            .init(text: text, audioDuration: audio.duration, coverage: coverage, words: timed ? words : nil)
        }
        guard let words else { return result(text) }
        guard let last = words.last else { coverage.outcome = .noWords; return result(text) }
        let samples = audio.samples
        let speech = speechSeconds(samples, from: sample(last.end), threshold: speechThreshold(samples))
        coverage.lastWordEndSeconds = last.end; coverage.speechAfterSeconds = speech
        guard speech >= minimumSpeechSeconds else { coverage.outcome = .covered; return result(text) }
        guard samples.count > windowSamples else { coverage.outcome = .uncovered; return result(text) }
        let started = ContinuousClock.now
        let start = sample(last.end - contextSeconds) / frameSamples * frameSamples
        let tail = try await redecode(PCM16k(Array(samples[start..<min(samples.count, start + windowSamples)])))
        coverage.fallbackMS = started.duration(to: .now).milliseconds
        let missing = missingWords(after: words, in: tail ?? [], offset: Double(start) / Double(PCM16k.rate))
        coverage.outcome = missing.isEmpty ? .unrecovered : .recovered
        coverage.recoveredWords = missing.count
        return missing.isEmpty ? result(text) : result(([text] + missing.map(\.text)).joined(separator: " "), timed: false)
    }

    /// Tail words starting after the transcript's last word ends (one frame of emission
    /// jitter allowed), minus a re-heard copy of up to its last three words. Empty unless
    /// FluidAudio would call the decode credible.
    static func missingWords(after transcript: [TimedWord], in tail: [TimedWord], offset: Double) -> [TimedWord] {
        guard let last = transcript.last else { return [] }
        let jitter = Double(frameSamples) / Double(PCM16k.rate)
        var missing = tail.filter { offset + $0.start >= last.end - jitter }
        let key = { (word: TimedWord) in WordTokens.words(word.text) }
        let ending = transcript.suffix(3).map(key)
        for count in stride(from: min(ending.count, missing.count), through: 1, by: -1)
        where Array(ending.suffix(count)) == missing.prefix(count).map(key) {
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
