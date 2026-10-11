import Foundation
import CoreGraphics
import ParakeetCore

public enum DiagnosticKind: String, Codable, Sendable {
    case loggingEnabled, loggingDisabled, configuration, preparationStarted, preparationProgress, preparationReady, preparationFailed
    case permissions, readiness, hotkey, state, timing, capture, mediaState, mediaCommand, mediaReply
    case targetSnapshot, modifierState, insertionCheck, insertionMethod, clipboardRestore, cancelled, completed, failure, suspended, shutdown
}
public enum DiagnosticCode: String, Codable, Sendable {
    case press, release, cancel, ready, notReady
    case disabled, starting, recovering, unavailable, begin, end, paused, resumed, skipped, unconfirmed, fatal, snapshot, issued, released
    case accessibilityDenied, noTarget, appChanged, elementChanged, disabledTarget, secureTarget, unsupportedRole, readonlyTarget
    case modifiersHeld, clipboard, capture, drainTimeout, overflow, deadline, inference, cleanup, contextLimit, unsupported, invalidAudio, audioLimit, protocolViolation, targetChanged
    case nativeAX, commandPaste, restored, userClipboardChanged, restoreFailed
    case missingCache, downloadFailed, preparationFailed, busy, queueFull, cancelled, copyOnly
    public static func failure(_ error: AppError) -> Self {
        switch error {
        case .deadline: .deadline
        case .invalidAudio: .invalidAudio
        case .audioLimit: .audioLimit
        case .notReady: .notReady
        case .unsupported: .unsupported
        case .inference: .inference
        case .cleanup: .cleanup
        case .contextLimit: .contextLimit
        case .capture: .capture
        case .overflow: .overflow
        case .targetChanged: .targetChanged
        case .modifiersHeld: .modifiersHeld
        case .clipboard: .clipboard
        case .protocolViolation: .protocolViolation
        }
    }
    public static func failure(_ error: any Error) -> Self {
        if let error = error as? AppError { return failure(error) }
        if error is CancellationError { return .cancelled }
        if let error = error as? ParakeetError {
            switch error {
            case .missingCache: return .missingCache
            case .downloadFailed: return .downloadFailed
            case .preparationFailed: return .preparationFailed
            case .busy: return .busy
            case .queueFull: return .queueFull
            case .cancelled: return .cancelled
            case .notReady: return .notReady
            case .queueDeadlineExceeded, .inferenceDeadlineExceeded: return .deadline
            case .invalidAudio: return .invalidAudio
            case .audioLimitExceeded: return .audioLimit
            case .invalidConfiguration, .unsupportedMode: return .unsupported
            case .invalidSampleOffset, .sessionFinished: return .protocolViolation
            case .inferenceFailed: return .inference
            }
        }
        return .inference
    }
}
public enum InsertionTargetKind: String, Codable, Sendable {
    case native, appleTerminal, iterm, ghostty, other
    public static func classify(bundleIdentifier: String?) -> Self {
        if let bundleIdentifier, bundleIdentifier == Bundle.main.bundleIdentifier { return .native }
        return switch bundleIdentifier {
        case "com.apple.Terminal": .appleTerminal
        case "com.googlecode.iterm2": .iterm
        case "com.mitchellh.ghostty": .ghostty
        default: .other
        }
    }
}
/// Only these five modifier categories can enter the log; no key codes or text.
public enum InsertionModifier: String, Codable, Sendable, CaseIterable {
    case command, control, option, shift, fn
    private var flag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .control: .maskControl
        case .option: .maskAlternate
        case .shift: .maskShift
        case .fn: .maskSecondaryFn
        }
    }
    static func held(in flags: CGEventFlags) -> [Self] { allCases.filter { flags.contains($0.flag) } }
}
/// Fixed protocol reasons; player identities and metadata never enter diagnostics.
public enum MediaDiagnosticReason: String, Codable, Sendable {
    case playerChanged, playerRestarted, itemChanged, itemIdentifierRefreshed, unidentifiedPlayer, unknownPlayer
    case externalPlayback, subscriptionUnavailable, alreadyPaused, endedBeforePause
    case closing, leaseBusy, noLease, sessionMismatch, pauseRejected, pauseUnconfirmed
    case resumeRejected, resumeUnconfirmed, queryTimeout
}
public struct DiagnosticConfiguration: Codable, Sendable {
    public let backend: BackendMode
    public let asrModel: ParakeetModel?
    public let warmCapture: Bool
    public let lowLatencyCapture: Bool
    public let pauseMedia: Bool
    public let audioActivity: Bool
    public let asrTimeout: Double
    public let cleanupTimeout: Double
    public init(_ preferences: Preferences) {
        backend = preferences.backend; warmCapture = preferences.warmCapture; pauseMedia = preferences.pauseMedia
        lowLatencyCapture = preferences.lowLatencyCapture
        asrModel = preferences.backend == .parakeet ? preferences.asrModel : nil
        audioActivity = preferences.showAudioActivity; asrTimeout = preferences.asrTimeoutSeconds; cleanupTimeout = preferences.cleanupTimeoutSeconds
    }
}
/// Typed fields intentionally provide no route for text, paths, URLs, titles or raw errors.
public struct DiagnosticRecord: Codable, Sendable {
    public var schema = 1
    public var timestamp = Date()
    public var uptimeMS = ProcessInfo.processInfo.systemUptime * 1000
    public var run: UUID?
    public let kind: DiagnosticKind
    public var session: UUID?
    public var stage: TimingStage?
    public var code: DiagnosticCode?
    public var state: DictationState?
    public var target: InsertionTargetKind?
    public var milliseconds: Double?
    public var sampleCount: Int?
    public var enabled: Bool?
    public var configuration: DiagnosticConfiguration?
    public var accessibility: Bool?
    public var microphone: Bool?
    public var inputMonitoring: Bool?
    public var droppedBefore: Int?
    public var known: Bool?
    public var playing: Bool?
    public var trustworthy: Bool?
    public var subscriptionHealthy: Bool?
    public var mediaReason: MediaDiagnosticReason?
    public var preparation: BackendPreparation?
    public var hardwareModifiers: [InsertionModifier]?
    public var sessionModifiers: [InsertionModifier]?
    public init(_ kind: DiagnosticKind, session: UUID? = nil, stage: TimingStage? = nil,
                code: DiagnosticCode? = nil, state: DictationState? = nil, target: InsertionTargetKind? = nil,
                milliseconds: Double? = nil, sampleCount: Int? = nil, enabled: Bool? = nil,
                configuration: DiagnosticConfiguration? = nil) {
        self.kind = kind; self.session = session; self.stage = stage; self.code = code; self.state = state
        self.target = target; self.milliseconds = milliseconds; self.sampleCount = sampleCount
        self.enabled = enabled; self.configuration = configuration
    }
}

