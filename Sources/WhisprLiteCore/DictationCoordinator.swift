import Foundation

/// Completed speech chunks a long recording publishes while the key is held, for early cleanup.
public typealias EarlyChunks = AsyncThrowingStream<PCM16k, any Error>

/// One per final direct-Parakeet dictation that published an early chunk: how far early
/// cleanup got and whether the final transcript reused it. Counts and codes only.
public struct EarlyChunkReport: Codable, Sendable, Equatable {
    /// complete: every chunk received was cleaned. released: the recording ended before a
    /// received chunk started. The others end early work for the rest of the recording.
    public enum Stop: String, Codable, Sendable {
        case complete, released, emptyChunk, rawNoSentenceEnd, cleanedNoSentenceEnd, failed
    }
    /// unused: no chunk was cleaned. mismatch: cleaned chunks don't prefix the final transcript.
    public enum Reuse: String, Codable, Sendable { case unused, reused, mismatch }
    public var chunks = 0
    /// Chunks that ended at the window limit rather than at a pause.
    public var limitCuts = 0
    /// Chunks whose transcript ended mid-sentence, cleaned up to their last full stop.
    public var sentenceCuts = 0
    public var cleaned = 0
    public var stop = Stop.complete
    public var reuse = Reuse.unused
    public var reusedWords: Int?
    public var tailWords: Int?
    /// From the end of final ASR until early work settled.
    public var waitMS: Double?
    /// Why a chunk's cleanup failed, when early work stopped as failed in cleanup.
    public var cleanupFailure: CleanupFailure?
    public init() {}
}
struct EarlyWork: Sendable {
    var completed: [DictationText] = []
    var report = EarlyChunkReport()
    var refused: PipelineFailure?
}

public struct CapturedAudio: Sendable {
    public let pcm: PCM16k
    public let firstAudioUptime: Double?
    public let drainTimedOut: Bool

    public init(pcm: PCM16k, firstAudioUptime: Double? = nil, drainTimedOut: Bool = false) {
        self.pcm = pcm
        self.firstAudioUptime = firstAudioUptime
        self.drainTimedOut = drainTimedOut
    }
}

