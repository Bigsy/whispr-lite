import Foundation

@MainActor public protocol CaptureDriver: AnyObject {
    func begin() throws
    func end() async throws -> PCM16k
    func end(at boundary: Double?) async throws -> PCM16k
    func releaseBoundary() -> Double?
    func suspend()
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>?
    func completedChunks() -> AsyncThrowingStream<PCM16k, any Error>?
    var firstAudioUptime: Double? { get }
    var drainTimedOut: Bool { get }
}
public extension CaptureDriver {
    func end(at boundary: Double?) async throws -> PCM16k { try await end() }
    func releaseBoundary() -> Double? { nil }
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>? { nil }
    func completedChunks() -> AsyncThrowingStream<PCM16k, any Error>? { nil }
    var firstAudioUptime: Double? { nil }
    var drainTimedOut: Bool { false }
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
    /// The Neural Engine and CPU clock down within about a second of idle, and batch ASR has
    /// nothing to do while the key is held. One small inference this often keeps them up until
    /// release (147 to 89 ms median on a synthetic 4 s hold); nil disables. Idle is unaffected.
    public var holdWarmupInterval: Duration? = .milliseconds(500)
    private var partial: PartialSnapshot?
    private var streaming: StreamingPipeline?
    private var delivery: Task<Void, Never>?
    private var earlyDelivery: Task<[DictationText], Never>?
    private var streamingFailed = false
    public var safetyDuration: Duration = .seconds(PCM16k.maximumDuration)
    public let timings: LatencyRecorder
    public var diagnostics: DiagnosticLogger?
    /// Saves completed batch dictations locally when enabled; never demo or cancelled output.
    public var history: DictationHistory?
    private let capture: any CaptureDriver
    private let insertion: any InsertionDriver
    private let media: any MediaDriver
    private let pipeline: BatchPipeline
    private var session: UUID?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var holdWarmup: Task<Void, Never>?
    private var ceiling: Task<Void, Never>?
    private var finalized = false
    private var activationHeld = false
    private var draining = false
    private var insertionSession: UUID?
    public init(capture: any CaptureDriver, insertion: any InsertionDriver, media: any MediaDriver,
                pipeline: BatchPipeline, timings: LatencyRecorder = .init()) {
        self.capture = capture; self.insertion = insertion; self.media = media
        self.pipeline = pipeline; self.timings = timings
    }
    public func press() {
        guard !activationHeld else { return }
        activationHeld = true
        let canStart = !draining && (state == .idle || state == .error)
        guard ready, canStart else {
            if !ready, canStart {
                // The event tap swallowed the shortcut, so say why rather than doing nothing.
                diagnostics?.record(.init(.failure, code: .notReady))
                message = "Dictation isn't ready yet. Check the Whispr Lite menu."; state = .error
            } else { message = "Busy or not ready"; onChange?() }
            return
        }
        let id = UUID(); generation &+= 1
        let owner = generation
        session = id; finalized = false; recoveryText = nil
        timings.mark(.press, session: id)
        (insertion as? TextInserter)?.diagnosticSession = id
        do { try capture.begin() }
        catch { fail(AppError.capture); return }
        // After capture starts: the snapshot is synchronous AX IPC into the target app and can be slow.
        let target = insertion.snapshot()
        message = "Recording"; state = .recording
        media.begin(id)
        startHoldWarmup()
        if streamingEnabled, pipeline.backend.capabilities.streaming, let chunks = capture.chunks() {
            let streaming = StreamingPipeline(pipeline: pipeline)
            self.streaming = streaming; streamingFailed = false; partial = nil
            delivery = Task { [weak self] in
                guard let self else { return }
                do {
                    try await streaming.start()
                    for try await chunk in chunks {
                        try Task.checkCancellation()
                        if let snapshot = try await streaming.append(chunk), self.generation == owner {
                            self.partial = snapshot
                        }
                    }
                } catch { await streaming.cancel(); if self.generation == owner { self.streamingFailed = true } }
            }
        } else if let chunks = capture.completedChunks() {
            let pipeline = self.pipeline
            earlyDelivery = Task { [weak self] in
                guard let self else { return [] }
                var completed: [DictationText] = []
                do {
                    for try await chunk in chunks {
                        guard self.generation == owner, self.state == .recording else { break }
                        // Stop the periodic silence pass before using the same CoreML engine.
                        self.holdWarmup?.cancel()
                        await self.holdWarmup?.value
                        guard self.generation == owner, self.state == .recording else { break }
                        // Resume keep-warm after this chunk's ASR/cleanup settles. The next
                        // chunk cancels and awaits that pass before reusing the engine.
                        defer {
                            if self.generation == owner, self.state == .recording { self.startHoldWarmup() }
                        }
                        guard let raw = try await pipeline.transcribe(chunk), raw.endsSentence else { break }
                        let result = try await pipeline.finish(raw)
                        guard result.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).endsSentence else { break }
                        completed.append(result)
                    }
                    return completed
                } catch { return completed }
            }
        }
        let safetyDuration = self.safetyDuration
        ceiling = Task { [weak self] in
            do { try await Task.sleep(for: safetyDuration) } catch { return }
            guard let self, self.generation == owner else { return }
            self.finish(id, target: target, copyOnly: true, boundary: self.capture.releaseBoundary())
        }
        // The target belongs to this recording, never the currently frontmost app at release.
        currentTarget = target
    }
    private var currentTarget: UUID?
    public func release() {
        activationHeld = false
        guard let id = session, let target = currentTarget, state == .recording else { return }
        let boundary = capture.releaseBoundary()
        timings.mark(.release, session: id)
        finish(id, target: target, copyOnly: false, boundary: boundary)
    }
    private func finish(_ id: UUID, target: UUID, copyOnly: Bool, boundary: Double?) {
        guard session == id, !finalized else { return }
        holdWarmup?.cancel() // No new pass after release; final ASR awaits any pass in flight.
        finalized = true; draining = true; ceiling?.cancel(); ceiling = nil
        message = "Processing"; state = .processing
        let owner = generation
        task = Task { [weak self] in
            guard let self else { return }
            // Even cancellation must wait for capture handoff before ending its media lease.
            let audio: PCM16k
            do { audio = try await self.capture.end(at: boundary) }
            catch {
                _ = await self.earlyDelivery?.value
                self.draining = false; self.media.end(id)
                if self.generation == owner { self.fail(AppError.capture) }
                return
            }
            self.draining = false
            self.timings.mark(.captureFinalized, session: id)
            if self.timings.isEnabled, let first = self.capture.firstAudioUptime { self.timings.mark(.firstAudio, session: id, uptime: first) }
            self.diagnostics?.record(.init(.capture, session: id, code: self.capture.drainTimedOut ? .drainTimeout : nil, sampleCount: audio.samples.count))
            self.media.end(id)
            guard self.generation == owner, !Task.isCancelled else { return }
            do {
                // A cancelled task can return before CoreML has settled. The warm-up
                // itself is never cancelled; final ASR and model replacement await it.
                await self.holdWarmup?.value
                guard self.generation == owner, !Task.isCancelled else { return }
                let recorder = self.timings
                var mark: (@Sendable (TimingStage) async -> Void)?
                if recorder.isEnabled { mark = { stage in await recorder.mark(stage, session: id) } }
                let text: String?
                var dictation: DictationText?
                if let streaming = self.streaming {
                    await self.delivery?.value
                    guard self.generation == owner, !Task.isCancelled else { return }
                    if !self.streamingFailed { text = try await streaming.finish(audio: audio) }
                    else { text = try await self.pipeline.run(audio, mark: mark) }
                } else {
                    let early = self.earlyDelivery
                    // The structured child is awaited even if final ASR throws, so the
                    // early worker has settled before this task releases the engine.
                    async let prepared = early?.value
                    if let raw = try await self.pipeline.transcribe(audio, mark: mark) {
                        dictation = try await self.pipeline.finish(raw, early: await prepared ?? [], mark: mark)
                    } else { dictation = nil }
                    text = dictation?.cleaned
                }
                guard self.generation == owner, !Task.isCancelled else { return }
                if let dictation { self.history?.record(dictation) }
                self.timings.mark(.resultReady, session: id)
                guard let text else { self.complete(); return }
                self.recoveryText = String(text.prefix(DictationHistory.maximumTextCharacters))
                if copyOnly { self.endSession(.copyOnly); return }
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
                self.recoveryText = error.rawText.map { String($0.prefix(DictationHistory.maximumTextCharacters)) }; self.fail(error.reason)
            } catch { if self.generation == owner { self.fail(error) } }
        }
    }
    public func cancel() {
        // Escape arrives from every app; with nothing to cancel or dismiss, leave state and UI alone.
        guard session != nil || state != .idle || draining else { activationHeld = false; insertionSession = nil; return }
        if let session { diagnostics?.record(.init(.cancelled, session: session)) }
        generation &+= 1; activationHeld = false; insertionSession = nil
        holdWarmup?.cancel()
        let owner = generation
        task?.cancel(); task = nil; ceiling?.cancel(); ceiling = nil
        delivery?.cancel(); delivery = nil
        let oldStream = streaming; streaming = nil
        if let oldStream { Task { await oldStream.cancel() } }
        if let id = session, !finalized {
            finalized = true; draining = true
            // Serialize the end before allowing another recording to own the capture buffers.
            message = "Cancelling"; state = .processing
            task = Task { [weak self] in
                guard let self else { return }
                _ = try? await self.capture.end()
                _ = await self.earlyDelivery?.value
                self.media.end(id); self.draining = false
                if self.generation == owner { self.complete() }
            }
        } else if let earlyDelivery {
            // A cancelled cleanup request can return before CoreML finishes. Keep
            // the coordinator busy until the early worker has actually settled.
            draining = true; message = "Cancelling"; state = .processing
            task = Task { [weak self] in
                _ = await earlyDelivery.value
                guard let self, self.generation == owner else { return }
                self.draining = false; self.complete()
            }
        } else { complete() }
    }
    public func recordVisibleText() -> Double? {
        guard let id = insertionSession else { return nil }
        insertionSession = nil; timings.mark(.visibleText, session: id)
        return timings.span(from: .release, to: .visibleText, session: id)
    }
    public func suspend() {
        ready = false
        cancel()
        capture.suspend()
    }
    public func settleBackendWork() async { await holdWarmup?.value; _ = await earlyDelivery?.value }
    private func startHoldWarmup() {
        guard !streamingEnabled, holdWarmup == nil, let interval = holdWarmupInterval,
              let backend = pipeline.backend as? any HoldWarmableASRBackend else { return }
        holdWarmup = Task { [weak self] in
            repeat {
                // Its own task: cancelling the loop never cancels CoreML mid-inference.
                await Task { _ = try? await backend.warmForRecording() }.value
                do { try await Task.sleep(for: interval) } catch { break }
            } while !Task.isCancelled && self?.state == .recording
            self?.holdWarmup = nil
        }
    }
    private enum SessionEnd { case completed, failed(any Error), copyOnly }
    private func endSession(_ result: SessionEnd) {
        if let session {
            switch result {
            case .completed: diagnostics?.record(.init(.completed, session: session))
            case .failed(let error): diagnostics?.record(.init(.failure, session: session, code: .failure(error)))
            case .copyOnly: diagnostics?.record(.init(.completed, session: session, code: .copyOnly))
            }
        }
        streaming = nil; delivery = nil; earlyDelivery = nil; partial = nil
        session = nil; currentTarget = nil; draining = false
        switch result {
        case .completed:
            message = ready ? "Ready" : "Not ready"
            state = .idle
        case .failed(let error):
            message = (error as? AppError ?? .inference).localizedDescription
            state = .error
        case .copyOnly:
            message = "Recording limit reached. Copy the result."
            state = .error
        }
    }
    private func fail(_ error: any Error) { endSession(.failed(error)) }
    private func complete() { endSession(.completed) }
}
