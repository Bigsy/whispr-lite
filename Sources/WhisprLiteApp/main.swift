import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import WhisprLiteCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var status = "Starting"
    @Published var statusDetail = ""
    @Published var readinessState: SetupReadiness = .preparing
    @Published var mediaStatus = "Media disabled"
    private var item: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var benchmarkWindow: NSWindow?
    private var benchmarkField: MeasuredTextView?
    private var benchmarkVisible: ((Double) -> Void)?
    private var store: SettingsStore!
    private var diagnostics: DiagnosticLogger?
    private let audio = AudioCapture()
    private let insertion = TextInserter()
    private let media = MediaBroker()
    private let indicator = RecordingIndicator()
    private var coordinator: DictationCoordinator?
    private var hotkey: GlobalHotkey?
    private var setupTask: Task<Void, Never>?
    private var localBackend: ParakeetCoreBackend?
    private var tapReady = false
    private var pipelineReady = false
    private var sessionAvailable = true
    private var recordingShortcut = false
    private var observers: [NSObjectProtocol] = []
    private var settingsEpoch = UUID()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--ui-preview"), CommandLine.arguments.count > index + 1 {
            do { try NativeUIPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true), app: self); exit(0) }
            catch { print("Native UI preview failed: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            let bundle = Bundle.main
            let resourcesValid = !BackendFactory.hasParakeetCore || bundle.resourceURL.flatMap {
                Bundle(url: $0.appendingPathComponent("FluidAudio_FluidAudio.bundle"))
            } != nil
            let valid = resourcesValid && bundle.bundleIdentifier == "com.hedworth.whispr-lite" && bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
            print("bundle=\(valid ? "ok" : "invalid") arch=arm64 parakeet=\(BackendFactory.hasParakeetCore) resources=\(resourcesValid ? "ok" : "invalid")")
            exit(valid ? 0 : 1)
        }
        if CommandLine.arguments.contains("--permission-status") {
            print("permissions accessibility=\(AXIsProcessTrusted()) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) input-monitoring=\(CGPreflightListenEventAccess())")
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--batch-flow-check") {
            Task {
                do { try await NativeBatchCheck.run(arguments: Array(CommandLine.arguments.dropFirst(index + 1))); exit(0) }
                catch { print("batch-flow check failed: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--asr-check"),
           CommandLine.arguments.count > index + 1 {
            let cache = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            Task {
                do {
                    let model: ParakeetModel
                    if CommandLine.arguments.count > index + 2 {
                        guard let selected = ParakeetModel(rawValue: CommandLine.arguments[index + 2]) else { throw AppError.unsupported }
                        model = selected
                    } else { model = .unified }
                    let backend = ParakeetCoreBackend(cacheRoot: cache, model: model)
                    try await backend.prepare()
                    let empty = try await backend.transcribe(PCM16k([]))
                    let silence = try await backend.transcribe(PCM16k([Float](repeating: 0, count: 8_000)))
                    guard empty.text.isEmpty, silence.audioDuration == 0.5 else { throw AppError.inference }
                    try await backend.unload()
                    print("bundled-asr model=\(model.rawValue) preparation=ok short-input=ok unload=ok")
                    exit(0)
                } catch { print("bundled-asr check failed: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        do { store = try SettingsStore() }
        catch { status = "Settings could not be loaded"; readinessState = .needsAttention; createMenu(); return }
        createMenu()
        diagnostics = DiagnosticLogger(directory: store.directory.appendingPathComponent("Diagnostics", isDirectory: true))
        diagnostics?.setEnabled(store.preferences.debugLogging)
        indicator.activitySource = { [weak self] in self?.audio.recordingActivity ?? 0 }
        observeLifecycle()
        if CommandLine.arguments.contains("--benchmark-window") { showBenchmark() }
        if CommandLine.arguments.contains("--capture-flow-check") { showBenchmark() }
        configure()
        if CommandLine.arguments.contains("--settings") { showSettings() }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-flow-check") {
            Task {
                do {
                    try await runCaptureFlowCheck(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
                    exit(0)
                } catch {
                    print("capture-flow check failed: \(type(of: error))")
                    exit(1)
                }
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--readiness-report"), CommandLine.arguments.count > index + 1 {
            writeReadinessReport(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
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
            let report: [String: Any] = ["schema": 1, "ready": ready, "status": status,
                "asr_model": store.preferences.asrModel.rawValue,
                "microphone_authorized": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                "accessibility_authorized": AXIsProcessTrusted(), "input_monitoring_authorized": CGPreflightListenEventAccess(),
                "event_tap_ready": tapReady, "pipeline_ready": pipelineReady,
                "warm_capture": store.preferences.warmCapture, "media_status": media.status,
                "physical_hotkey_or_dictation_tested": false, "private_content_recorded": false]
            var success = ready
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
                print("readiness-check ready=\(ready) event-tap=\(tapReady)")
            } catch { success = false; print("readiness report could not be written") }
            setupTask?.cancel(); hotkey?.stop(); coordinator?.suspend(); audio.suspend(); media.shutdown()
            try? await Task.sleep(for: .milliseconds(700))
            exit(success ? 0 : 1)
        }
    }
    private func createMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setMenuAppearance(.idle)
        let menu = NSMenu()
        for (title, action) in [("Starting", #selector(showStatus)), ("Copy last result", #selector(copyResult)),
                                ("Settings…", #selector(showSettings)), ("Check readiness", #selector(retry)),
                                ("Microphone permission", #selector(requestMicrophone)),
                                ("Accessibility permission", #selector(requestAccessibility)),
                                ("Input Monitoring settings", #selector(inputMonitoring)),
                                ("Benchmark text field", #selector(showBenchmark)), ("Quit", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item.menu = menu
    }
    private func configure() {
        guard !recordingShortcut else { return }
        guard let store else { update("Settings file is invalid. Review preferences.json before preparing.", readiness: .needsAttention); return }
        guard sessionAvailable, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else {
            suspendSession(); return
        }
        let previousSetup = setupTask
        let previousCoordinator = coordinator
        previousSetup?.cancel(); hotkey?.stop(); hotkey = nil
        previousCoordinator?.suspend(); audio.suspend(); media.shutdown()
        indicator.hide()
        pipelineReady = false; tapReady = false
        settingsEpoch = UUID(); let epoch = settingsEpoch
        let preferences = store.preferences
        diagnostics?.setEnabled(preferences.debugLogging)
        diagnostics?.record(.init(.configuration, configuration: .init(preferences)))
        let debug = diagnostics?.isEnabled == true
        insertion.diagnostics = debug ? diagnostics : nil; media.diagnostics = debug ? diagnostics : nil
        audio.showAudioActivity = preferences.showAudioActivity
        audio.debugTimings = debug
        let backend: any ASRBackend
        do { backend = try BackendFactory.make(mode: preferences.backend, endpoint: preferences.asrEndpoint,
            cacheRoot: preferences.asrModelDirectory.isEmpty ? nil : URL(fileURLWithPath: preferences.asrModelDirectory, isDirectory: true),
            allowDownloads: preferences.allowASRDownloads, model: preferences.asrModel) }
        catch { update("Check the selected backend settings.", readiness: .needsAttention); return }
        let cleanup: any TextCleanup
        do {
            let prompt = try store.privateText("prompt.txt") ?? SettingsStore.defaultPrompt
            let dictionary = try store.privateText("dictionary.txt") ?? ""
            cleanup = preferences.backend == .demo ? DemoCleanup() : HTTPCleanup(.init(endpoint: try LocalEndpoint(preferences.cleanupEndpoint), prompt: prompt, dictionary: dictionary,
                inputFormat: preferences.cleanupInputFormat, dictionaryPrefix: preferences.cleanupDictionaryPrefix))
            var pipeline = BatchPipeline(backend: backend, cleanup: cleanup)
            pipeline.asrDeadline = .seconds(preferences.asrTimeoutSeconds)
            pipeline.cleanupDeadline = .seconds(preferences.cleanupTimeoutSeconds)
            coordinator = DictationCoordinator(capture: audio, insertion: insertion, media: media, pipeline: pipeline)
            coordinator?.diagnostics = debug ? diagnostics : nil
            if let timings = coordinator?.timings {
                timings.setEnabled(debug)
                insertion.timings = debug ? timings : nil
                if debug {
                    timings.onEvent = { [weak self] event in
                        self?.diagnostics?.record(.init(.timing, session: event.session, stage: event.stage, milliseconds: event.seconds * 1000))
                    }
                }
            }
            coordinator?.streamingEnabled = preferences.backend == .demo && preferences.streamingDemo
            coordinator?.safetyDuration = .seconds(preferences.warmCapture ? 119.8 : 119.95)
        } catch { update("Check private prompt and local endpoint settings", readiness: .needsAttention); return }
        coordinator?.onChange = { [weak self] in self?.refresh() }
        audio.onFailure = { [weak self] in
            self?.coordinator?.suspend(); self?.update("Microphone changed. Check readiness to rebuild capture.")
        }
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
                await previousCoordinator?.settlePressWarmup()
                guard self.settingsEpoch == epoch, self.sessionAvailable, !Task.isCancelled else { return }
                try await self.localBackend?.unload()
                guard self.settingsEpoch == epoch, self.sessionAvailable, !Task.isCancelled else { return }
                self.localBackend = backend as? ParakeetCoreBackend
                try await withDeadline(.seconds(preferences.allowASRDownloads ? 900 : 120), stage: "Preparation") {
                    try await backend.prepare { [weak self] stage in
                        DispatchQueue.main.async {
                            guard let self, self.settingsEpoch == epoch, self.readinessState == .preparing else { return }
                            if self.diagnostics?.isEnabled == true {
                                var record = DiagnosticRecord(.preparationProgress); record.preparation = stage
                                self.diagnostics?.record(record)
                            }
                            self.update(stage.rawValue)
                        }
                    }
                }
                if preferences.backend != .demo {
                    checkingCleanup = true
                    self.update("Checking cleanup service", readiness: .preparing)
                    try await LocalHTTP().cleanupReadiness(LocalEndpoint(preferences.cleanupEndpoint))
                    guard self.settingsEpoch == epoch, self.sessionAvailable, !Task.isCancelled else { return }
                    if let cleanup = cleanup as? HTTPCleanup {
                        self.update("Preparing cleanup", readiness: .preparing)
                        try await withDeadline(.seconds(preferences.cleanupTimeoutSeconds), stage: "Cleanup preparation") {
                            try await cleanup.preparePrefix()
                        }
                    }
                }
                guard self.settingsEpoch == epoch, self.sessionAvailable, !Task.isCancelled else { return }
                if self.diagnostics?.isEnabled == true {
                    var permissionRecord = DiagnosticRecord(.permissions)
                    permissionRecord.accessibility = AXIsProcessTrusted()
                    permissionRecord.microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    permissionRecord.inputMonitoring = CGPreflightListenEventAccess()
                    self.diagnostics?.record(permissionRecord)
                }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                    self.update("Microphone permission needed", detail: "Allow microphone access below, then check readiness.", readiness: .needsAttention); return
                }
                try self.audio.prepare(warm: preferences.warmCapture, microphoneUID: preferences.microphoneUID, streaming: preferences.backend == .demo && preferences.streamingDemo)
                guard AXIsProcessTrusted() else {
                    self.audio.suspend(); self.update("Accessibility permission needed", detail: "Enable Whispr Lite in Accessibility settings below, then check readiness.", readiness: .needsAttention); return
                }
                self.pipelineReady = true
                self.diagnostics?.record(.init(.preparationReady, milliseconds: preparationStart.map { Self.milliseconds($0.duration(to: .now)) }))
                self.hotkey = GlobalHotkey(configuration: preferences.hotkey, callback: { [weak self] action in
                    // The event-tap thread emits in order; FIFO dispatch keeps press/release in that order.
                    DispatchQueue.main.async {
                        guard let self, self.settingsEpoch == epoch else { return }
                        self.diagnostics?.record(.init(.hotkey, code: action == .press ? .press : action == .release ? .release : .cancel))
                        switch action {
                        case .press: self.coordinator?.press()
                        case .release: self.coordinator?.release()
                        case .cancel: self.coordinator?.cancel()
                        }
                    }
                }, readiness: { [weak self] ready in DispatchQueue.main.async {
                    guard let self, self.settingsEpoch == epoch else { return }
                    self.tapReady = ready; self.coordinator?.ready = ready && self.pipelineReady
                    self.diagnostics?.record(.init(.readiness, code: ready ? .ready : .notReady))
                    self.update(ready ? "Ready to dictate" : "Input Monitoring permission needed",
                        detail: ready ? "" : "Enable Whispr Lite in Input Monitoring settings below, then check readiness.",
                        readiness: ready ? .ready : .needsAttention)
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
    private func update(_ text: String, detail: String = "", readiness: SetupReadiness? = nil) {
        status = store?.preferences.backend == .demo ? "DEMO — \(text)" : text
        statusDetail = detail
        if let readiness { readinessState = readiness }
        item?.menu?.items.first?.title = status
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
        item?.button?.title = store?.preferences.backend == .demo ? " DEMO" : ""
    }
    private func observeLifecycle() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendSession() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeSession() }
            })
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(retry), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    private func suspendSession() {
        diagnostics?.record(.init(.suspended))
        sessionAvailable = false
        settingsEpoch = UUID(); setupTask?.cancel(); hotkey?.stop(); hotkey = nil
        pipelineReady = false; tapReady = false
        coordinator?.suspend(); audio.suspend(); media.shutdown(); indicator.hide()
        update("Dictation paused", detail: "Unlock your Mac or return to this session, then check readiness.", readiness: .needsAttention)
    }
    private func resumeSession() { sessionAvailable = true; configure() }
    func beginShortcutRecording() {
        guard !recordingShortcut else { return }
        recordingShortcut = true
        settingsEpoch = UUID(); setupTask?.cancel(); hotkey?.stop(); hotkey = nil
        pipelineReady = false; tapReady = false
        coordinator?.suspend(); audio.suspend(); media.shutdown(); indicator.hide()
        update("Choosing a shortcut", detail: "Dictation is paused while you record the shortcut.", readiness: .needsAttention)
    }
    func endShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false; resumeSession()
    }
    @objc private func locked() { suspendSession() }
    @objc private func showStatus() {}
    @objc func retry() { resumeSession() }
    func showDiagnosticLogs() {
        guard let diagnostics else { return }
        if FileManager.default.fileExists(atPath: diagnostics.directory.path) { NSWorkspace.shared.open(diagnostics.directory) }
    }
    var diagnosticLogFailed: Bool { diagnostics?.hasFailed == true }
    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
    @objc private func copyResult() {
        guard let text = coordinator?.recoveryText else { return }
        insertion.clipboard.settle()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc func requestMicrophone() {
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            if allowed { configure() }
            else { openSettings("Privacy_Microphone") }
        }
    }
    @objc func requestAccessibility() {
        if !AXIsProcessTrusted() {
            openSettings("Privacy_Accessibility")
        } else { configure() }
    }
    @objc func inputMonitoring() { openSettings("Privacy_ListenEvent") }
    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    @objc private func showSettings() {
        guard let store else { return }
        if settingsWindow == nil {
            let view = SettingsView(store: store, app: self) { [weak self] in self?.configure() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            window.title = "Whispr Lite Settings"; window.contentView = host
            window.contentMinSize = NSSize(width: 620, height: 560)
            window.isReleasedWhenClosed = false; window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showBenchmark() {
        if benchmarkWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Whispr Lite — visible text benchmark"
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
              let field = benchmarkField, let window = benchmarkWindow else { throw AppError.unsupported }
        let fixture = URL(fileURLWithPath: arguments[0])
        let player = URL(fileURLWithPath: arguments[1])
        let expectedWords = arguments[3].lowercased().split(separator: " ")
        guard !expectedWords.isEmpty else { throw AppError.unsupported }
        let output = URL(fileURLWithPath: arguments[4])
        let device = arguments[2]
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while readinessState == .preparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard readinessState == .ready, let coordinator else { throw AppError.notReady }
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
                throw AppError.targetChanged
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
            guard coordinator.state == .recording else { throw AppError.notReady }
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
            guard status == 0 else { throw AppError.capture }
            try await Task.sleep(for: .milliseconds(150))
            coordinator.release()
            let visibleDeadline = ContinuousClock.now.advanced(by: .seconds(12))
            while visibleMS == nil && ContinuousClock.now < visibleDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let visibleMS, !field.string.isEmpty else { throw AppError.inference }
            let events = coordinator.timings.events
            guard let session = events.last(where: { $0.stage == .visibleText })?.session else { throw AppError.inference }
            let owned = events.filter { $0.session == session }
            func span(_ start: TimingStage, _ end: TimingStage) throws -> Double {
                guard let left = owned.first(where: { $0.stage == start }),
                      let right = owned.first(where: { $0.stage == end }), right.seconds >= left.seconds else { throw AppError.inference }
                return (right.seconds - left.seconds) * 1000
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
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
    @objc private func quit() {
        setupTask?.cancel(); hotkey?.stop(); coordinator?.suspend(); audio.suspend()
        indicator.hide()
        insertion.clipboard.settle(); media.shutdown()
        Task { try? await Task.sleep(for: .milliseconds(700)); NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        diagnostics?.record(.init(.shutdown))
        coordinator?.suspend(); audio.suspend(); media.shutdown(); insertion.clipboard.settle(); indicator.hide()
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
