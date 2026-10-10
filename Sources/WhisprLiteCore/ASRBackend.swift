import Foundation

public enum AppError: Error, Sendable, Equatable, LocalizedError {
    case invalidAudio, audioLimit, notReady, unsupported, inference, cleanup, contextLimit
    case deadline(String), capture, overflow, targetChanged, modifiersHeld, clipboard, protocolViolation
    public var errorDescription: String? {
        switch self {
        case .invalidAudio: "Invalid PCM samples."
        case .audioLimit: "Recording exceeds the 120-second limit."
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
    public static let maximumSamples = 120 * rate
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
    public init(text: String, audioDuration: Double) { self.text = text; self.audioDuration = audioDuration }
}
public struct ASRCapabilities: Sendable {
    public let streaming: Bool
    public init(streaming: Bool = false) { self.streaming = streaming }
}
public enum BackendReadiness: Sendable, Equatable { case unloaded, preparing, ready, failed }
public enum BackendPreparation: String, Codable, Sendable {
    case preparing = "Preparing backend"
    case checkingCache = "Checking ASR model cache"
    case downloading = "Downloading ASR models"
    case loading = "Loading ASR models"
    case warmingUp = "Warming ASR models"
    case ready = "ASR ready"
}
public struct PartialSnapshot: Sendable, Equatable {
    public let revision: Int
    public let text: String
    public init(revision: Int, text: String) { self.revision = revision; self.text = text }
}
public protocol ASRSession: Sendable {
    func append(_ audio: PCM16k, startingAt offset: Int) async throws
    func partial() async throws -> PartialSnapshot?
    func finish() async throws -> ASRResult
    func cancel() async
}
public protocol ASRBackend: Sendable {
    var capabilities: ASRCapabilities { get }
    func prepare() async throws
    func prepare(progress: @escaping @Sendable (BackendPreparation) -> Void) async throws
    func readiness() async -> BackendReadiness
    func transcribe(_ audio: PCM16k) async throws -> ASRResult
    func makeSession() async throws -> any ASRSession
}
/// Optional one-shot work started away from the event-tap callback on a long-idle press.
public protocol PressWarmableASRBackend: ASRBackend {
    func warmForRecording() async throws
}
public extension ASRBackend {
    func prepare(progress: @escaping @Sendable (BackendPreparation) -> Void) async throws {
        progress(.preparing); try await prepare(); progress(.ready)
    }
    func makeSession() async throws -> any ASRSession { throw AppError.unsupported }
}

public struct FakeASRConfiguration: Sendable {
    public var text = "Demo dictation. This is fabricated text."
    public var preparationDelay: Duration = .milliseconds(10)
    public var inferenceDelay: Duration = .milliseconds(20)
    public var fails = false
    public var preparationFails = false
    public var ignoresCancellation = false
    public var partials = ["Thursday", "Friday."]
    public init() {}
}
/// Only selected by explicit demo settings or synthetic test/benchmark code.
public actor FakeASRBackend: ASRBackend {
    public nonisolated let capabilities = ASRCapabilities(streaming: true)
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
    public func makeSession() async throws -> any ASRSession {
        guard state == .ready else { throw AppError.notReady }
        return FakeASRSession(configuration)
    }
}
public actor FakeASRSession: ASRSession {
    private let configuration: FakeASRConfiguration
    private var count = 0
    private var revision = 0
    private var ended = false
    private var cancelled = false
    public init(_ configuration: FakeASRConfiguration) { self.configuration = configuration }
    public func append(_ audio: PCM16k, startingAt offset: Int) throws {
        guard !ended, offset == count, audio.samples.count <= 16_000 else { throw AppError.protocolViolation }
        guard audio.samples.count <= PCM16k.maximumSamples - count else { throw AppError.audioLimit }
        count += audio.samples.count
        revision += 1
    }
    public func partial() throws -> PartialSnapshot? {
        guard !ended else { throw AppError.protocolViolation }
        guard revision > 0, !configuration.partials.isEmpty else { return nil }
        return .init(revision: revision, text: configuration.partials[min(revision - 1, configuration.partials.count - 1)])
    }
    public func finish() async throws -> ASRResult {
        guard !ended else { throw AppError.protocolViolation }
        ended = true
        if configuration.ignoresCancellation {
            await Task.detached { try? await Task.sleep(for: self.configuration.inferenceDelay) }.value
        } else {
            try await Task.sleep(for: configuration.inferenceDelay)
            guard !cancelled else { throw CancellationError() }
        }
        if configuration.fails { throw AppError.inference }
        return .init(text: count == 0 ? "" : configuration.text, audioDuration: Double(count) / 16_000)
    }
    public func cancel() { cancelled = true; ended = true }
}
