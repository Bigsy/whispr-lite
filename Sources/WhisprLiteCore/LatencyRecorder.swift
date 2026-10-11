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
    @discardableResult public func mark(_ stage: TimingStage, session: UUID, uptime: Double? = nil) -> TimingEvent? {
        guard isEnabled, let origin else { return nil }
        let event = TimingEvent(session: session, stage: stage, seconds: (uptime ?? now()) - origin)
        events.append(event)
        if events.count > 1280 { events.removeFirst(events.count - 1024) }
        onEvent?(event)
        return event
    }
    public func span(from start: TimingStage, to end: TimingStage, session: UUID) -> Double? {
        guard let first = events.last(where: { $0.session == session && $0.stage == start }),
              let last = events.last(where: { $0.session == session && $0.stage == end }),
              last.seconds >= first.seconds else { return nil }
        return (last.seconds - first.seconds) * 1000
    }
}
