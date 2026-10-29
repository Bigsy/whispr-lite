import AppKit
import WhisprLiteCore

/// Prepares and runs dictation: builds the pipeline from saved settings, loads the speech
/// model and cleanup service, starts capture and the event tap, and recovers or suspends
/// them. It reports through AppStatus; the app delegate owns the menu, windows and
/// lifecycle notifications.
@MainActor final class DictationController {
    let appStatus: AppStatus
    let audio = AudioCapture()
    let insertion = TextInserter()
    let media = MediaBroker()
    private let indicator = RecordingIndicator()
    private(set) var store: SettingsStore?
    private(set) var diagnostics: DiagnosticLogger?
    private(set) var history: DictationHistory?
    private(set) var recordings: DebugRecordings?
    /// Synthetic acoustic benchmark runs never become history or saved recordings.
    var historyAllowed = true
    /// The menu icon follows the dictation state.
    var onStateChange: ((DictationState) -> Void)?
    private(set) var coordinator: DictationCoordinator?
    private(set) var tapReady = false
    private(set) var pipelineReady = false
    private var hotkey: GlobalHotkey?
    private var setupTask: Task<Void, Never>?
    private var localBackend: ParakeetCoreBackend?
    /// The last successfully prepared ASR backend, reused while its settings are unchanged.
    private var preparedASR: (backend: any ASRBackend, configuration: ASRConfiguration)?
    private var acceptingASRProgress = false
    private var loggedPreparation: BackendPreparation?
    private var captureRecovery: Task<Void, Never>?
    private var captureRecoveries: [ContinuousClock.Instant] = []
    /// Setup stopped at capture (the microphone was missing); recovery finishes it.
    private var awaitingMicrophone = false
    private var sessionAvailable = true
    /// Unlocked, but loginwindow was still frontmost; resume when another app activates.
    private var awaitingLoginWindow = false
    static let loginWindowID = "com.apple.loginwindow"
    private var recordingShortcut = false
    private var shortcutPreviousStatus: AppStatus.Snapshot?
    private var settingsEpoch = UUID()
    private var hotkeyEpoch = UUID()
    private var readinessState: SetupReadiness { appStatus.snapshot.readiness }

    init(status: AppStatus) {
        appStatus = status
        indicator.activitySource = { [weak self] in self?.audio.recordingActivity ?? 0 }
        indicator.onCancel = { [weak self] in self?.coordinator?.cancel() }
        indicator.onCopy = { [weak self] in self?.copyResult() }
    }
    /// Opens the diagnostic log and dictation history beside the loaded settings.
    func attach(_ store: SettingsStore) {
        self.store = store
        diagnostics = DiagnosticLogger(directory: store.directory.appendingPathComponent("Diagnostics", isDirectory: true))
        diagnostics?.setFailureObserver { [weak self] in
            Task { @MainActor [weak self] in self?.publishFailureFlags() }
        }
        diagnostics?.setEnabled(store.preferences.debugLogging)
        history = DictationHistory(directory: store.directory.appendingPathComponent("History", isDirectory: true))
        history?.setFailureObserver { [weak self] in
            Task { @MainActor [weak self] in self?.publishFailureFlags() }
        }
        recordings = DebugRecordings(directory: store.directory.appendingPathComponent("Recordings", isDirectory: true))
        recordings?.setObserver { [weak self] in
            Task { @MainActor [weak self] in self?.publishFailureFlags() }
        }
        recordings?.refreshStorage()
    }

    // MARK: Pipeline

