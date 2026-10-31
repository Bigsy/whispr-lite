import Foundation
import ParakeetCore

public enum AppError: Error, Sendable, Equatable, LocalizedError {
    case invalidAudio, audioLimit, notReady, unsupported, inference, cleanup, contextLimit
    case deadline(String), capture, overflow, targetChanged, modifiersHeld, clipboard, protocolViolation
    public var errorDescription: String? {
        switch self {
        case .invalidAudio: "Invalid PCM samples."
        case .audioLimit: "Recording exceeds the \(Int(PCM16k.maximumDuration))-second limit."
        case .notReady: "The selected backend is not ready."
        case .unsupported: "This operation is unavailable in this build."
        case .inference: "Transcription failed."
        case .cleanup: "Cleanup failed. Raw text is available to copy."
        case .contextLimit: "Text exceeds the cleanup context budget. Copy the raw text."
        case .deadline(let stage): "\(stage) deadline exceeded."
        case .capture: "Microphone capture failed. Check the device and permission."
        case .overflow: "Audio delivery overflowed. Recording was cancelled."
        case .targetChanged: "The destination changed or cannot accept text. Copy the result."
        case .modifiersHeld: "Release held modifier keys. Copy the result."
        case .clipboard: "Clipboard data could not be safely preserved. Copy the result."
        case .protocolViolation: "Invalid backend protocol data."
        }
    }
}

public struct PCM16k: Sendable, Equatable {
    public static let rate = 16_000
    public static let maximumDuration = 120.0
    public static let maximumSamples = Int(maximumDuration) * rate
    public let samples: [Float]
    public var duration: Double { Double(samples.count) / Double(Self.rate) }
    public init(_ samples: [Float]) throws {
        guard samples.count <= Self.maximumSamples else { throw AppError.audioLimit }
        guard samples.allSatisfy(\.isFinite) else { throw AppError.invalidAudio }
        self.samples = samples
    }
}
public struct ASRResult: Sendable, Equatable {
    public let text: String
    public let audioDuration: Double
    /// Direct Parakeet only; see `TranscriptTail`.
    public let coverage: TranscriptCoverage?
    /// Direct Parakeet only, including absolute word timings from credible tail recovery.
    public let words: [TimedWord]?
    public init(text: String, audioDuration: Double, coverage: TranscriptCoverage? = nil, words: [TimedWord]? = nil) {
        self.text = text; self.audioDuration = audioDuration; self.coverage = coverage; self.words = words
    }
}
public enum BackendReadiness: Sendable, Equatable { case unloaded, preparing, ready, failed }
public enum BackendPreparation: String, Codable, Sendable {
    case preparing, checkingCache, downloading, loading, warmingUp, ready

    public var displayName: String {
        switch self {
        case .preparing: "Preparing backend"
        case .checkingCache: "Checking ASR model cache"
        case .downloading: "Downloading ASR models"
        case .loading: "Loading ASR models"
        case .warmingUp: "Warming ASR models"
        case .ready: "ASR ready"
        }
    }
}
public protocol ASRBackend: Sendable {
    func prepare() async throws
    func prepare(progress: @escaping @Sendable (BackendPreparation, Double?) -> Void) async throws
    func readiness() async -> BackendReadiness
    func transcribe(_ audio: PCM16k) async throws -> ASRResult
}
/// Optional keep-warm work while a recording is held, away from the event-tap callback.
public protocol HoldWarmableASRBackend: ASRBackend {
    func warmForRecording() async throws
}
public extension ASRBackend {
    func prepare(progress: @escaping @Sendable (BackendPreparation, Double?) -> Void) async throws {
        progress(.preparing, nil); try await prepare(); progress(.ready, nil)
    }
}

public struct FakeASRConfiguration: Sendable {
    var text = "Demo dictation. This is fabricated text."
    var preparationDelay: Duration = .milliseconds(10)
    var inferenceDelay: Duration = .milliseconds(20)
    var fails = false
    var preparationFails = false
    var ignoresCancellation = false
    public init() {}
}
/// Only selected by explicit demo settings or synthetic test/benchmark code.
public actor FakeASRBackend: ASRBackend {
    private let configuration: FakeASRConfiguration
    private var state: BackendReadiness = .unloaded
    public init(_ configuration: FakeASRConfiguration = .init()) { self.configuration = configuration }
    public func readiness() -> BackendReadiness { state }
    public func prepare() async throws {
        if state == .ready { return }
        state = .preparing
        do {
            try await Task.sleep(for: configuration.preparationDelay)
            if configuration.preparationFails { throw AppError.inference }
            state = .ready
        } catch { state = .failed; throw error }
    }
    public func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        guard state == .ready else { throw AppError.notReady }
        if configuration.ignoresCancellation {
            await Task.detached { try? await Task.sleep(for: self.configuration.inferenceDelay) }.value
        } else { try await Task.sleep(for: configuration.inferenceDelay) }
        if configuration.fails { throw AppError.inference }
        return .init(text: audio.samples.isEmpty ? "" : configuration.text, audioDuration: audio.duration)
    }
}
