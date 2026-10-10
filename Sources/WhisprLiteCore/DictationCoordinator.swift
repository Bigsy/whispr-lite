import Foundation

@MainActor public protocol CaptureDriver: AnyObject {
    func begin() throws
    func end() async throws -> PCM16k
    func suspend()
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>?
    var firstAudioUptime: Double? { get }
}
public extension CaptureDriver {
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>? { nil }
    var firstAudioUptime: Double? { nil }
}
@MainActor public protocol InsertionDriver: AnyObject {
    func snapshot() -> UUID
    func insert(_ text: String, target: UUID) async throws
}
@MainActor public protocol MediaDriver: AnyObject {
    func begin(_ session: UUID)
    func end(_ session: UUID)
}
public enum DictationState: String, Codable, Sendable { case idle, recording, processing, inserting, error }
@MainActor public final class DictationCoordinator {
    public private(set) var state: DictationState = .idle { didSet { onChange?() } }
    public private(set) var recoveryText: String?
    public private(set) var message = "Preparing…"
    public var ready = false
    public var onChange: (() -> Void)?
    public var streamingEnabled = false
    public var prefill: PrefillScheduler?
    public private(set) var partial: PartialSnapshot?
    private var streaming: StreamingPipeline?
    private var delivery: Task<Void, Never>?
    private var streamingFailed = false
    public var safetyDuration: Duration = .seconds(120)
    public let timings: LatencyRecorder
    public var diagnostics: DiagnosticLogger?
    private let capture: any CaptureDriver
    private let insertion: any InsertionDriver
    private let media: any MediaDriver
    private var pipeline: BatchPipeline
    private var session: UUID?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var ceiling: Task<Void, Never>?
    private var finalized = false
    private var activationHeld = false
    private var draining = false
    public private(set) var insertionSession: UUID?
    public init(capture: any CaptureDriver, insertion: any InsertionDriver, media: any MediaDriver,
                pipeline: BatchPipeline, timings: LatencyRecorder = .init()) {
        self.capture = capture; self.insertion = insertion; self.media = media
        self.pipeline = pipeline; self.timings = timings
    }
    public func press() {
        guard !activationHeld else { return }
        activationHeld = true
        guard ready, !draining, state == .idle || state == .error else { message = "Busy or not ready"; onChange?(); return }
        let id = UUID(); generation &+= 1
        let owner = generation
        session = id; finalized = false; recoveryText = nil
        timings.mark(.press, session: id)
        (insertion as? TextInserter)?.diagnosticSession = id
        let target = insertion.snapshot()
        do { try capture.begin() }
        catch { diagnostics?.record(.init(.failure, session: id, code: .capture)); message = AppError.capture.localizedDescription; state = .error; session = nil; return }
        message = "Recording"; state = .recording
        media.begin(id)
        if streamingEnabled, pipeline.backend.capabilities.streaming, let chunks = capture.chunks() {
            let streaming = StreamingPipeline(backend: pipeline.backend)
            self.streaming = streaming; streamingFailed = false; partial = nil
            delivery = Task { [weak self] in
                guard let self else { return }
                do {
                    try await streaming.start()
                    for try await chunk in chunks {
                        try Task.checkCancellation()
                        if let snapshot = try await streaming.append(chunk), self.generation == owner {
                            self.partial = snapshot
                            if self.state == .recording { await self.prefill?.submit(snapshot) }
                        }
                    }
                } catch { await streaming.cancel(); if self.generation == owner { self.streamingFailed = true } }
            }
        }
        ceiling = Task { [weak self] in
            do { try await Task.sleep(for: self?.safetyDuration ?? .seconds(120)) } catch { return }
            guard let self, self.generation == owner else { return }
            self.finish(id, target: target, copyOnly: true)
        }
        // The target belongs to this recording, never the currently frontmost app at release.
        currentTarget = target
    }
    private var currentTarget: UUID?
    public func release() {
        activationHeld = false
        guard let id = session, let target = currentTarget, state == .recording else { return }
        timings.mark(.release, session: id)
        finish(id, target: target, copyOnly: false)
    }
    private func finish(_ id: UUID, target: UUID, copyOnly: Bool) {
        guard session == id, !finalized else { return }
        finalized = true; draining = true; ceiling?.cancel(); ceiling = nil
        message = "Processing"; state = .processing
        let owner = generation
        task = Task { [weak self] in
            guard let self else { return }
            // Even cancellation must wait for capture handoff before ending its media lease.
            let audio: PCM16k
            do { audio = try await self.capture.end() }
            catch {
                self.draining = false; self.media.end(id)
                if self.generation == owner { self.fail(.capture) }
                return
            }
            self.draining = false
            self.timings.mark(.captureFinalized, session: id)
            if self.timings.isEnabled, let first = self.capture.firstAudioUptime { self.timings.mark(.firstAudio, session: id, uptime: first) }
            self.diagnostics?.record(.init(.capture, session: id, sampleCount: audio.samples.count))
            self.media.end(id)
            guard self.generation == owner, !Task.isCancelled else { return }
            do {
                let recorder = self.timings
                var mark: (@Sendable (TimingStage) async -> Void)?
                if recorder.isEnabled { mark = { stage in await recorder.mark(stage, session: id) } }
                let text: String?
                if let streaming = self.streaming {
                    await self.delivery?.value
                    await self.prefill?.stop()
                    guard self.generation == owner, !Task.isCancelled else { return }
                    if !self.streamingFailed { text = try await streaming.finish(cleanup: self.pipeline.cleanup) }
                    else { text = try await self.pipeline.run(audio, mark: mark) }
                } else {
                    text = try await self.pipeline.run(audio, mark: mark)
                }
                guard self.generation == owner, !Task.isCancelled else { return }
                self.timings.mark(.resultReady, session: id)
                guard let text else { self.complete(); return }
                self.recoveryText = String(text.prefix(32_768))
                if copyOnly { self.streaming = nil; self.delivery = nil; self.partial = nil; self.message = "Recording limit reached. Copy the result."; self.state = .error; self.session = nil; return }
                self.insertionSession = id
                (self.insertion as? TextInserter)?.diagnosticSession = id
                self.message = "Inserting"; self.state = .inserting
                try await self.insertion.insert(text, target: target)
                guard self.generation == owner, !Task.isCancelled else { return }
                self.timings.mark(.insertionDispatched, session: id)
                self.complete()
            } catch is CancellationError { if self.generation == owner { self.complete() } }
            catch let error as PipelineFailure {
                guard self.generation == owner else { return }
                self.recoveryText = error.rawText.map { String($0.prefix(32_768)) }; self.fail(error.reason)
            } catch { if self.generation == owner { self.fail(error as? AppError ?? .inference) } }
        }
    }
    public func cancel() {
        if let session { diagnostics?.record(.init(.cancelled, session: session)) }
        generation &+= 1; activationHeld = false; insertionSession = nil
        let owner = generation
        task?.cancel(); task = nil; ceiling?.cancel(); ceiling = nil
        delivery?.cancel(); delivery = nil
        let oldStream = streaming; streaming = nil
        let oldPrefill = prefill
        Task { await oldStream?.cancel(); await oldPrefill?.stop() }
        if let id = session, !finalized {
            finalized = true; draining = true
            // Serialize the end before allowing another recording to own the capture buffers.
            message = "Cancelling"; state = .processing
            task = Task { [weak self] in
                guard let self else { return }
                _ = try? await self.capture.end()
                self.media.end(id); self.draining = false
                if self.generation == owner { self.complete() }
            }
        } else { complete() }
    }
    public func recordVisibleText() -> Double? {
        guard let id = insertionSession else { return nil }
        insertionSession = nil; timings.mark(.visibleText, session: id)
        guard let release = timings.events.last(where: { $0.session == id && $0.stage == .release }),
              let visible = timings.events.last(where: { $0.session == id && $0.stage == .visibleText }) else { return nil }
        return (visible.seconds - release.seconds) * 1000
    }
    public func suspend() {
        ready = false
        cancel()
        capture.suspend()
    }
    public func setMessage(_ value: String) { message = value; onChange?() }
    private func fail(_ error: AppError) { diagnostics?.record(.init(.failure, session: session, code: .failure(error))); streaming = nil; delivery = nil; partial = nil; message = error.localizedDescription; state = .error; session = nil }
    private func complete() { if let session { diagnostics?.record(.init(.completed, session: session)) }; streaming = nil; delivery = nil; partial = nil; session = nil; currentTarget = nil; message = ready ? "Ready" : "Not ready"; state = .idle }
}
