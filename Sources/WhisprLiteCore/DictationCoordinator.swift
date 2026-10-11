import Foundation

@MainActor public protocol CaptureDriver: AnyObject {
    func begin() throws
    func end() async throws -> PCM16k
    func suspend()
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>?
    func completedChunks() -> AsyncThrowingStream<PCM16k, any Error>?
    var firstAudioUptime: Double? { get }
    var drainTimedOut: Bool { get }
}
public extension CaptureDriver {
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
    public var prefill: PrefillScheduler?
    public private(set) var partial: PartialSnapshot?
    private var streaming: StreamingPipeline?
    private var delivery: Task<Void, Never>?
    private var earlyDelivery: Task<[DictationText]?, Never>?
    private var streamingFailed = false
    public var safetyDuration: Duration = .seconds(120)
    public let timings: LatencyRecorder
    public var diagnostics: DiagnosticLogger?
    /// Saves completed batch dictations locally when enabled; never demo or cancelled output.
    public var history: DictationHistory?
    private let capture: any CaptureDriver
    private let insertion: any InsertionDriver
    private let media: any MediaDriver
    private var pipeline: BatchPipeline
    private var session: UUID?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var pressWarmup: Task<Void, Never>?
    private var pressWarmupSerial: UInt64 = 0
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
        guard ready, !draining, state == .idle || state == .error else {
            if !ready, !draining, state == .idle || state == .error {
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
        catch { diagnostics?.record(.init(.failure, session: id, code: .capture)); message = AppError.capture.localizedDescription; state = .error; session = nil; return }
        // After capture starts: the snapshot is synchronous AX IPC into the target app and can be slow.
        let target = insertion.snapshot()
        message = "Recording"; state = .recording
        media.begin(id)
        startHoldWarmup()
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
        } else if let chunks = capture.completedChunks() {
            let pipeline = self.pipeline
            earlyDelivery = Task { [weak self] in
                guard let self else { return nil }
                var completed: [DictationText] = []
                do {
                    for try await chunk in chunks {
                        guard self.generation == owner, self.state == .recording else { break }
                        // Stop the periodic silence pass before using the same CoreML engine.
                        self.pressWarmup?.cancel()
                        await self.pressWarmup?.value
                        guard self.generation == owner, self.state == .recording else { break }
                        guard let raw = try await pipeline.transcribe(chunk), raw.endsSentence else { break }
                        let result = try await pipeline.finish(raw)
                        guard result.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).endsSentence else { break }
                        completed.append(result)
                    }
                    return completed
                } catch { return completed }
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
        pressWarmup?.cancel() // No new pass after release; final ASR awaits any pass in flight.
        finalized = true; draining = true; ceiling?.cancel(); ceiling = nil
        message = "Processing"; state = .processing
        let owner = generation
        task = Task { [weak self] in
            guard let self else { return }
            // Even cancellation must wait for capture handoff before ending its media lease.
            let audio: PCM16k
            do { audio = try await self.capture.end() }
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
                await self.pressWarmup?.value
                guard self.generation == owner, !Task.isCancelled else { return }
                let recorder = self.timings
                var mark: (@Sendable (TimingStage) async -> Void)?
                if recorder.isEnabled { mark = { stage in await recorder.mark(stage, session: id) } }
                let text: String?
                var dictation: DictationText?
                if let streaming = self.streaming {
                    await self.delivery?.value
                    await self.prefill?.stop()
                    guard self.generation == owner, !Task.isCancelled else { return }
                    if !self.streamingFailed { text = try await streaming.finish(cleanup: self.pipeline.cleanup) }
                    else { text = try await self.pipeline.run(audio, mark: mark) }
                } else {
                    let early = self.earlyDelivery
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
            } catch { if self.generation == owner { self.fail(error) } }
        }
    }
    public func cancel() {
        // Escape arrives from every app; with nothing to cancel or dismiss, leave state and UI alone.
        guard session != nil || state != .idle || draining else { activationHeld = false; insertionSession = nil; return }
        if let session { diagnostics?.record(.init(.cancelled, session: session)) }
        generation &+= 1; activationHeld = false; insertionSession = nil
        pressWarmup?.cancel()
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
        guard let release = timings.events.last(where: { $0.session == id && $0.stage == .release }),
              let visible = timings.events.last(where: { $0.session == id && $0.stage == .visibleText }) else { return nil }
        return (visible.seconds - release.seconds) * 1000
    }
    public func suspend() {
        ready = false
        cancel()
        capture.suspend()
    }
    public func settlePressWarmup() async { await pressWarmup?.value; _ = await earlyDelivery?.value }
    private func startHoldWarmup() {
        guard !streamingEnabled, pressWarmup == nil, let interval = holdWarmupInterval,
              let backend = pipeline.backend as? any PressWarmableASRBackend else { return }
        pressWarmupSerial &+= 1
        let serial = pressWarmupSerial
        pressWarmup = Task { [weak self] in
            repeat {
                // Its own task: cancelling the loop never cancels CoreML mid-inference.
                await Task { _ = try? await backend.warmForRecording() }.value
                do { try await Task.sleep(for: interval) } catch { break }
            } while !Task.isCancelled && self?.state == .recording
            guard let self, self.pressWarmupSerial == serial else { return }
            self.pressWarmup = nil
        }
    }
    public func setMessage(_ value: String) { message = value; onChange?() }
    private func fail(_ error: any Error) {
        diagnostics?.record(.init(.failure, session: session, code: .failure(error)))
        streaming = nil; delivery = nil; earlyDelivery = nil; partial = nil
        message = (error as? AppError ?? .inference).localizedDescription
        state = .error; session = nil
    }
    private func complete() { if let session { diagnostics?.record(.init(.completed, session: session)) }; streaming = nil; delivery = nil; earlyDelivery = nil; partial = nil; session = nil; currentTarget = nil; message = ready ? "Ready" : "Not ready"; state = .idle }
}
