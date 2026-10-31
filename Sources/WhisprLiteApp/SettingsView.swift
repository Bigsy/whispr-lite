import AppKit
import SwiftUI
import AVFoundation
import WhisprLiteCore

enum SettingsPage: String, CaseIterable { case general = "General", cleanup = "Cleanup", advanced = "Advanced" }
enum SetupReadiness: Equatable { case preparing, ready, needsAttention }
@MainActor struct SettingsActions {
    let checkReadiness: () -> Void
    let beginShortcutRecording: () -> Void
    let endShortcutRecording: () -> Void
    let showDictationHistory: () -> Void
    let deleteDictationHistory: () async -> Bool
    let showDiagnosticLogs: () -> Void
    let showDebugRecordings: () -> Void
    let deleteDebugRecordings: () async -> Bool
    let requestMicrophone: () -> Void
    let requestAccessibility: () -> Void
    let downloadSpeechModel: () -> Void
    let permissions: () -> PermissionStatus

    /// Input Monitoring is deliberately absent: Accessibility covers the event tap.
    static let preview = Self(checkReadiness: {}, beginShortcutRecording: {},
        endShortcutRecording: {}, showDictationHistory: {},
        deleteDictationHistory: { false }, showDiagnosticLogs: {},
        showDebugRecordings: {}, deleteDebugRecordings: { false },
        requestMicrophone: {}, requestAccessibility: {}, downloadSpeechModel: {},
        permissions: { .init(microphone: true, accessibility: true, inputMonitoring: false) })
}
private final class SettingsSectionHeights {
    var header: CGFloat = 0
    var content: CGFloat = 0
    var footer: CGFloat = 0
}

/// Fixed-width settings whose window follows each page's height, so ordinary settings never
/// need scrolling. The scroll view is only a fallback for a page taller than the screen; the
/// instructions and dictionary editors scroll inside and can be dragged taller.
@MainActor struct SettingsView: View {
    static let width: CGFloat = 640
    let store: SettingsStore
    @ObservedObject var status: AppStatus
    @ObservedObject var engine: CleanupEngineModel
    @ObservedObject var setup: CleanupSetupModel
    let actions: SettingsActions
    let onHeightChange: (CGFloat) -> Void
    let saved: () -> Void
    private let enumerateMicrophones: Bool
    @State private var page: SettingsPage
    @State private var preferences: Preferences
    @State private var instructions: String
    @State private var dictionary: String
    @State private var instructionsUnreadable: Bool
    @State private var dictionaryUnreadable: Bool
    @State private var instructionsEdited = false
    @State private var dictionaryEdited = false
    @State private var error: String
    @State private var recordingShortcut = false
    @State private var microphones: [MicrophoneDevice] = []
    @State private var confirmingHistoryDelete = false
    @State private var historyMessage = ""
    @State private var confirmingRecordingsDelete = false
    @State private var recordingsMessage = ""
    @State private var showingDifferences = false
    @State private var confirmingCleanupInstall = false
    @State private var permissions: PermissionStatus
    @State private var sectionHeights = SettingsSectionHeights()
    @AppStorage("settingsInstructionsEditorHeight") private var instructionsHeight = 56.0
    @AppStorage("settingsDictionaryEditorHeight") private var dictionaryHeight = 84.0

