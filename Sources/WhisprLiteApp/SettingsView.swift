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
    let requestMicrophone: () -> Void
    let requestAccessibility: () -> Void
    let requestInputMonitoring: () -> Void

    static let preview = Self(checkReadiness: {}, beginShortcutRecording: {},
        endShortcutRecording: {}, showDictationHistory: {},
        deleteDictationHistory: { false }, showDiagnosticLogs: {},
        requestMicrophone: {}, requestAccessibility: {}, requestInputMonitoring: {})
}
private final class SettingsSectionHeights {
    var header: CGFloat = 0
    var content: CGFloat = 0
    var footer: CGFloat = 0
}

/// Fixed-width settings whose window follows each page's height, so ordinary settings never
/// need scrolling. The scroll view is only a fallback for a page taller than the screen; the
/// prompt and dictionary editors scroll inside and can be dragged taller.
@MainActor struct SettingsView: View {
    static let width: CGFloat = 640
    let store: SettingsStore
    @ObservedObject var status: AppStatus
    @ObservedObject var engine: CleanupEngineModel
    let actions: SettingsActions
    let onHeightChange: (CGFloat) -> Void
    let saved: () -> Void
    private let enumerateMicrophones: Bool
    @State private var page: SettingsPage
    @State private var preferences: Preferences
    @State private var prompt: String
    @State private var dictionary: String
    @State private var promptUnreadable: Bool
    @State private var dictionaryUnreadable: Bool
    @State private var promptEdited = false
    @State private var dictionaryEdited = false
    @State private var error: String
    @State private var recordingShortcut = false
    @State private var microphones: [MicrophoneDevice] = []
    @State private var confirmingHistoryDelete = false
    @State private var historyMessage = ""
    @State private var showingDifferences = false
    @State private var sectionHeights = SettingsSectionHeights()
    @AppStorage("settingsPromptEditorHeight") private var promptHeight = 132.0
    @AppStorage("settingsDictionaryEditorHeight") private var dictionaryHeight = 84.0