@MainActor public protocol CaptureDriver: AnyObject {
    func begin() throws -> EarlyChunks?
    func end(at boundary: Double?) async throws -> CapturedAudio
    func releaseBoundary() -> Double?
    func suspend()
    /// Why the last begin/end failed and how its audio path behaved; diagnostics only.
    var captureReport: CaptureReport? { get }
}
public extension CaptureDriver {
    func end() async throws -> CapturedAudio { try await end(at: nil) }
    func releaseBoundary() -> Double? { nil }
    var captureReport: CaptureReport? { nil }
}
@MainActor public protocol InsertionDriver: AnyObject {
    func snapshot(session: UUID) -> UUID
    func insert(_ text: String, target: UUID) async throws
}
@MainActor public protocol MediaDriver: AnyObject {
    func begin(_ session: UUID)
    func end(_ session: UUID)
}
public enum DictationState: String, Codable, Sendable { case idle, recording, processing, inserting, error }
@MainActor public final class DictationCoordinator {
    public private(set) var state: DictationState = .idle { didSet { onChange?() } }
    public private(set) var isCancelling = false
    public private(set) var recoveryText: String?
    public private(set) var message = "Preparing…"
    public var ready = false
    public var onChange: (() -> Void)?
    /// The Neural Engine and CPU clock down within about a second of idle, and batch ASR has
    /// nothing to do while the key is held. One small inference this often keeps them up until
    /// release (147 to 89 ms median on a synthetic 4 s hold); nil disables. Idle is unaffected.
    public var holdWarmupInterval: Duration? = .milliseconds(500)
    private var earlyDelivery: Task<EarlyWork, Never>?
    public var safetyDuration: Duration = .seconds(PCM16k.maximumDuration)
    public let timings: LatencyRecorder
    public var diagnostics: DiagnosticLogger?
    /// Saves completed batch dictations locally when enabled; never demo or cancelled output.
    public var history: DictationHistory?
    public var recordings: DebugRecordings?
    private let capture: any CaptureDriver
    private let insertion: any InsertionDriver
    private let media: any MediaDriver
    private let pipeline: BatchPipeline
    private var session: UUID?
    /// The insertion token created when this recording started; paste follows current focus.
    private var currentTarget: UUID?
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
        session = id; finalized = false; isCancelling = false; recoveryText = nil
        timings.mark(.press, session: id)
        let earlyChunks: EarlyChunks?
        do { earlyChunks = try capture.begin() }
        catch {
            diagnostics?.record(.init(.capture, session: id, capture: capture.captureReport))
            fail(AppError.capture); return
        }
        // After capture starts: the snapshot is synchronous AX IPC into the target app and can be slow.
        let target = insertion.snapshot(session: id)
        message = "Recording"; state = .recording
        media.begin(id)
        startHoldWarmup()
        if let chunks = earlyChunks {
            let pipeline = self.pipeline
            earlyDelivery = Task { [weak self] in
                var work = EarlyWork()
                guard let self else { return work }
                // Audio after the last full stop of the previous chunk, transcribed with the next.
                var carry: [Float] = []
                do {
                    for try await chunk in chunks {
                        work.report.chunks += 1
                        if chunk.samples.count >= EarlyChunkRule.limitSamples { work.report.limitCuts += 1 }
                        guard self.generation == owner, self.state == .recording else { work.report.stop = .released; break }
                        // Stop the periodic silence pass before using the same CoreML engine.
                        self.holdWarmup?.cancel()
                        await self.holdWarmup?.value
                        guard self.generation == owner, self.state == .recording else { work.report.stop = .released; break }
                        // Resume keep-warm after this chunk's ASR/cleanup settles. The next
                        // chunk cancels and awaits that pass before reusing the engine.
                        defer {
                            if self.generation == owner, self.state == .recording { self.startHoldWarmup() }
                        }
                        let audio = carry.isEmpty ? chunk : try PCM16k(carry + chunk.samples)
                        guard let heard = try await pipeline.recognize(audio) else { work.report.stop = .emptyChunk; break }
                        guard let sentence = BatchPipeline.sentencePrefix(of: heard, audio: audio) else {
                            work.report.stop = .rawNoSentenceEnd; break
                        }
                        if !sentence.rest.isEmpty { work.report.sentenceCuts += 1 }
                        carry = sentence.rest
                        let result = try await pipeline.finish(sentence.text)
                        guard result.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).endsSentence else {
                            work.report.stop = .cleanedNoSentenceEnd; break
                        }
                        work.completed.append(result); work.report.cleaned += 1
                    }
                } catch {
                    work.report.stop = .failed
                    if let failure = error as? PipelineFailure {
                        work.refused = failure; work.report.cleanupFailure = failure.cleanupFailure
                    }
                }
                return work
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
    public func release() {
        activationHeld = false
        guard let id = session, let target = currentTarget, state == .recording else { return }
        let boundary = capture.releaseBoundary()
        timings.mark(.release, session: id)
        finish(id, target: target, copyOnly: false, boundary: boundary)
    }
    private func handoffCapture(session id: UUID, owner: UInt64,
                                boundary: Double?) async -> PCM16k? {
        // Even cancellation must wait for capture handoff before ending its media lease.
        let captured: CapturedAudio
        do { captured = try await capture.end(at: boundary) }
        catch {
            diagnostics?.record(.init(.capture, session: id, capture: capture.captureReport))
            _ = await earlyDelivery?.value
            draining = false; media.end(id)
            if generation == owner { fail(AppError.capture) }
            return nil
        }
        draining = false
        timings.mark(.captureFinalized, session: id)
        if timings.isEnabled, let first = captured.firstAudioUptime {
            timings.mark(.firstAudio, session: id, uptime: first)
        }
        diagnostics?.record(.init(.capture, session: id,
            code: captured.drainTimedOut ? .drainTimeout : nil,
            sampleCount: captured.pcm.samples.count, capture: capture.captureReport))
        media.end(id)
        return captured.pcm
    }
    private func transcribeFinalAudio(_ audio: PCM16k, session id: UUID,
                                      owner: UInt64) async throws -> DictationText? {
        // CoreML can continue after cancellation. The final pass waits for hold warm-up.
        await holdWarmup?.value
        guard generation == owner, !Task.isCancelled else { throw CancellationError() }
        let recorder = timings
        var mark: StageMark?
        if recorder.isEnabled { mark = { stage in await recorder.mark(stage, session: id) } }
        let early = earlyDelivery
        // The structured child settles the early worker even when final ASR throws.
        async let prepared = early?.value
        let logger = diagnostics
        let report: CoverageReport = { coverage in logger?.record(.init(.coverage, session: id, coverage: coverage)) }
        guard let raw = try await pipeline.transcribe(audio, mark: mark, report: report) else { return nil }
        let measured = logger?.isEnabled == true
        let asrEnd = measured ? ProcessInfo.processInfo.systemUptime : 0
        let work = await prepared
        if measured, let work, work.report.chunks > 0 {
            logger?.record(.init(.earlyChunks, session: id, early: Self.earlyReport(work, final: raw,
                waitMS: (ProcessInfo.processInfo.systemUptime - asrEnd) * 1000)))
        }
        return try await pipeline.finish(raw, early: work?.completed ?? [], refused: work?.refused, mark: mark)
    }
    private static func earlyReport(_ work: EarlyWork, final raw: String, waitMS: Double) -> EarlyChunkReport {
        var report = work.report
        report.waitMS = waitMS
        guard !work.completed.isEmpty else { return report }
        if let reuse = BatchPipeline.reusablePrefix(in: raw, chunks: work.completed) {
            report.reuse = .reused
            report.reusedWords = work.completed.reduce(0) { $0 + WordTokens.words($1.raw).count }
            report.tailWords = WordTokens.words(reuse.tail).count
        } else { report.reuse = .mismatch }
        return report
    }
    private func finish(_ id: UUID, target: UUID, copyOnly: Bool, boundary: Double?) {
        guard session == id, !finalized else { return }
        holdWarmup?.cancel() // No new pass after release; final ASR awaits any pass in flight.
        finalized = true; draining = true; ceiling?.cancel(); ceiling = nil
        message = "Processing"; state = .processing
        let owner = generation
        task = Task { [weak self] in
            guard let self else { return }
            guard let audio = await self.handoffCapture(session: id, owner: owner,
                boundary: boundary) else { return }
            guard self.generation == owner, !Task.isCancelled else { return }
            // Keep released audio even after ASR/cleanup failure, but never cancelled or
            // superseded sessions. Enqueue only; encoding and writes run on a utility queue.
            defer {
                if self.generation == owner, !Task.isCancelled {
                    self.recordings?.record(audio, session: id)
                }
            }
            do {
                let dictation = try await self.transcribeFinalAudio(audio, session: id, owner: owner)
                guard self.generation == owner, !Task.isCancelled else { return }
                if let dictation { self.history?.record(dictation) }
                self.timings.mark(.resultReady, session: id)
                guard let text = dictation?.cleaned else { self.complete(); return }
                self.recoveryText = String(text.prefix(DictationHistory.maximumTextCharacters))
                if copyOnly { self.endSession(.copyOnly); return }
                self.insertionSession = id
                self.message = "Inserting"; self.state = .inserting
                try await self.insertion.insert(text, target: target)
                guard self.generation == owner, !Task.isCancelled else { return }
                self.timings.mark(.insertionDispatched, session: id)
                self.complete()
            } catch is CancellationError { if self.generation == owner { self.complete() } }
            catch let error as PipelineFailure {
                guard self.generation == owner else { return }
                self.recoveryText = error.rawText.map { String($0.prefix(DictationHistory.maximumTextCharacters)) }; self.fail(error)
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
        if let id = session, !finalized {
            finalized = true; draining = true
            // Serialize the end before allowing another recording to own the capture buffers.
            isCancelling = true
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
            isCancelling = true
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
        guard holdWarmup == nil, let interval = holdWarmupInterval,
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
            case .failed(let error): diagnostics?.record(.init(.failure, session: session, code: .failure(error),
                cleanupFailure: (error as? PipelineFailure)?.cleanupFailure))
            case .copyOnly: diagnostics?.record(.init(.completed, session: session, code: .copyOnly))
            }
        }
        earlyDelivery = nil
        session = nil; currentTarget = nil; draining = false; isCancelling = false
        switch result {
        case .completed:
            message = ready ? "Ready" : "Not ready"
            state = .idle
        case .failed(let error):
            message = ((error as? PipelineFailure)?.reason ?? (error as? AppError) ?? .inference).localizedDescription
            state = .error
        case .copyOnly:
            message = "Recording limit reached. Copy the result."
            state = .error
        }
    }
    private func fail(_ error: any Error) { endSession(.failed(error)) }
    private func complete() { endSession(.completed) }
}