    init(store: SettingsStore, status: AppStatus, engine: CleanupEngineModel, setup: CleanupSetupModel, actions: SettingsActions,
         page: SettingsPage = .general,
         enumerateMicrophones: Bool = true, onHeightChange: @escaping (CGFloat) -> Void,
         saved: @escaping () -> Void) {
        self.store = store; self.status = status; self.engine = engine; self.setup = setup; self.actions = actions
        _permissions = State(initialValue: actions.permissions())
        self.onHeightChange = onHeightChange
        self.saved = saved; self.enumerateMicrophones = enumerateMicrophones
        _page = State(initialValue: page)
        _preferences = State(initialValue: store.preferences)
        let loadedInstructions = Self.loadPrivateText(.instructions, fallback: "", store: store)
        let loadedDictionary = Self.loadPrivateText(.dictionary, fallback: "", store: store)
        _instructions = State(initialValue: loadedInstructions.text)
        _dictionary = State(initialValue: loadedDictionary.text)
        _instructionsUnreadable = State(initialValue: loadedInstructions.unreadable)
        _dictionaryUnreadable = State(initialValue: loadedDictionary.unreadable)
        _error = State(initialValue: loadedInstructions.unreadable || loadedDictionary.unreadable ? Self.unreadableMessage : "")
    }
    private static let unreadableMessage =
        "Private instructions or a dictionary could not be read. The file is preserved until you edit it."
    private static func loadPrivateText(_ file: PrivateFile, fallback: String, store: SettingsStore) -> (text: String, unreadable: Bool) {
        do { return (try store.privateText(file) ?? fallback, false) }
        catch { return (fallback, true) }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
                .overlay(alignment: .bottom) { Divider() }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    sectionHeights.header = $0; fitWindow()
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .general: general
                    case .cleanup: cleanup
                    case .advanced: advanced
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 16)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    sectionHeights.content = $0; fitWindow()
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
                .overlay(alignment: .top) { Divider() }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    sectionHeights.footer = $0; fitWindow()
                }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: instructions) { _, _ in instructionsEdited = true }
        .onChange(of: dictionary) { _, _ in dictionaryEdited = true }
        .onAppear { if enumerateMicrophones { microphones = MicrophoneDevice.available() } }
        // Permissions change in System Settings: re-read on return and on readiness changes, never by polling.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshPermissions() }
        .onChange(of: status.snapshot) { _, _ in refreshPermissions() }
        .sheet(isPresented: $recordingShortcut, onDismiss: actions.endShortcutRecording) {
            ShortcutRecordingSheet(recorded: { configuration in
                preferences.hotkey = configuration
                recordingShortcut = false
            }, cancelled: { recordingShortcut = false })
        }
    }
    private func refreshPermissions() {
        let current = actions.permissions()
        if current != permissions { permissions = current }
    }
    private func fitWindow() {
        guard sectionHeights.header > 0, sectionHeights.content > 0,
              sectionHeights.footer > 0 else { return }
        onHeightChange(sectionHeights.header + sectionHeights.content + sectionHeights.footer)
    }

    private var header: some View {
        VStack(spacing: 14) {
            Picker("Settings page", selection: $page) {
                ForEach(SettingsPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: status.snapshot.readiness == .ready ? "checkmark.circle.fill"
                          : status.snapshot.readiness == .preparing ? "hourglass" : "exclamationmark.circle.fill")
                        .foregroundStyle(status.snapshot.readiness == .ready ? Color.green : Color.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.snapshot.text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if !status.snapshot.detail.isEmpty {
                            Text(status.snapshot.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Check readiness", action: actions.checkReadiness)
                        .disabled(status.snapshot.readiness == .preparing)
                }
                if showsSetup {
                    Divider()
                    setupSteps
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
        .alert("Install the cleanup service?", isPresented: $confirmingCleanupInstall) {
            Button("Install") { setup.install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads any missing cleanup files (up to \(cleanupDownloadSize ?? "the model and llama.cpp")) from Hugging Face and GitHub and checks every file against a pinned checksum. Existing models are reused. It then adds “Whispr Lite Cleanup” to your login items so cleanup is ready whenever you log in. Your dictation stays on this Mac.")
        }
    }

    // MARK: Setup steps

    /// Each step that takes time or needs the user, while setup is incomplete. Hidden when a
    /// ready app only prepares again (after saving or unlocking), so the window does not jump.
    private var showsSetup: Bool {
        if setup.busy { return true }
        if case .failed = setup.phase, status.setup.cleanup != .ready { return true }
        let readiness = status.snapshot.readiness
        guard readiness != .ready, !setupComplete else { return false }
        if readiness == .needsAttention || !status.hasBeenReady { return true }
        if case .working(_, fraction: .some) = status.setup.speech { return true }
        return false
    }
    private var setupComplete: Bool {
        missingPermissions.isEmpty && status.setup.speech == .ready
            && (status.setup.cleanup == .ready || status.setup.cleanup == .hidden)
    }
    private var missingPermissions: [String] {
        [(permissions.microphone, "Microphone"), (permissions.accessibility, "Accessibility")]
            .filter { !$0.0 }.map(\.1)
    }
    private var cleanupDownloadSize: String? {
        setup.downloadBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            setupStep("Permissions", missingPermissions.isEmpty ? .done : .attention,
                      missingPermissions.isEmpty ? "Microphone and Accessibility are allowed."
                      : "Needs \(ListFormatter.localizedString(byJoining: missingPermissions)).") {
                if !missingPermissions.isEmpty { Button("Grant…", action: grantNextPermission) }
            }
            speechStep
            cleanupStep
        }
    }
    private func grantNextPermission() {
        if !permissions.microphone { actions.requestMicrophone() }
        else if !permissions.accessibility { actions.requestAccessibility() }
    }

    @ViewBuilder private var speechStep: some View {
        let saved = store.preferences
        let title = saved.backend == .http ? "Speech server" : "Speech model"
        let model = saved.backend == .parakeet ? saved.asrModel.name : "Your local speech server"
        let size = saved.backend == .parakeet ? saved.asrModel.approximateDownload : nil
        switch status.setup.speech {
        case .waiting:
            setupStep(title, .waiting, "\(model). Waiting to start.")
        case let .working(text, fraction):
            setupStep(title, .working, "\(text). \(model)\(size.map { ", \($0)" } ?? "").", fraction: fraction)
        case .ready:
            setupStep(title, .done, saved.backend == .parakeet ? "\(model), on this Mac." : "\(model) is responding.")
        case .missing:
            setupStep(title, .attention, "\(model) is not downloaded yet\(size.map { " (\($0))" } ?? ""). It downloads once, then runs on this Mac.") {
                Button("Download") { preferences.allowASRDownloads = true; actions.downloadSpeechModel() }
            }
        case let .failed(message):
            setupStep(title, .attention, message)
        }
    }

    @ViewBuilder private var cleanupStep: some View {
        if setup.busy {
            setupStep("Cleanup", .working, setup.text + (setup.phase == .downloading ? setup.fraction.map { " (\(Int($0 * 100))%)" } ?? "" : ""),
                      fraction: setup.phase == .downloading ? setup.fraction : nil) {
                if setup.phase != .installing { Button("Cancel", action: setup.cancel) }
            }
        } else if case let .failed(message) = setup.phase, status.setup.cleanup != .ready {
            setupStep("Cleanup", .attention, "Install stopped: \(message)") {
                Button("Try Again") { confirmingCleanupInstall = true }
            }
        } else {
            switch status.setup.cleanup {
            case .hidden: EmptyView()
            case .waiting: setupStep("Cleanup", .waiting, "Checked after the speech model is ready.")
            case let .working(text): setupStep("Cleanup", .working, "\(text).")
            case .ready: setupStep("Cleanup", .done, "Running on this Mac.")
            case .notInstalled where setup.available:
                setupStep("Cleanup", .attention, "Not installed. A small local model tidies your dictation; it downloads \(cleanupDownloadSize ?? "once") and runs on this Mac.") {
                    Button("Install…") { confirmingCleanupInstall = true }
                }
            case .notInstalled:
                setupStep("Cleanup", .attention, "Not installed. Run make cleanup-install from the Whispr Lite repository.")
            case let .unavailable(message):
                setupStep("Cleanup", .attention, message)
            }
        }
    }

    private enum StepMark {
        case done, working, attention, waiting
        var label: String {
            switch self {
            case .done: "Done"
            case .working: "In progress"
            case .attention: "Needs attention"
            case .waiting: "Waiting"
            }
        }
    }
    private func setupStep(_ title: String, _ mark: StepMark, _ caption: String, fraction: Double? = nil) -> some View {
        setupStep(title, mark, caption, fraction: fraction) { EmptyView() }
    }
    private func setupStep<Controls: View>(_ title: String, _ mark: StepMark, _ caption: String, fraction: Double? = nil,
                                           @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                switch mark {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .working: ProgressView().controlSize(.small)
                case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityLabel(mark.label)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fraction { ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8, content: controls)
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if error.isEmpty { Text("Changes apply when saved.").font(.caption).foregroundStyle(.secondary) }
            else { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 12)
            Button("Save settings", action: save).keyboardShortcut(.defaultAction)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var general: some View {
        Group {
            section("Recording") {
                row("Speech recognition", preferences.backend == .parakeet ? "Runs on this Mac. Model setup is in Advanced."
                    : preferences.backend == .http ? "Uses your local speech server. Its address is in Advanced."
                    : "Demo produces fabricated text and bypasses real speech recognition and cleanup.") {
                    Picker("Speech recognition", selection: $preferences.backend) {
                        Text("Parakeet: on this Mac").tag(BackendMode.parakeet)
                        Text("Local HTTP server").tag(BackendMode.http)
                        if preferences.backend == .demo { Text(DemoLabel.tagged("simulated output")).tag(BackendMode.demo) }
                    }.labelsHidden().fixedSize()
                }
                if preferences.backend == .parakeet {
                    Divider()
                    row("Speech model", "If a model is missing, enable downloads in Advanced.") {
                        Picker("Speech model", selection: $preferences.asrModel) {
                            ForEach(ParakeetModel.allCases, id: \.self) { Text($0.name).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                Divider()
                row("Hold shortcut") {
                    Picker("Hold shortcut", selection: $preferences.hotkey) {
                        ForEach(HotkeyConfiguration.presets, id: \.self) { preset in
                            Text(ShortcutLabel.name(preset)).tag(preset)
                        }
                        if !HotkeyConfiguration.presets.contains(preferences.hotkey) {
                            Text(ShortcutLabel.name(preferences.hotkey)).tag(preferences.hotkey)
                        }
                    }.labelsHidden().fixedSize()
                    Button("Record…") {
                        actions.beginShortcutRecording()
                        recordingShortcut = true
                    }.help("Record any hold key or combination, including Left or Right Control.")
                }
                Divider()
                row("Microphone") {
                    let saved = preferences.microphoneUID.isEmpty ? nil
                        : MicrophoneDevice.saved(preferences.microphoneUID, in: microphones)
                    Picker("Microphone", selection: $preferences.microphoneUID) {
                        Text("System default").tag("")
                        // A saved USB microphone on another port is listed under its saved UID.
                        ForEach(microphones.filter { $0.id != saved?.id }) { Text($0.name).tag($0.id) }
                        if !preferences.microphoneUID.isEmpty && !microphones.contains(where: { $0.id == preferences.microphoneUID }) {
                            Text(saved?.name ?? "Saved microphone: currently unavailable").tag(preferences.microphoneUID)
                        }
                    }.labelsHidden().frame(maxWidth: 260)
                }
            }
            section("While recording") {
                toggleRow("Keep the microphone ready", "Turn on if the start of your first word gets cut; some microphones take longer to start. Keeps the microphone running between dictations, which uses more power, keeps the microphone indicator on and stops your Mac going to sleep by itself.",
                          isOn: $preferences.warmCapture)
                Divider()
                toggleRow("Show audio activity", "A small wave in the listening pill follows your microphone level.", isOn: $preferences.showAudioActivity)
                Divider()
                toggleRow("Pause media while recording", preferences.pauseMedia && status.snapshot.readiness == .ready ? status.mediaStatus
                          : "Playback resumes only if this recording paused it.", isOn: $preferences.pauseMedia)
            }
            section("Permissions") {
                row("Grant access", permissions.microphone && permissions.accessibility
                    ? "All granted." : "Needed to record and insert text.") {
                    permissionButton("Microphone…", granted: permissions.microphone, action: actions.requestMicrophone)
                    permissionButton("Accessibility…", granted: permissions.accessibility, action: actions.requestAccessibility)
                }
            }
        }
    }

    private var cleanup: some View {
        Group {
            section("Transcription") {
                row("Clean up dictation", "Tidy punctuation and self-corrections with the local cleanup model. Turn off to insert the speech model's raw transcript.") {
                    Toggle("Clean up dictation", isOn: $preferences.cleanupEnabled)
                        .labelsHidden().toggleStyle(.checkbox).controlSize(.small)
                }
                Divider()
                toggleRow("Use raw transcription if cleanup is unavailable", "Keep dictating during cleanup outages. Raw transcription is labelled, and cleanup retries on the next dictation. A slow service can still take up to the cleanup deadline.",
                          isOn: $preferences.allowRawTranscription)
                    .disabled(!preferences.cleanupEnabled)
            }
            editorSection("Additional instructions", "Added to the built-in cleanup prompt. Keep it to a short line about your work or terminology.",
                          text: $instructions, height: $instructionsHeight) { EmptyView() }
            if instructionsUnreadable {
                warning("Saved instructions could not be read. The editor is blank; Save preserves the file until you edit it.")
            }
            editorSection("Dictionary and phrases", "Names and terms guide the local model. For an exact conversion, write spoken phrase > Written phrase on its own line; case is ignored.",
                          text: $dictionary, height: $dictionaryHeight) { EmptyView() }
            if dictionaryUnreadable {
                warning("Saved dictionary could not be read. The editor is blank; Save preserves the file until you edit it.")
            }
            section("Dictation history") {
                toggleRow("Keep dictation history on this Mac", "Saves each transcript and its cleaned text in a private file on this Mac, so a better local cleanup model can be trained on your own dictation. Never uploaded or shared. History excludes audio and cancelled dictations.",
                          isOn: $preferences.saveDictationHistory)
                Divider()
                row("Saved history", historyMessage.isEmpty ? "Excluded from Time Machine. Keeps up to \(DictationHistory.maximumStorageBytes / (1024 * 1024)) MB, removing the oldest entries first." : historyMessage) {
                    Button("Show in Finder", action: actions.showDictationHistory).help("~/Library/Application Support/WhisprLite/History")
                    Button("Delete…", role: .destructive) { confirmingHistoryDelete = true }
                }
                if status.dictationHistoryFailed {
                    warning("Saving stopped after a file error. Check free space and folder permissions, then save settings to retry.")
                }
            }
            .alert("Delete all dictation history?", isPresented: $confirmingHistoryDelete) {
                Button("Delete", role: .destructive) {
                    Task { historyMessage = await actions.deleteDictationHistory() ? "Dictation history deleted." : "Dictation history could not be deleted." }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes every saved transcript from this Mac.") }
        }
    }

    private var advanced: some View {
        Group {
            if preferences.backend == .parakeet {
                section("Speech models") {
                    toggleRow("Download missing models when preparing", "Needs internet access. Once cached, speech recognition runs locally.",
                              isOn: $preferences.allowASRDownloads)
                    Divider()
                    row("Model cache folder", "Leave blank for the default FluidAudio cache.") {
                        TextField("Default cache", text: $preferences.asrModelDirectory).textFieldStyle(.roundedBorder).frame(width: 200)
                            .help("Blank uses ~/Library/Application Support/FluidAudio/Models.")
                        Button("Choose…", action: chooseCache).fixedSize()
                    }
                }
            }
            if preferences.backend != .demo {
                section("Local services") {
                    if preferences.backend == .http {
                        row("Speech server") {
                            TextField("http://127.0.0.1:11435", text: $preferences.asrEndpoint).textFieldStyle(.roundedBorder).frame(width: 220)
                        }
                        Divider()
                    }
                    row("Cleanup server", "Local base address without /v1. Saving does not start or replace a service.") {
                        TextField("http://127.0.0.1:11436", text: $preferences.cleanupEndpoint).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }
                cleanupEngine
            }
            section("Performance") {
                toggleRow("Low-latency capture", "Reads the microphone about every 10 ms so text arrives sooner. Turn off if a microphone records silence or fails.",
                          isOn: $preferences.lowLatencyCapture)
                Divider()
                row("Response deadlines", "\(Int(Preferences.timeoutRange.lowerBound))–\(Int(Preferences.timeoutRange.upperBound)) seconds. Cleanup failures keep raw text available. Transcription settings control whether it is inserted.") {
                    Text("Speech").foregroundStyle(.secondary)
                    TextField("Speech deadline", value: $preferences.asrTimeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 48)
                    Text("Cleanup").foregroundStyle(.secondary).padding(.leading, 4)
                    TextField("Cleanup deadline", value: $preferences.cleanupTimeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 48)
                    Text("s").foregroundStyle(.secondary)
                }
            }
            // Demo output is a development mode set in preferences.json, not a user setting.
            section("Diagnostics") {
                row("Record debug timings", "Timing, readiness, paste checks and media replies only; never audio, dictated text, prompts or titles. Up to \(DiagnosticLogger.maximumStorageBytes / (1024 * 1024)) MB.") {
                    Button("Show logs", action: actions.showDiagnosticLogs)
                        .help("~/Library/Application Support/WhisprLite/Diagnostics · Enable logging and save first.")
                    Toggle("Record debug timings", isOn: $preferences.debugLogging).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if status.diagnosticLogFailed {
                    warning("Logging stopped after a file error. Check free space and folder permissions, then turn logging off and on.")
                }
                Divider()
                toggleRow("Save recordings for debugging", "Keeps local WAV audio, including failed transcriptions. Off by default; cancelled and demo recordings are skipped. Never uploaded; excluded from Time Machine.",
                          isOn: $preferences.saveDebugRecordings)
                Divider()
                row("Saved recordings", recordingStorageCaption) {
                    Button("Show recordings", action: actions.showDebugRecordings)
                        .help("~/Library/Application Support/WhisprLite/Recordings")
                    Button("Delete all…", role: .destructive) { confirmingRecordingsDelete = true }
                }
                if !recordingsMessage.isEmpty { Text(recordingsMessage).font(.caption).fixedSize(horizontal: false, vertical: true) }
                if status.debugRecordings.failed {
                    warning("Recording storage is unavailable. Check free space and folder permissions, then save settings to retry.")
                }
                if status.debugRecordings.skipped > 0 {
                    let count = status.debugRecordings.skipped
                    warning("\(count) \(count == 1 ? "recording was" : "recordings were") skipped because the saving queue or storage limit was full.")
                }
            }
            .alert("Delete all debug recordings?", isPresented: $confirmingRecordingsDelete) {
                Button("Delete recordings", role: .destructive) {
                    Task { recordingsMessage = await actions.deleteDebugRecordings() ? "Recordings deleted." : "Recordings could not be deleted." }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes all saved debug audio from this Mac. New recordings will still be saved while enabled.") }
        }
    }

    private var recordingStorageCaption: String {
        let usage = status.debugRecordings.bytes.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)) used" } ?? "Storage usage unavailable"
        return "\(usage) · 500 MB limit (about 4 hours). Oldest recordings are deleted automatically. Turning saving off keeps existing files."
    }

    /// The installed cleanup service's llama.cpp build: check for a newer one, compare, switch.
    private var cleanupEngine: some View {
        section("Cleanup engine") {
            row("llama.cpp build", engineCaption) {
                if engine.busy { ProgressView().controlSize(.small) }
                if engine.activity == .checking {
                    Button("Cancel", action: engine.cancel)
                } else {
                    Button("Check for update", action: engine.check).disabled(engine.busy)
                        .help("Downloads the newest build and compares it with the installed one. Nothing changes until you upgrade.")
                }
            }
            if let report = engine.checked, let candidate = report.candidate {
                Divider()
                row("\(candidate.tag) is available", Self.comparison(report)) {
                    if !report.differences.isEmpty {
                        Button("Show differences…") { showingDifferences = true }
                    }
                    Button(report.differences.isEmpty ? "Upgrade" : "Upgrade anyway", action: engine.upgrade)
                        .disabled(engine.busy)
                }
            }
            if let previous = engine.installed?.previous {
                Divider()
                row("Previous build", "\(previous.tag) is kept so you can switch back.") {
                    Button("Switch back", action: engine.switchBack).disabled(engine.busy)
                }
            }
            if engine.failed { warning(engine.message) }
        }
        .onAppear(perform: engine.refresh)
        .sheet(isPresented: $showingDifferences) {
            if let report = engine.checked {
                CleanupDifferencesSheet(report: report, upgrade: { showingDifferences = false; engine.upgrade() },
                                        close: { showingDifferences = false })
            }
        }
    }
    private var engineCaption: String {
        if engine.busy {
            return engine.progress.isEmpty ? (engine.activity == .switching ? "Restarting cleanup…" : "Starting…") : engine.progress
        }
        if !engine.failed, !engine.message.isEmpty { return engine.message }
        let installed = engine.installed.map { "Running \($0.current.tag) (llama.cpp \($0.current.version)). " } ?? ""
        return installed + "A check compares the newest build with this one on synthetic dictations, using your saved prompt."
    }
    static func comparison(_ report: CleanupEngineReport) -> String {
        func timing(_ build: CleanupBuild?) -> String {
            guard let median = build?.medianMilliseconds, let p90 = build?.p90Milliseconds else { return "unmeasured" }
            return "\(Int(median.rounded())) ms (p90 \(Int(p90.rounded())) ms)"
        }
        let count = report.fixtures ?? 0
        let outputs = report.differences.isEmpty ? "Same output on all \(count) synthetic dictations."
            : "Different output on \(report.differences.count) of \(count) synthetic dictations."
        return "Median \(timing(report.candidate)), against \(timing(report.current)) now. \(outputs)"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 14)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
    /// Label and optional caption on the left, controls on the right.
    private func row<Controls: View>(_ title: String, _ caption: String? = nil, @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption, !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8, content: controls)
        }.padding(.vertical, 8)
    }
    private func permissionButton(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if granted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Text(title)
            }
        }
        .fixedSize()
        .help(granted ? "Granted" : "Not granted yet")
        .accessibilityValue(granted ? "Granted" : "Not granted")
    }
    private func toggleRow(_ title: String, _ caption: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, caption) { Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }
    private func warning(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
    }
    private func editorSection<Accessory: View>(_ title: String, _ caption: String, text: Binding<String>, height: Binding<Double>,
                                                @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) { sectionTitle(title); Spacer(); accessory() }
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 2)
            ResizableEditor(title: title, text: text, height: height)
        }
    }
    private func chooseCache() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url { preferences.asrModelDirectory = url.path }
    }
    private func save() {
        do {
            try store.save(preferences,
                instructions: instructionsUnreadable && !instructionsEdited ? nil : instructions,
                dictionary: dictionaryUnreadable && !dictionaryEdited ? nil : dictionary)
            if instructionsEdited { instructionsUnreadable = false; instructionsEdited = false }
            if dictionaryEdited { dictionaryUnreadable = false; dictionaryEdited = false }
            error = instructionsUnreadable || dictionaryUnreadable ? Self.unreadableMessage : ""
            saved()
        } catch let failure as SettingsValidationError {
            self.error = failure.message
        } catch {
            self.error = "Could not save settings. Check access to the settings folder and try again."
        }
    }
}

/// Synthetic dictations the installed and candidate builds cleaned differently, so the
/// upgrade decision rests on the actual outputs.
struct CleanupDifferencesSheet: View {
    let report: CleanupEngineReport
    let upgrade: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(report.differences.count) of \(report.fixtures ?? 0) dictations cleaned differently").font(.headline)
            Text("Synthetic test dictations, cleaned with your saved prompt and dictionary.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(report.differences) { difference in
                        VStack(alignment: .leading, spacing: 6) {
                            output("Dictation", difference.input, secondary: true)
                            output(report.current.tag, difference.current)
                            output(report.candidate?.tag ?? "Candidate", difference.candidate)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.textSelection(.enabled)
            }.frame(height: 340)
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Upgrade anyway", action: upgrade)
            }
        }.padding(20).frame(width: 600)
    }
    private func output(_ label: String, _ text: String, secondary: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(text).font(secondary ? .callout : .body).foregroundStyle(secondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A text editor that scrolls inside and can be dragged taller or shorter by its bottom grip.
private struct ResizableEditor: View {
    static let heights = 56.0...520.0
    private static func clampedHeight(_ value: Double) -> Double {
        min(max(value, heights.lowerBound), heights.upperBound)
    }
    let title: String
    @Binding var text: String
    @Binding var height: Double
    @State private var dragStart: Double?
    @State private var cursorPushed = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text).font(.body).scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.top, 6)
                .frame(height: Self.clampedHeight(height))
                .accessibilityLabel(title)
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity, minHeight: 14)
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    if inside, !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true }
                    else if !inside, dragStart == nil { popCursor() }
                }
                // Window coordinates stay put while the window grows downward, so the grip tracks the pointer.
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? height
                        dragStart = start
                        height = Self.clampedHeight(start + value.translation.height)
                    }
                    .onEnded { _ in dragStart = nil; if !hovering { popCursor() } })
                .help("Drag to resize")
                .accessibilityHidden(true)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .onDisappear { popCursor() }
    }
    private func popCursor() { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
}

extension ParakeetModel {
    /// The model cache's size on the development Mac (Unified 600 MB, Ultra 620 MB);
    /// none for models not measured there.
    var approximateDownload: String? {
        switch self {
        case .unified: "about 600 MB"
        case .ultra: "about 620 MB"
        case .v2, .v3: nil
        }
    }
}