    init(store: SettingsStore, status: AppStatus, engine: CleanupEngineModel, actions: SettingsActions,
         page: SettingsPage = .general,
         enumerateMicrophones: Bool = true, onHeightChange: @escaping (CGFloat) -> Void,
         saved: @escaping () -> Void) {
        self.store = store; self.status = status; self.engine = engine; self.actions = actions
        self.onHeightChange = onHeightChange
        self.saved = saved; self.enumerateMicrophones = enumerateMicrophones
        _page = State(initialValue: page)
        _preferences = State(initialValue: store.preferences)
        let loadedPrompt = Self.loadPrivateText(.prompt, fallback: SettingsStore.defaultPrompt, store: store)
        let loadedDictionary = Self.loadPrivateText(.dictionary, fallback: "", store: store)
        _prompt = State(initialValue: loadedPrompt.text)
        _dictionary = State(initialValue: loadedDictionary.text)
        _promptUnreadable = State(initialValue: loadedPrompt.unreadable)
        _dictionaryUnreadable = State(initialValue: loadedDictionary.unreadable)
        _error = State(initialValue: loadedPrompt.unreadable || loadedDictionary.unreadable
            ? "A private prompt or dictionary could not be read. Its file will be preserved until you edit or reset it." : "")
    }
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
        .onChange(of: prompt) { _, _ in promptEdited = true }
        .onChange(of: dictionary) { _, _ in dictionaryEdited = true }
        .onAppear { if enumerateMicrophones { microphones = MicrophoneDevice.available() } }
        .sheet(isPresented: $recordingShortcut, onDismiss: actions.endShortcutRecording) {
            ShortcutRecordingSheet(recorded: { configuration in
                preferences.hotkey = configuration
                recordingShortcut = false
            }, cancelled: { recordingShortcut = false })
        }
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
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
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
                    Picker("Microphone", selection: $preferences.microphoneUID) {
                        Text("System default").tag("")
                        ForEach(microphones) { Text($0.name).tag($0.id) }
                        if !preferences.microphoneUID.isEmpty && !microphones.contains(where: { $0.id == preferences.microphoneUID }) {
                            Text("Saved microphone: currently unavailable").tag(preferences.microphoneUID)
                        }
                    }.labelsHidden().frame(maxWidth: 260)
                }
            }
            section("While recording") {
                toggleRow("Keep the microphone ready", "Holds a short buffer in memory so your first word isn't cut. The microphone indicator stays on; turn off to save idle power.",
                          isOn: $preferences.warmCapture)
                Divider()
                toggleRow("Show audio activity", "A small wave in the listening pill follows your microphone level.", isOn: $preferences.showAudioActivity)
                Divider()
                toggleRow("Pause media while recording", preferences.pauseMedia && status.snapshot.readiness == .ready ? status.mediaStatus
                          : "Playback resumes only if this recording paused it.", isOn: $preferences.pauseMedia)
            }
            section("Permissions") {
                row("Grant access", "Needed to record and insert text.") {
                    Button("Microphone…", action: actions.requestMicrophone).fixedSize()
                    Button("Accessibility…", action: actions.requestAccessibility).fixedSize()
                    Button("Input Monitoring…", action: actions.requestInputMonitoring).fixedSize()
                }
            }
        }
    }

    private var cleanup: some View {
        Group {
            editorSection("Cleanup prompt", "The default makes minimal edits and keeps your meaning. Add a short context line for your work or terminology.",
                          text: $prompt, height: $promptHeight) {
                Button("Use default prompt") { prompt = SettingsStore.defaultPrompt; promptEdited = true }.controlSize(.small)
                    .help("Replace the editor text with the default. Changes apply when saved.")
            }
            if promptUnreadable {
                warning("Saved prompt could not be read. The editor shows the default; Save preserves the file until you edit or reset it.")
            }
            editorSection("Dictionary and phrases", "Names and terms guide the local model. For an exact conversion, write spoken phrase > Written phrase on its own line; case is ignored.",
                          text: $dictionary, height: $dictionaryHeight) { EmptyView() }
            if dictionaryUnreadable {
                warning("Saved dictionary could not be read. The editor is blank; Save preserves the file until you edit it.")
            }
            section("Dictation history") {
                toggleRow("Keep dictation history on this Mac", "Saves each transcript and its cleaned text in a private file on this Mac, so a better local cleanup model can be trained on your own dictation. Never uploaded or shared. Audio and cancelled dictations are not kept.",
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
                        Button("Choose…", action: chooseCache)
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
                    Divider()
                    row("Cleanup input format") {
                        Picker("Cleanup input format", selection: $preferences.cleanupInputFormat) {
                            Text("Plain transcript").tag(CleanupInputFormat.plain)
                            Text("OpenWhispr transcript tags").tag(CleanupInputFormat.openWhispr)
                        }.labelsHidden().fixedSize()
                    }
                }
                cleanupEngine
            }
            section("Performance") {
                toggleRow("Low-latency capture", "Reads the microphone about every 10 ms so text arrives sooner. Turn off if a microphone records silence or fails.",
                          isOn: $preferences.lowLatencyCapture)
                Divider()
                row("Response deadlines", "\(Int(Preferences.timeoutRange.lowerBound))–\(Int(Preferences.timeoutRange.upperBound)) seconds. A cleanup failure offers the raw transcript to copy.") {
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
            }
        }
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
                prompt: promptUnreadable && !promptEdited ? nil : prompt,
                dictionary: dictionaryUnreadable && !dictionaryEdited ? nil : dictionary)
            if promptEdited { promptUnreadable = false; promptEdited = false }
            if dictionaryEdited { dictionaryUnreadable = false; dictionaryEdited = false }
            error = promptUnreadable || dictionaryUnreadable
                ? "A private prompt or dictionary could not be read. Its file is preserved until you edit or reset it." : ""
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