    private enum PipelineSetupFailure: Error { case backend, cleanup }
    private struct PipelineParts {
        let backend: any ASRBackend
        let httpCleanup: HTTPCleanup?
        let coordinator: DictationCoordinator
    }
    private func makePipeline(store: SettingsStore, preferences: Preferences,
                              reused: (any ASRBackend)?, debug: Bool) throws -> PipelineParts {
        let backend: any ASRBackend
        do {
            backend = try reused ?? BackendFactory.make(mode: preferences.backend, endpoint: preferences.asrEndpoint,
                cacheRoot: preferences.asrModelDirectory.isEmpty ? nil
                    : URL(fileURLWithPath: preferences.asrModelDirectory, isDirectory: true),
                allowDownloads: preferences.allowASRDownloads, model: preferences.asrModel)
        } catch { throw PipelineSetupFailure.backend }
        let prompt: String
        let cleanup: any TextCleanup
        let httpCleanup: HTTPCleanup?
        do {
            prompt = try store.prompt()
            let dictionary = try store.dictionary()
            if preferences.backend == .demo {
                cleanup = DemoCleanup(); httpCleanup = nil
            } else {
                let http = HTTPCleanup(try .init(preferences: preferences, prompt: prompt, dictionary: dictionary))
                cleanup = http; httpCleanup = http
            }
        } catch { throw PipelineSetupFailure.cleanup }
        var pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
        pipeline.asrDeadline = .seconds(preferences.asrTimeoutSeconds)
        pipeline.cleanupDeadline = .seconds(preferences.cleanupTimeoutSeconds)
        let coordinator = DictationCoordinator(capture: audio, insertion: insertion, media: media, pipeline: pipeline)
        coordinator.diagnostics = debug ? diagnostics : nil
        history?.configure(enabled: preferences.saveDictationHistory && preferences.backend != .demo && historyAllowed,
            asr: preferences.backend == .parakeet ? "parakeet-\(preferences.asrModel.rawValue)" : preferences.backend.rawValue,
            prompt: prompt)
        coordinator.history = history
        coordinator.recordings = recordings
        let timings = coordinator.timings
        timings.setEnabled(debug)
        insertion.timings = debug ? timings : nil
        if debug {
            timings.onEvent = { [weak self] event in
                self?.diagnostics?.record(.init(.timing, session: event.session, stage: event.stage,
                    milliseconds: event.seconds * 1000))
            }
        }
        coordinator.safetyDuration = .seconds(PCM16k.maximumDuration - (preferences.warmCapture ? 0.2 : 0.05))
        coordinator.onChange = { [weak self] in self?.refresh() }
        return .init(backend: backend, httpCleanup: httpCleanup, coordinator: coordinator)
    }
    private func isCurrent(_ epoch: UUID) -> Bool {
        settingsEpoch == epoch && sessionAvailable && !Task.isCancelled
    }
    private func updateTapReadiness(_ ready: Bool) {
        tapReady = ready
        coordinator?.ready = ready && pipelineReady
        diagnostics?.record(.init(.readiness, code: ready ? .ready : .notReady))
        if ready {
            update("Ready to dictate", readiness: .ready)
        } else {
            update("Keyboard shortcut unavailable",
                   detail: "Check Accessibility access, then check readiness. If you just enabled it, quit and reopen Whispr Lite.",
                   readiness: .needsAttention)
        }
    }
    private func startHotkey(configuration: HotkeyConfiguration, epoch: UUID) {
        guard sessionAvailable, pipelineReady, !recordingShortcut, settingsEpoch == epoch else { return }
        hotkeyEpoch = UUID(); let tapEpoch = hotkeyEpoch
        hotkey?.stop()
        hotkey = GlobalHotkey(configuration: configuration, callback: { [weak self] action in
            // The event-tap thread emits in order; FIFO dispatch keeps press/release in that order.
            DispatchQueue.main.async {
                guard let self, self.settingsEpoch == epoch, self.hotkeyEpoch == tapEpoch,
                      !self.recordingShortcut else { return }
                self.diagnostics?.record(.init(.hotkey, code: action.diagnosticCode))
                switch action {
                case .press: self.coordinator?.press()
                case .release: self.coordinator?.release()
                case .cancel: self.coordinator?.cancel()
                }
            }
        }, readiness: { [weak self] ready in DispatchQueue.main.async {
            guard let self, self.settingsEpoch == epoch, self.hotkeyEpoch == tapEpoch,
                  !self.recordingShortcut else { return }
            self.updateTapReadiness(ready)
        } })
        hotkey?.start()
    }
    func tearDownPipeline(bumpEpoch: Bool, clearCoordinator: Bool = false,
                          settleClipboard: Bool = false) {
        // Invalidate queued tap callbacks before stopping the tap or cancelling preparation.
        if bumpEpoch { settingsEpoch = UUID() }
        hotkeyEpoch = UUID()
        captureRecovery?.cancel(); captureRecovery = nil
        setupTask?.cancel(); setupTask = nil
        hotkey?.stop(); hotkey = nil
        if let coordinator { coordinator.suspend() }
        else { audio.suspend() }
        if clearCoordinator { coordinator = nil }
        insertion.timings = nil
        pipelineReady = false; tapReady = false; awaitingMicrophone = false
        indicator.hide()
        if settleClipboard { insertion.clipboard.settle() }
        media.shutdown()
    }
    /// Quitting: records the shutdown, then stops dictation and returns the user's clipboard.
    func shutdown() {
        diagnostics?.record(.init(.shutdown))
        tearDownPipeline(bumpEpoch: true, settleClipboard: true)
    }

