import Foundation

public enum TimingStage: String, Codable, Sendable {
    case press, firstAudio, release, captureFinalized, mediaPause, mediaResume
    case asrStart, asrEnd, cleanupStart, cleanupEnd, resultReady, insertionDispatched, visibleText, clipboardRestored
}
public struct TimingEvent: Codable, Sendable {
    public let session: UUID
    public let stage: TimingStage
    public let seconds: Double
}
@MainActor public final class LatencyRecorder {
    private var origin: Double?
    private let now: () -> Double
    public private(set) var isEnabled = false
    public private(set) var events: [TimingEvent] = []
    public var onEvent: ((TimingEvent) -> Void)?
    public init(enabled: Bool = false, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        setEnabled(enabled)
    }
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        events.removeAll()
        origin = enabled ? now() : nil
    }
    public func mark(_ stage: TimingStage, session: UUID, uptime: Double? = nil) {
        guard isEnabled, let origin else { return }
        let event = TimingEvent(session: session, stage: stage, seconds: (uptime ?? now()) - origin)
        events.append(event)
        if events.count > 1024 { events.removeFirst(events.count - 1024) }
        onEvent?(event)
    }
}
