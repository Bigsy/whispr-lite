import AppKit
import SwiftUI
import AVFoundation
import WhisprLiteCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, ObservableObject {
    @Published var status = "Starting"
    @Published var statusDetail = ""
    @Published var readinessState: SetupReadiness = .preparing
    @Published var mediaStatus = "Media disabled"
    private var item: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var copyMenuItem: NSMenuItem?
    /// Internal so the UI preview command can check window fitting on a real titled window.
    var settingsWindow: NSWindow?
    private var benchmarkWindow: NSWindow?
    private var benchmarkField: MeasuredTextView?
    private var benchmarkVisible: ((Double) -> Void)?
    private var store: SettingsStore!
    private var diagnostics: DiagnosticLogger?
    private var history: DictationHistory?
    /// Synthetic acoustic benchmark runs never become dictation history.
    private var historyAllowed = true
    private let audio = AudioCapture()
    private let insertion = TextInserter()
    private let media = MediaBroker()
    private let indicator = RecordingIndicator()
    private var coordinator: DictationCoordinator?
    private var hotkey: GlobalHotkey?
    private var setupTask: Task<Void, Never>?
    private var localBackend: ParakeetCoreBackend?
    /// The last successfully prepared ASR backend, reused while its settings are unchanged.
    private var preparedASR: (backend: any ASRBackend, configuration: ASRConfiguration)?
    private var captureRecovery: Task<Void, Never>?
    private var captureRecoveries: [ContinuousClock.Instant] = []
    private var tapReady = false
    private var pipelineReady = false
    private var sessionAvailable = true
    private var recordingShortcut = false
    private var observers: [NSObjectProtocol] = []
    private var settingsEpoch = UUID()
    private static let shutdownGrace: Duration = .milliseconds(700)
    private var shutdownStarted = false
    private var terminationReply: Task<Void, Never>?
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
            update("Input Monitoring permission needed",
                   detail: "Enable Whispr Lite in Input Monitoring settings below, then check readiness.",
                   readiness: .needsAttention)
        }
    }
    private func tearDownPipeline(bumpEpoch: Bool, clearCoordinator: Bool = false,
                                  settleClipboard: Bool = false) {
        // Invalidate queued tap callbacks before stopping the tap or cancelling preparation.
        if bumpEpoch { settingsEpoch = UUID() }
        captureRecovery?.cancel(); captureRecovery = nil
        setupTask?.cancel(); setupTask = nil
        hotkey?.stop(); hotkey = nil
        if let coordinator { coordinator.suspend() }
        else { audio.suspend() }
        if clearCoordinator { coordinator = nil }
        pipelineReady = false; tapReady = false
        indicator.hide()
        if settleClipboard { insertion.clipboard.settle() }
        media.shutdown()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let command: LaunchCommand
        do { command = try LaunchCommand.parse(Array(CommandLine.arguments.dropFirst())) }
        catch {
            fputs("Launch arguments: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        NSApp.setActivationPolicy(.accessory)
        if DevelopmentCommands.run(command, app: self) { return }
        do { store = try SettingsStore() }
        catch {
            if case .run = command {
                status = "Settings could not be loaded"
                readinessState = .needsAttention
                createMenu()
                return
            }
            fputs("Probe settings could not be loaded\n", stderr)
            exit(1)
        }
        createMenu()
        diagnostics = DiagnosticLogger(directory: store.directory.appendingPathComponent("Diagnostics", isDirectory: true))
        diagnostics?.setEnabled(store.preferences.debugLogging)
        history = DictationHistory(directory: store.directory.appendingPathComponent("History", isDirectory: true))
        indicator.activitySource = { [weak self] in self?.audio.recordingActivity ?? 0 }
        observeLifecycle()
        if case .run(let options) = command, options.showBenchmarkWindow { showBenchmark() }
        if case .captureFlow = command { historyAllowed = false; showBenchmark() }
        configure()
        if case .run(let options) = command, options.showSettings { showSettings() }
        if case .captureFlow(let arguments) = command {
            Task {
                do {
                    try await runCaptureFlowCheck(arguments: arguments)
                    exit(0)
                } catch {
                    if let failure = error as? CheckFailure {
                        print("capture-flow check failed: \(failure.message)")
                    } else { print("capture-flow check failed: \(type(of: error))") }
                    exit(1)
                }
            }
        }
        if case .readinessReport(let output) = command { writeReadinessReport(to: output) }
    }
    private func writeReadinessReport(to output: URL) {
        // Explicit, finite integration probe; normal operation has no readiness polling.
        Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while readinessState == .preparing && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let mediaDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            while media.readiness == .starting && ContinuousClock.now < mediaDeadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let ready = readinessState == .ready && pipelineReady && tapReady
            let permissions = PermissionStatus.current
            let report: [String: Any] = ["schema": 1, "ready": ready, "status": status,
                "asr_model": store.preferences.asrModel.rawValue,
                "microphone_authorized": permissions.microphone,
                "accessibility_authorized": permissions.accessibility,
                "input_monitoring_authorized": permissions.inputMonitoring,
                "event_tap_ready": tapReady, "pipeline_ready": pipelineReady,
                "warm_capture": store.preferences.warmCapture, "media_status": media.status,
                "physical_hotkey_or_dictation_tested": false, "private_content_recorded": false]
            var success = ready
            do {
                try JSONReport.write(report, to: output)
                print("readiness-check ready=\(ready) event-tap=\(tapReady)")
            } catch { success = false; print("readiness report could not be written") }
            tearDownPipeline(bumpEpoch: true, settleClipboard: true)
            try? await Task.sleep(for: .milliseconds(700))
            exit(success ? 0 : 1)
        }
    }
    private func createMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setMenuAppearance(.idle)
        let menu = NSMenu()
        let statusEntry = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusEntry.isEnabled = false
        statusMenuItem = statusEntry
        menu.addItem(statusEntry)
        let copyEntry = NSMenuItem(title: "Copy last result", action: #selector(copyResult), keyEquivalent: "")
        copyEntry.target = self
        copyMenuItem = copyEntry
        menu.addItem(copyEntry)
        for (title, action) in [("Settings…", #selector(showSettings)), ("Check readiness", #selector(retry)),
                                ("Microphone permission", #selector(requestMicrophone)),
                                ("Accessibility permission", #selector(requestAccessibility)),
                                ("Input Monitoring settings", #selector(inputMonitoring)),
                                ("Quit", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item.menu = menu
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === copyMenuItem { return coordinator?.recoveryText != nil }
        return true
    }
    private func configure() {
        guard !recordingShortcut else { return }
        guard let store else { update("Settings file is invalid. Review preferences.json before preparing.", readiness: .needsAttention); return }
        guard sessionAvailable, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else {
            suspendSession(); return
        }
        let previousSetup = setupTask
        let previousCoordinator = coordinator
        tearDownPipeline(bumpEpoch: true, clearCoordinator: true)
        let epoch = settingsEpoch
        let preferences = store.preferences
        diagnostics?.setEnabled(preferences.debugLogging)
        diagnostics?.record(.init(.configuration, configuration: .init(preferences)))
        let debug = diagnostics?.isEnabled == true
        insertion.diagnostics = debug ? diagnostics : nil; media.diagnostics = debug ? diagnostics : nil
        audio.showAudioActivity = preferences.showAudioActivity
        audio.debugTimings = debug
        // Saving unrelated settings, wake, unlock and readiness checks keep a loaded model.
        let asrConfiguration = ASRConfiguration(preferences)
        let reused = preparedASR.flatMap { $0.configuration == asrConfiguration ? $0.backend : nil }
        let backend: any ASRBackend
        do { backend = try reused ?? BackendFactory.make(mode: preferences.backend, endpoint: preferences.asrEndpoint,
            cacheRoot: preferences.asrModelDirectory.isEmpty ? nil : URL(fileURLWithPath: preferences.asrModelDirectory, isDirectory: true),
            allowDownloads: preferences.allowASRDownloads, model: preferences.asrModel) }
        catch { update("Check the selected backend settings.", readiness: .needsAttention); return }
        let cleanup: any TextCleanup
        do {
            let prompt = try store.prompt()
            let dictionary = try store.dictionary()
            cleanup = preferences.backend == .demo ? DemoCleanup() : HTTPCleanup(try .init(preferences: preferences, prompt: prompt, dictionary: dictionary))
            var pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
            pipeline.asrDeadline = .seconds(preferences.asrTimeoutSeconds)
            pipeline.cleanupDeadline = .seconds(preferences.cleanupTimeoutSeconds)
            coordinator = DictationCoordinator(capture: audio, insertion: insertion, media: media, pipeline: pipeline)
            coordinator?.diagnostics = debug ? diagnostics : nil
            history?.configure(enabled: preferences.saveDictationHistory && preferences.backend != .demo && historyAllowed,
                asr: preferences.backend == .parakeet ? "parakeet-\(preferences.asrModel.rawValue)" : preferences.backend.rawValue,
                prompt: prompt)
            coordinator?.history = history
            if let timings = coordinator?.timings {
                timings.setEnabled(debug)
                insertion.timings = debug ? timings : nil
                if debug {
                    timings.onEvent = { [weak self] event in
                        self?.diagnostics?.record(.init(.timing, session: event.session, stage: event.stage, milliseconds: event.seconds * 1000))
                    }
                }
            }
            coordinator?.streamingEnabled = preferences.usesStreamingDemo
            coordinator?.safetyDuration = .seconds(PCM16k.maximumDuration - (preferences.warmCapture ? 0.2 : 0.05))
        } catch { update("Check private prompt and local endpoint settings", readiness: .needsAttention); return }
        coordinator?.onChange = { [weak self] in self?.refresh() }
        audio.onFailure = { [weak self] in self?.recoverCapture(epoch: epoch, preferences: preferences) }
        media.onChange = { [weak self] in self?.mediaStatus = self?.media.status ?? "" }
        setupTask = Task { [weak self] in
            guard let self else { return }
            self.update("Preparing speech recognition", readiness: .preparing)
            let preparationStart = debug ? ContinuousClock.now : nil
            self.diagnostics?.record(.init(.preparationStarted))
            var checkingCleanup = false
            do {
                // Serialise replacements. Cancellation cannot preempt CoreML work;
                // a busy old engine rejects unloading, so no new model is loaded yet.
                await previousSetup?.value
                await previousCoordinator?.settleBackendWork()
                guard self.isCurrent(epoch) else { return }
                if reused == nil {
                    self.preparedASR = nil
                    try await self.localBackend?.unload()
                    guard self.isCurrent(epoch) else { return }
                    self.localBackend = backend as? ParakeetCoreBackend
                }
                // A ready engine returns at once; HTTP still rechecks health.
                try await withDeadline(.seconds(preferences.allowASRDownloads ? 900 : 120), stage: "Preparation") {
                    try await backend.prepare { [weak self] stage in
                        DispatchQueue.main.async {
                            guard let self, self.settingsEpoch == epoch, self.readinessState == .preparing else { return }
                            if self.diagnostics?.isEnabled == true {
                                var record = DiagnosticRecord(.preparationProgress); record.preparation = stage
                                self.diagnostics?.record(record)
                            }
                            self.update(stage.displayName)
                        }
                    }
                }
                self.preparedASR = (backend, asrConfiguration)
                if preferences.backend != .demo {
                    checkingCleanup = true
                    self.update("Checking cleanup service", readiness: .preparing)
                    guard let httpCleanup = cleanup as? HTTPCleanup else { throw AppError.unsupported }
                    // The service may still be loading (login, restart); wait about 15 s before asking the user.
                    for attempt in 1... {
                        do { try await httpCleanup.checkReadiness(); break }
                        catch {
                            guard attempt < 6, !(error is CancellationError) else { throw error }
                            self.update("Waiting for cleanup service", readiness: .preparing)
                            try await Task.sleep(for: .seconds(attempt))
                            guard self.isCurrent(epoch) else { return }
                        }
                    }
                    guard self.isCurrent(epoch) else { return }
                    self.update("Preparing cleanup", readiness: .preparing)
                    try await withDeadline(.seconds(preferences.cleanupTimeoutSeconds), stage: "Cleanup preparation") {
                        try await httpCleanup.preparePrefix()
                    }
                }
                guard self.isCurrent(epoch) else { return }
                let permissions = PermissionStatus.current
                if self.diagnostics?.isEnabled == true {
                    var permissionRecord = DiagnosticRecord(.permissions)
                    permissionRecord.accessibility = permissions.accessibility
                    permissionRecord.microphone = permissions.microphone
                    permissionRecord.inputMonitoring = permissions.inputMonitoring
                    self.diagnostics?.record(permissionRecord)
                }
                guard permissions.microphone else {
                    self.update("Microphone permission needed", detail: "Allow microphone access below, then check readiness.", readiness: .needsAttention); return
                }
                try self.audio.prepare(CaptureOptions(preferences))
                guard permissions.accessibility else {
                    self.audio.suspend(); self.update("Accessibility permission needed", detail: "Enable Whispr Lite in Accessibility settings below, then check readiness.", readiness: .needsAttention); return
                }
                self.pipelineReady = true
                self.diagnostics?.record(.init(.preparationReady, milliseconds: preparationStart.map { Self.milliseconds($0.duration(to: .now)) }))
                self.hotkey = GlobalHotkey(configuration: preferences.hotkey, callback: { [weak self] action in
                    // The event-tap thread emits in order; FIFO dispatch keeps press/release in that order.
                    DispatchQueue.main.async {
                        guard let self, self.settingsEpoch == epoch else { return }
                        let code: DiagnosticCode = switch action {
                        case .press: .press
                        case .release: .release
                        case .cancel: .cancel
                        }
                        self.diagnostics?.record(.init(.hotkey, code: code))
                        switch action {
                        case .press: self.coordinator?.press()
                        case .release: self.coordinator?.release()
                        case .cancel: self.coordinator?.cancel()
                        }
                    }
                }, readiness: { [weak self] ready in DispatchQueue.main.async {
                    guard let self, self.settingsEpoch == epoch else { return }
                    self.updateTapReadiness(ready)
                } })
                if preferences.pauseMedia,
                   let resources = Bundle.main.resourceURL {
                    self.media.start(script: resources.appendingPathComponent("broker.pl"),
                        framework: Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"))
                }
                self.hotkey?.start()
            } catch is CancellationError {}
            catch {
                if self.settingsEpoch == epoch {
                    self.diagnostics?.record(.init(.preparationFailed, code: checkingCleanup ? .cleanup : .failure(error),
                        milliseconds: preparationStart.map { Self.milliseconds($0.duration(to: .now)) }))
                    self.update(checkingCleanup ? "Cleanup service unavailable" : "Speech recognition unavailable",
                        detail: checkingCleanup ? "Start your cleanup service and check its address in Advanced. \(error.localizedDescription)" : error.localizedDescription,
                        readiness: .needsAttention)
                }
            }
        }
    }
    /// Route changes (AirPods connecting, the default input switching) stop AVAudioEngine.
    /// Rebuild only capture after the burst settles; the model, cleanup and event tap are unaffected.
    private func recoverCapture(epoch: UUID, preferences: Preferences) {
        guard settingsEpoch == epoch, pipelineReady else { return }
        coordinator?.suspend()
        captureRecovery?.cancel()
        update("Microphone changed. Reconnecting", readiness: .preparing)
        captureRecovery = Task { [weak self] in
            // A route change (AirPods connecting) posts several notifications; they coalesce here.
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.settingsEpoch == epoch, self.pipelineReady else { return }
            // Count rebuilds, not notifications, so only a rebuild that keeps failing gives up.
            let now = ContinuousClock.now
            self.captureRecoveries = self.captureRecoveries.filter { $0.duration(to: now) < .seconds(30) } + [now]
            guard self.captureRecoveries.count <= 3 else {
                self.update("Microphone keeps changing", detail: "Check the microphone, then check readiness.", readiness: .needsAttention); return
            }
            do {
                try self.audio.prepare(CaptureOptions(preferences))
            } catch {
                self.update("Microphone unavailable", detail: "Reconnect or choose a microphone in Advanced, then check readiness.", readiness: .needsAttention)
                return
            }
            // Clear a "not ready" notice from a press made while reconnecting.
            if self.coordinator?.state == .error { self.coordinator?.cancel() }
            self.updateTapReadiness(self.tapReady)
        }
    }
    private func update(_ text: String, detail: String = "", readiness: SetupReadiness? = nil) {
        status = store?.preferences.backend == .demo ? DemoLabel.tagged(text) : text
        statusDetail = detail
        if let readiness { readinessState = readiness }
        statusMenuItem?.title = status
        item?.button?.toolTip = "Whispr Lite: \(status)"
    }
    private func refresh() {
        guard let coordinator else { return }
        update(coordinator.message)
        setMenuAppearance(coordinator.state)
        diagnostics?.record(.init(.state, state: coordinator.state))
        indicator.update(state: coordinator.state, message: coordinator.message,
            demo: store.preferences.backend == .demo, canCopy: coordinator.recoveryText != nil,
            showActivity: store.preferences.showAudioActivity,
            cancel: { [weak self] in self?.coordinator?.cancel() }, copy: { [weak self] in self?.copyResult() })
    }
    private func setMenuAppearance(_ state: DictationState) {
        let symbol = switch state {
        case .recording: "mic.fill"
        case .processing, .inserting: "ellipsis"
        case .error: "exclamationmark.circle"
        case .idle: "mic"
        }
        item?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whispr Lite")
        item?.button?.title = store?.preferences.backend == .demo ? " \(DemoLabel.name)" : ""
    }
    private func observeLifecycle() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendSession() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeSession() }
            })
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(retry), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    private func suspendSession() {
        diagnostics?.record(.init(.suspended))
        sessionAvailable = false
        tearDownPipeline(bumpEpoch: true)
        update("Dictation paused", detail: "Unlock your Mac or return to this session, then check readiness.", readiness: .needsAttention)
    }
    private func resumeSession() { sessionAvailable = true; configure() }
    func beginShortcutRecording() {
        guard !recordingShortcut else { return }
        recordingShortcut = true
        tearDownPipeline(bumpEpoch: true)
        update("Choosing a shortcut", detail: "Dictation is paused while you record the shortcut.", readiness: .needsAttention)
    }
    func endShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false; resumeSession()
    }
    @objc private func locked() { suspendSession() }
    @objc func retry() { resumeSession() }
    private func reveal(_ directory: URL) {
        let destination = FileManager.default.fileExists(atPath: directory.path)
            ? directory : directory.deletingLastPathComponent()
        NSWorkspace.shared.open(destination)
    }
    func showDiagnosticLogs() {
        guard let diagnostics else { return }
        reveal(diagnostics.directory)
    }
    var diagnosticLogFailed: Bool { diagnostics?.hasFailed == true }
    func showDictationHistory() {
        guard let history else { return }
        reveal(history.directory)
    }
    func deleteDictationHistory() async -> Bool {
        guard let history else { return false }
        do { try await history.deleteAll(); return true } catch { return false }
    }
    var dictationHistoryFailed: Bool { history?.hasFailed == true }
    private static func milliseconds(_ duration: Duration) -> Double { duration.milliseconds }
    @objc private func copyResult() {
        guard let text = coordinator?.recoveryText else { return }
        insertion.clipboard.settle()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc func requestMicrophone() {
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            if allowed { configure() }
            else { openSystemSettings(privacyAnchor: "Privacy_Microphone") }
        }
    }
    @objc func requestAccessibility() {
        if !PermissionStatus.current.accessibility {
            openSystemSettings(privacyAnchor: "Privacy_Accessibility")
        } else { configure() }
    }
    @objc func inputMonitoring() { openSystemSettings(privacyAnchor: "Privacy_ListenEvent") }
    private func openSystemSettings(privacyAnchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func showSettings() {
        guard let store else { return }
        if settingsWindow?.isVisible != true {
            let view = SettingsView(store: store, app: self) { [weak self] in self?.configure() }
            let host = NSHostingView(rootView: view)
            if let window = settingsWindow {
                host.sizingOptions = []
                window.contentView = host
            } else {
                let window = Self.makeSettingsWindow(host)
                settingsWindow = window
                window.center()
            }
            settingsWindow?.contentView?.layoutSubtreeIfNeeded()
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    /// Not user-resizable: the height follows the selected page via fitSettings(height:).
    static func makeSettingsWindow<Content: View>(_ host: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        host.sizingOptions = []
        window.title = "Whispr Lite Settings"; window.contentView = host
        window.isReleasedWhenClosed = false
        return window
    }
    /// The settings page's natural height, kept for the UI preview command.
    var preferredSettingsHeight: CGFloat = 0
    /// Sizes the settings window to the page with its top edge fixed. A page taller than the
    /// screen is capped and scrolls instead.
    func fitSettings(height: CGFloat) {
        preferredSettingsHeight = height.rounded(.up)
        guard let window = settingsWindow else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let titlebar = window.frame.height - content.height
        let target = min(preferredSettingsHeight, visible.map { $0.height - titlebar } ?? preferredSettingsHeight)
        guard abs(target - content.height) >= 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - target, width: content.width, height: target))
        if let visible, frame.minY < visible.minY { frame.origin.y = visible.minY }
        // Animate page switches; small changes while dragging an editor follow the pointer directly.
        window.setFrame(frame, display: true, animate: window.isVisible && abs(target - content.height) > 60)
    }
    @objc private func showBenchmark() {
        if benchmarkWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Whispr Lite: visible text benchmark"
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 180))
            let field = MeasuredTextView(frame: NSRect(x: 20, y: 45, width: 510, height: 110))
            field.font = .systemFont(ofSize: 16)
            field.onUpdate = { [weak self] in
                if let ms = self?.coordinator?.recordVisibleText() {
                    print("release-to-visible-text ms=\(ms)")
                    self?.benchmarkVisible?(ms)
                }
            }
            let label = NSTextField(labelWithString: "The console records content-free monotonic text-update times.")
            label.frame = NSRect(x: 20, y: 10, width: 510, height: 25)
            view.addSubview(field); view.addSubview(label)
            window.contentView = view; window.isReleasedWhenClosed = false; window.center()
            benchmarkField = field; benchmarkWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); benchmarkWindow?.makeKeyAndOrderFront(nil)
    }
    /// Opt-in acoustic loop: synthetic speaker playback, real microphone, normal pipeline
    /// and native paste. Press/release are called here, so the event tap is outside timing.
    private func runCaptureFlowCheck(arguments: [String]) async throws {
        guard arguments.count == 6, let repetitions = Int(arguments[5]), 1...31 ~= repetitions,
              let field = benchmarkField, let window = benchmarkWindow else {
            throw CheckFailure("Invalid capture-flow arguments or benchmark window")
        }
        let fixture = URL(fileURLWithPath: arguments[0])
        let player = URL(fileURLWithPath: arguments[1])
        let expectedWords = arguments[3].lowercased().split(separator: " ")
        guard !expectedWords.isEmpty else { throw CheckFailure("Capture-flow expected words are empty") }
        let output = URL(fileURLWithPath: arguments[4])
        let device = arguments[2]
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while readinessState == .preparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard readinessState == .ready, let coordinator else { throw CheckFailure("Dictation pipeline is not ready") }
        coordinator.timings.setEnabled(true)
        insertion.timings = coordinator.timings
        audio.debugTimings = true
        var observations: [[String: Any]] = []
        var captureStartFailures = 0
        for repetition in 0..<repetitions {
            field.string = ""; field.setSelectedRange(NSRange(location: 0, length: 0))
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            for _ in 0..<100 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                   window.isKeyWindow, window.firstResponder === field { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  window.isKeyWindow, window.firstResponder === field else {
                print("capture-flow focus frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier) key=\(window.isKeyWindow) responder=\(window.firstResponder === field)")
                throw CheckFailure("Benchmark field lost focus before capture")
            }
            var visibleMS: Double?
            benchmarkVisible = { visibleMS = $0 }
            for _ in 0..<3 {
                coordinator.press()
                if coordinator.state == .recording { break }
                captureStartFailures += 1
                coordinator.release()
                try await Task.sleep(for: .milliseconds(250))
            }
            guard coordinator.state == .recording else { throw CheckFailure("Recording did not start") }
            try await Task.sleep(for: .milliseconds(250))
            let playback = Process()
            playback.executableURL = player
            playback.arguments = ["-q", fixture.path, "-t", "coreaudio", device, "gain", "-n", "-6"]
            playback.standardOutput = FileHandle.nullDevice
            playback.standardError = FileHandle.nullDevice
            let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                playback.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do { try playback.run() }
                catch { playback.terminationHandler = nil; continuation.resume(throwing: error) }
            }
            guard status == 0 else { throw CheckFailure("Synthetic playback failed") }
            try await Task.sleep(for: .milliseconds(150))
            coordinator.release()
            let visibleDeadline = ContinuousClock.now.advanced(by: .seconds(12))
            while visibleMS == nil && ContinuousClock.now < visibleDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let visibleMS, !field.string.isEmpty else { throw CheckFailure("No native text update was observed") }
            let timings = coordinator.timings
            guard let session = timings.events.last(where: { $0.stage == .visibleText })?.session else {
                throw CheckFailure("Visible-text timing event is missing")
            }
            func span(_ start: TimingStage, _ end: TimingStage) throws -> Double {
                guard let value = timings.span(from: start, to: end, session: session) else {
                    throw CheckFailure("Capture-flow timing span is missing")
                }
                return value
            }
            observations.append(["repetition": repetition, "condition": repetition == 0 ? "first" : "warm",
                "release_to_visible_ms": visibleMS,
                "release_to_capture_finalized_ms": try span(.release, .captureFinalized),
                "asr_ms": try span(.asrStart, .asrEnd),
                "cleanup_ms": try span(.cleanupStart, .cleanupEnd),
                "result_to_visible_ms": try span(.resultReady, .visibleText),
                "release_to_insertion_dispatch_ms": try span(.release, .insertionDispatched),
                "phrase_detected": expectedWords.allSatisfy { field.string.lowercased().contains($0) }])
            print("capture-flow observation=\(repetition + 1)/\(repetitions)")
            benchmarkVisible = nil
            try await Task.sleep(for: .milliseconds(200))
        }
        let report: [String: Any] = ["schema": 1, "mode": "signed-acoustic-capture-to-native-text",
            "observations": observations, "capture_start_failures": captureStartFailures,
            "microphone_capture_measured": true,
            "native_text_update_measured": true, "physical_hotkey_measured": false,
            "display_compositor_latency_measured": false, "private_content_recorded": false]
        try JSONReport.write(report, to: output)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownStarted else { return .terminateLater }
        beginShutdown()
        terminationReply = Task {
            try? await Task.sleep(for: Self.shutdownGrace)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func beginShutdown() {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        diagnostics?.record(.init(.shutdown))
        tearDownPipeline(bumpEpoch: true, settleClipboard: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        // A forceful path can skip the termination query; normal quit already settled once.
        beginShutdown()
        terminationReply?.cancel(); terminationReply = nil
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
@MainActor final class MeasuredTextView: NSTextView {
    var onUpdate: (() -> Void)?
    private let origin = ContinuousClock.now
    override func didChangeText() {
        super.didChangeText(); onUpdate?()
        let elapsed = origin.duration(to: .now).components
        print("visible-text seconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)")
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