    // MARK: Preparation

    private enum PreparationStage: Equatable { case speech, cleanup, capture }
    private func prepareASR(_ backend: any ASRBackend, configuration: ASRConfiguration,
                            reused: Bool, previousSetup: Task<Void, Never>?,
                            previousCoordinator: DictationCoordinator?, preferences: Preferences,
                            epoch: UUID) async throws -> Bool {
        // Cancellation cannot preempt CoreML work. Settle both old owners before replacement.
        await previousSetup?.value
        await previousCoordinator?.settleBackendWork()
        guard isCurrent(epoch) else { return false }
        if !reused {
            preparedASR = nil
            try await localBackend?.unload()
            guard isCurrent(epoch) else { return false }
            localBackend = backend as? ParakeetCoreBackend
        }
        acceptingASRProgress = true; loggedPreparation = nil
        defer { acceptingASRProgress = false }
        try await withDeadline(.seconds(preferences.allowASRDownloads ? 900 : 120), stage: "Preparation") { [weak self] in
            try await backend.prepare { [weak self] stage, fraction in
                DispatchQueue.main.async {
                    guard let self, self.settingsEpoch == epoch,
                          self.readinessState == .preparing,
                          self.acceptingASRProgress else { return }
                    // Fractions arrive per percent; the log keeps one record per stage.
                    if self.diagnostics?.isEnabled == true, stage != self.loggedPreparation {
                        self.loggedPreparation = stage
                        var record = DiagnosticRecord(.preparationProgress)
                        record.preparation = stage
                        self.diagnostics?.record(record)
                    }
                    let text = stage.displayName + (fraction.map { " (\(Int($0 * 100))%)" } ?? "")
                    self.appStatus.setSpeech(stage == .ready ? .ready : .working(text, fraction: fraction))
                    self.update(text)
                }
            }
        }
        guard isCurrent(epoch) else { return false }
        preparedASR = (backend, configuration)
        appStatus.setSpeech(.ready)
        return true
    }
    private func waitForCleanupService(_ cleanup: HTTPCleanup, timeout: Double,
                                       retryStartup: Bool, epoch: UUID) async throws -> Bool {
        update("Checking cleanup service", readiness: .preparing)
        if retryStartup { appStatus.setCleanup(.working("Connecting to the cleanup service")) }
        // Retry a configured service that may still be loading. A fresh install keeps
        // its Install action visible and probes only once, allowing a manual server.
        for attempt in 1... {
            do {
                try await cleanup.checkReadiness()
                guard isCurrent(epoch) else { return false }
                break
            } catch {
                guard isCurrent(epoch) else { return false }
                guard retryStartup, attempt < 6, !(error is CancellationError) else { throw error }
                update("Waiting for cleanup service", readiness: .preparing)
                appStatus.setCleanup(.working("Waiting for the cleanup service to start"))
                try await Task.sleep(for: .seconds(attempt))
                guard isCurrent(epoch) else { return false }
            }
        }
        update("Preparing cleanup", readiness: .preparing)
        appStatus.setCleanup(.working("Preparing cleanup"))
        try await withDeadline(.seconds(timeout), stage: "Cleanup preparation") {
            try await cleanup.preparePrefix()
        }
        guard isCurrent(epoch) else { return false }
        appStatus.setCleanup(.ready)
        return true
    }
    /// Settings can install the cleanup service: Whispr Lite's login item is missing and the
    /// default address, which that service uses, is selected.
    private func cleanupInstallable(_ preferences: Preferences) -> Bool {
        !CleanupSetup.isInstalled() && preferences.cleanupEndpoint == Preferences().cleanupEndpoint
    }
    private func startCapture(preferences: Preferences, epoch: UUID,
                              preparationStart: ContinuousClock.Instant?) throws {
        let permissions = PermissionStatus.current
        if diagnostics?.isEnabled == true {
            var record = DiagnosticRecord(.permissions)
            record.accessibility = permissions.accessibility
            record.microphone = permissions.microphone
            record.inputMonitoring = permissions.inputMonitoring
            diagnostics?.record(record)
        }
        guard permissions.microphone else {
            update("Microphone permission needed",
                   detail: "Allow microphone access below, then check readiness.", readiness: .needsAttention)
            return
        }
        try audio.prepare(CaptureOptions(preferences))
        guard permissions.accessibility else {
            audio.suspend()
            update("Accessibility permission needed",
                   detail: "Enable Whispr Lite in Accessibility settings below, then check readiness.",
                   readiness: .needsAttention)
            return
        }
        pipelineReady = true
        diagnostics?.record(.init(.preparationReady,
            milliseconds: preparationStart.map { $0.duration(to: .now).milliseconds }))
        if preferences.pauseMedia, let resources = Bundle.main.resourceURL {
            media.start(script: resources.appendingPathComponent("broker.pl"),
                framework: Bundle.main.bundleURL.appendingPathComponent(
                    "Contents/Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"))
        }
        startHotkey(configuration: preferences.hotkey, epoch: epoch)
    }
    /// Builds the pipeline from the saved settings and prepares it, replacing any current one.
    func configure() {
        guard !recordingShortcut else { return }
        guard let store else { update("Settings file is invalid. Review preferences.json before preparing.", readiness: .needsAttention); return }
        guard sessionAvailable else { suspendSession(); return }
        // screenIsUnlocked can arrive before loginwindow gives up the front, with no later
        // unlock event to retry; wait for the next app activation instead.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Self.loginWindowID else {
            suspendSession(untilLoginWindowCloses: true); return
        }
        awaitingLoginWindow = false
        let previousSetup = setupTask
        let previousCoordinator = coordinator
        tearDownPipeline(bumpEpoch: true, clearCoordinator: true)
        captureRecoveries.removeAll()
        let epoch = settingsEpoch
        let preferences = store.preferences
        recordings?.setEnabled(preferences.saveDebugRecordings && preferences.backend != .demo && historyAllowed)
        diagnostics?.setEnabled(preferences.debugLogging)
        diagnostics?.record(.init(.configuration, configuration: .init(preferences)))
        let debug = diagnostics?.isEnabled == true
        insertion.diagnostics = debug ? diagnostics : nil; media.diagnostics = debug ? diagnostics : nil
        audio.showAudioActivity = preferences.showAudioActivity
        audio.debugTimings = debug
        // Saving unrelated settings, wake, unlock and readiness checks keep a loaded model.
        let asrConfiguration = ASRConfiguration(preferences)
        let reused = preparedASR.flatMap { $0.configuration == asrConfiguration ? $0.backend : nil }
        let parts: PipelineParts
        do {
            parts = try makePipeline(store: store, preferences: preferences, reused: reused, debug: debug)
        } catch PipelineSetupFailure.backend {
            update("Check the selected backend settings.", readiness: .needsAttention); return
        } catch {
            update("Check private prompt and local endpoint settings", readiness: .needsAttention); return
        }
        coordinator = parts.coordinator
        let backend = parts.backend
        appStatus.setSpeech(.waiting)
        appStatus.setCleanup(parts.httpCleanup == nil ? .hidden : cleanupInstallable(preferences) ? .notInstalled : .waiting)
        audio.onFailure = { [weak self] in self?.recoverCapture(epoch: epoch, preferences: preferences) }
        media.onChange = { [weak self] in
            guard let self else { return }
            self.appStatus.setMediaStatus(self.media.status)
        }
        setupTask = Task { [weak self] in
            guard let self else { return }
            self.update("Preparing speech recognition", readiness: .preparing)
            let preparationStart = debug ? ContinuousClock.now : nil
            self.diagnostics?.record(.init(.preparationStarted))
            var stage: PreparationStage = .speech
            do {
                guard try await self.prepareASR(backend, configuration: asrConfiguration,
                    reused: reused != nil, previousSetup: previousSetup,
                    previousCoordinator: previousCoordinator, preferences: preferences,
                    epoch: epoch) else { return }
                if let httpCleanup = parts.httpCleanup {
                    stage = .cleanup
                    guard try await self.waitForCleanupService(httpCleanup,
                        timeout: preferences.cleanupTimeoutSeconds,
                        retryStartup: !self.cleanupInstallable(preferences), epoch: epoch) else { return }
                }
                guard self.isCurrent(epoch) else { return }
                stage = .capture
                try self.startCapture(preferences: preferences, epoch: epoch, preparationStart: preparationStart)
            } catch is CancellationError {}
            catch {
                guard self.settingsEpoch == epoch else { return }
                if stage == .capture { self.awaitingMicrophone = true }
                self.reportPreparationFailure(error, stage: stage, preferences: preferences,
                                              started: preparationStart)
            }
        }
    }
    private func reportPreparationFailure(_ error: any Error, stage: PreparationStage, preferences: Preferences,
                                          started: ContinuousClock.Instant?) {
        let code: DiagnosticCode = stage == .cleanup ? .cleanup : .failure(error)
        diagnostics?.record(.init(.preparationFailed, code: code,
            milliseconds: started.map { $0.duration(to: .now).milliseconds }))
        if stage == .cleanup, cleanupInstallable(preferences) {
            appStatus.setCleanup(.notInstalled)
            update("Cleanup service not installed",
                detail: "Install it below to tidy dictation with a model on this Mac.", readiness: .needsAttention)
        } else if stage == .cleanup {
            appStatus.setCleanup(.unavailable(error.localizedDescription))
            update("Cleanup service unavailable",
                detail: "Start your cleanup service and check its address in Advanced. \(error.localizedDescription)",
                readiness: .needsAttention)
        } else if stage == .capture {
            reportMicrophoneUnavailable()
        } else if code == .missingCache {
            appStatus.setSpeech(.missing)
            update("Speech model not downloaded",
                detail: "Download it below. After that, speech recognition runs on this Mac.", readiness: .needsAttention)
        } else {
            appStatus.setSpeech(.failed(error.localizedDescription))
            update("Speech recognition unavailable", detail: error.localizedDescription, readiness: .needsAttention)
        }
    }
    private func reportMicrophoneUnavailable() {
        update("Microphone unavailable",
               detail: "Dictation resumes when it reconnects. Or choose another microphone in Settings.",
               readiness: .needsAttention)
    }
    /// Route changes (AirPods connecting, the default input switching) stop AVAudioEngine, and
    /// after a failed prepare capture reports microphones appearing. Rebuild only capture after
    /// the burst settles; the model, cleanup and event tap are unaffected.
    private func recoverCapture(epoch: UUID, preferences: Preferences) {
        guard settingsEpoch == epoch, pipelineReady || awaitingMicrophone else { return }
        coordinator?.suspend()
        captureRecovery?.cancel()
        update("Microphone changed. Reconnecting", readiness: .preparing)
        captureRecovery = Task { [weak self] in
            // A route change (AirPods connecting) posts several notifications; they coalesce here.
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.settingsEpoch == epoch else { return }
            // Count rebuilds, not notifications. A microphone that keeps dropping (a loose USB
            // cable) waits for the window to clear instead of staying off until a manual check.
            let now = ContinuousClock.now
            self.captureRecoveries = self.captureRecoveries.filter { $0.duration(to: now) < .seconds(30) }
            if self.captureRecoveries.count >= 3, let oldest = self.captureRecoveries.first {
                self.update("Microphone keeps changing", detail: "Trying again shortly.", readiness: .preparing)
                do { try await Task.sleep(until: oldest + .seconds(30), clock: .continuous) } catch { return }
                guard self.settingsEpoch == epoch else { return }
            }
            self.captureRecoveries.append(.now)
            self.diagnostics?.record(.init(.readiness, code: .recovering))
            let resumed = self.pipelineReady
            do {
                if resumed { try self.audio.prepare(CaptureOptions(preferences)) }
                // Setup stopped at capture: finish it, which also starts the event tap.
                else { try self.startCapture(preferences: preferences, epoch: epoch, preparationStart: nil) }
            } catch {
                // A failed prepare watches the device list and calls back here.
                self.diagnostics?.record(.init(.readiness, code: .unavailable))
                self.reportMicrophoneUnavailable(); return
            }
            // Clear a "not ready" notice from a press made while reconnecting.
            if self.coordinator?.state == .error { self.coordinator?.cancel() }
            if resumed { self.updateTapReadiness(self.tapReady) }
        }
    }
    /// The setup list's Download button: turns on model downloads, keeping the other saved
    /// settings, prompt and dictionary as they are, and prepares again.
    func downloadSpeechModel() {
        guard let store else { return }
        var preferences = store.preferences
        preferences.allowASRDownloads = true
        do { try store.save(preferences, instructions: nil, dictionary: nil) }
        catch { update("Could not save settings", detail: "Turn on model downloads in Advanced instead.", readiness: .needsAttention); return }
        configure()
    }

    // MARK: Status

    func update(_ text: String, detail: String? = nil, readiness: SetupReadiness? = nil) {
        let displayed = store?.preferences.backend == .demo ? DemoLabel.tagged(text) : text
        appStatus.update(displayed, detail: detail, readiness: readiness)
        publishFailureFlags()
    }
    func publishFailureFlags() {
        if let recordings { appStatus.setDebugRecordings(recordings.snapshot) }
        appStatus.setFailures(diagnostics: diagnostics?.hasFailed == true,
            history: history?.hasFailed == true)
    }
    private func refresh() {
        guard let coordinator, let store else { return }
        update(coordinator.message)
        onStateChange?(coordinator.state)
        diagnostics?.record(.init(.state, state: coordinator.state))
        indicator.update(state: coordinator.state, message: coordinator.message,
            demo: store.preferences.backend == .demo, canCopy: coordinator.recoveryText != nil,
            isCancelling: coordinator.isCancelling,
            showActivity: store.preferences.showAudioActivity)
    }

    // MARK: Session

    func suspendSession(untilLoginWindowCloses: Bool = false) {
        diagnostics?.record(.init(.suspended, code: untilLoginWindowCloses ? .paused : nil))
        sessionAvailable = untilLoginWindowCloses
        awaitingLoginWindow = untilLoginWindowCloses
        tearDownPipeline(bumpEpoch: true)
        update("Dictation paused", detail: "Unlock your Mac or return to this session, then check readiness.", readiness: .needsAttention)
    }
    func resumeSession() { sessionAvailable = true; configure() }
    /// Resumes a session that unlocked while loginwindow was still frontmost.
    func applicationActivated(_ bundleIdentifier: String?) {
        guard awaitingLoginWindow, sessionAvailable, bundleIdentifier != Self.loginWindowID else { return }
        configure()
    }
    func beginShortcutRecording() {
        guard !recordingShortcut else { return }
        shortcutPreviousStatus = appStatus.snapshot
        recordingShortcut = true
        hotkeyEpoch = UUID()
        hotkey?.stop(); hotkey = nil
        tapReady = false; coordinator?.ready = false
        coordinator?.cancel()
        update("Choosing a shortcut", detail: "Dictation is paused while you record the shortcut.", readiness: .needsAttention)
    }
    func endShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false
        let previous = shortcutPreviousStatus; shortcutPreviousStatus = nil
        guard sessionAvailable else { return }
        if pipelineReady, let store {
            startHotkey(configuration: store.preferences.hotkey, epoch: settingsEpoch)
        } else if appStatus.snapshot.text.contains("Choosing a shortcut"), let previous {
            appStatus.update(previous.text, detail: previous.detail, readiness: previous.readiness)
        }
    }

    // MARK: Results and history

    var canCopyResult: Bool { coordinator?.recoveryText != nil }
    func copyResult() {
        guard let text = coordinator?.recoveryText else { return }
        insertion.clipboard.settle()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func deleteDictationHistory() async -> Bool {
        guard let history else { return false }
        do {
            try await history.deleteAll()
            publishFailureFlags()
            return true
        } catch {
            publishFailureFlags()
            return false
        }
    }
    func deleteDebugRecordings() async -> Bool {
        guard let recordings else { return false }
        do {
            try await recordings.deleteAll()
            return true
        } catch { return false }
    }
}
/// Settings that select and load the ASR model; anything else can change without a reload.
private struct ASRConfiguration: Equatable {
    let backend: BackendMode, endpoint: String, cacheDirectory: String, allowDownloads: Bool, model: ParakeetModel
    init(_ preferences: Preferences) {
        backend = preferences.backend; endpoint = preferences.asrEndpoint; cacheDirectory = preferences.asrModelDirectory
        allowDownloads = preferences.allowASRDownloads; model = preferences.asrModel
    }
}
