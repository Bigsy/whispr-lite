import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

func monoFormat(rate: Double = 16_000) throws -> AVAudioFormat {
    try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
        channels: 1, interleaved: false))
}

func filledBuffer(format: AVAudioFormat, frames: AVAudioFrameCount,
                  value: Float) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = value }
    }
    return buffer
}

func decodeJSONLines<Value: Decodable>(_ file: URL, as type: Value.Type) throws -> [Value] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n")
        .map { try decoder.decode(type, from: Data($0.utf8)) }
}

actor CountingCleanup: TextCleanup {
    var calls = 0
    func clean(_ text: String) -> String { calls += 1; return text }
}
actor RecordingCleanup: TextCleanup {
    var inputs: [String] = []
    var started = false
    private let delay: Duration?
    init(delay: Duration? = nil) { self.delay = delay }
    func clean(_ text: String) async throws -> String {
        started = true
        inputs.append(text)
        if let delay { try await Task.sleep(for: delay) }
        return text
    }
}
struct FailingCleanup: TextCleanup { func clean(_ text: String) throws -> String { throw AppError.cleanup } }

@MainActor final class FakeCapture: CaptureDriver {
    var begins = 0; var ends = 0; var suspended = 0
    var boundaryValue: Double?
    var endBoundary: Double?
    var onBoundary: (() -> Void)?
    var endError: (any Error)?
    var captureReport: CaptureReport?
    func begin() -> CaptureStreams { begins += 1; return .none }
    func end(at boundary: Double?) async throws -> CapturedAudio {
        ends += 1
        endBoundary = boundary
        if let endError { throw endError }
        return try .init(pcm: PCM16k([0.1]))
    }
    func releaseBoundary() -> Double? { onBoundary?(); return boundaryValue }
    func suspend() { suspended += 1 }
}
@MainActor final class EarlyCapture: CaptureDriver {
    var ends = 0
    private var continuation: AsyncThrowingStream<PCM16k, any Error>.Continuation?
    func begin() -> CaptureStreams {
        let pair = AsyncThrowingStream<PCM16k, any Error>.makeStream()
        continuation = pair.continuation
        return .completed(pair.stream)
    }
    func publish() throws { continuation?.yield(try PCM16k([0.1])) }
    func end(at boundary: Double?) throws -> CapturedAudio {
        ends += 1; continuation?.finish(); continuation = nil
        return try .init(pcm: PCM16k([0.1, 0.2]))
    }
    func suspend() {}
}
actor EarlyBackend: ASRBackend {
    nonisolated let capabilities = ASRCapabilities()
    func prepare() async throws {}
    func readiness() async -> BackendReadiness { .ready }
    func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        .init(text: audio.samples.count == 1 ? "First sentence." : "First sentence. Second sentence.", audioDuration: audio.duration)
    }
}
@MainActor final class FakeInsertion: InsertionDriver {
    var texts: [String] = []; var shouldFail = false
    var snapshots: [(session: UUID, target: UUID)] = []
    var insertedTargets: [UUID] = []
    func snapshot(session: UUID) -> UUID {
        let target = UUID()
        snapshots.append((session, target))
        return target
    }
    func insert(_ text: String, target: UUID) throws {
        try Task.checkCancellation()
        guard snapshots.contains(where: { $0.target == target }) else { throw AppError.targetChanged }
        if shouldFail { throw AppError.targetChanged }
        insertedTargets.append(target); texts.append(text)
    }
}
@MainActor final class OrderedInsertion: InsertionDriver {
    let capture: FakeCapture; var beginsAtSnapshot: [Int] = []
    init(_ capture: FakeCapture) { self.capture = capture }
    func snapshot(session: UUID) -> UUID { beginsAtSnapshot.append(capture.begins); return UUID() }
    func insert(_ text: String, target: UUID) throws {}
}
@MainActor final class FakeMedia: MediaDriver {
    var begins: [UUID] = []; var ends: [UUID] = []
    func begin(_ session: UUID) { begins.append(session) }
    func end(_ session: UUID) { ends.append(session) }
}
actor AsyncGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var exitWaiter: CheckedContinuation<Void, Never>?
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func enterAndWait() async {
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { exitWaiter = $0 }
    }
    func open() { exitWaiter?.resume(); exitWaiter = nil }
}
actor WarmupBackend: HoldWarmableASRBackend {
    nonisolated let capabilities = ASRCapabilities()
    private let warmGate: AsyncGate?
    private(set) var warmCalls = 0
    private(set) var finalBeforeWarmSettled = false
    private(set) var transcribedWhileWarming = false
    private var warmSettled = false
    private var warming = false
    init(warmGate: AsyncGate? = nil) { self.warmGate = warmGate }
    func prepare() async throws {}
    func readiness() async -> BackendReadiness { .ready }
    func warmForRecording() async throws {
        warmCalls += 1
        warming = true
        if let warmGate { await warmGate.enterAndWait() }
        else { try await Task.sleep(for: .milliseconds(80)) }
        warming = false
        warmSettled = true
    }
    func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        if !warmSettled { finalBeforeWarmSettled = true }
        if warming { transcribedWhileWarming = true }
        return .init(text: "Synthetic words", audioDuration: audio.duration)
    }
}

@MainActor func poll(timeout: Duration = .seconds(1),
                     _ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await condition(), "Condition was not met before the test deadline")
}