/// Opt-in, bounded, asynchronous JSONL writer. No disk access on the caller's thread.
public final class DiagnosticLogger: @unchecked Sendable {
    public static let defaultMaximumBytes = 2 * 1024 * 1024
    public static let maximumStorageBytes = 2 * defaultMaximumBytes
    public let directory: URL
    private let queue = DispatchQueue(label: "WhisprLite.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private var failed = false
    private var pending = 0
    private var dropped = 0
    private let run = UUID()
    private let maximumBytes: Int
    private let maximumPending: Int
    private var handle: FileHandle?
    private var bytes = 0
    public init(directory: URL, maximumBytes: Int = DiagnosticLogger.defaultMaximumBytes, maximumPending: Int = 128) {
        self.directory = directory; self.maximumBytes = max(1024, maximumBytes); self.maximumPending = max(1, maximumPending)
    }
    public var isEnabled: Bool { lock.withLock { enabled && !failed } }
    public var hasFailed: Bool { lock.withLock { failed } }
    public var droppedEvents: Int { lock.withLock { dropped } }
    public func setEnabled(_ value: Bool) {
        lock.lock()
        guard enabled != value else { lock.unlock(); return }
        if value { enabled = true; failed = false }
        enqueueLocked(.init(value ? .loggingEnabled : .loggingDisabled))
        enabled = value
        if !value { queue.async { try? self.handle?.close(); self.handle = nil } }
        lock.unlock()
    }
    public func record(_ value: @autoclosure () -> DiagnosticRecord) {
        guard isEnabled else { return } // Disabled mode doesn't even construct a record.
        let record = value()
        lock.lock(); defer { lock.unlock() }
        guard enabled, !failed else { return }
        enqueueLocked(record)
    }
    private func enqueueLocked(_ value: DiagnosticRecord) {
        guard pending < maximumPending else { dropped += 1; return }
        var value = value; value.run = run
        if dropped > 0 { value.droppedBefore = dropped }
        pending += 1
        queue.async { [value] in
            do { try self.write(value) }
            catch { self.lock.withLock { self.failed = true }; try? self.handle?.close(); self.handle = nil }
            self.lock.withLock { self.pending -= 1 }
        }
    }
    private func open() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("debug.jsonl")
        if !manager.fileExists(atPath: file.path) { guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        handle = try FileHandle(forWritingTo: file); bytes = Int(try handle!.seekToEnd())
    }
    private func write(_ value: DiagnosticRecord) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value); data.append(10)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteUnknown) }
        if handle == nil { try open() }
        if bytes + data.count > maximumBytes {
            try handle?.close(); handle = nil
            let current = directory.appendingPathComponent("debug.jsonl"), previous = directory.appendingPathComponent("debug.previous.jsonl")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: current, to: previous)
            try open()
        }
        try handle?.write(contentsOf: data); bytes += data.count
    }
    /// Explicit tests/shutdown only; normal dictation never waits for disk.
    public func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    deinit { try? handle?.close() }
}
