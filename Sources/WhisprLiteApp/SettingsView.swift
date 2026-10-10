import AppKit
import SwiftUI
import AVFoundation
import WhisprLiteCore

enum SettingsPage: String, CaseIterable { case general = "General", cleanup = "Cleanup", advanced = "Advanced" }
enum SetupReadiness: Equatable { case preparing, ready, needsAttention }

@MainActor struct SettingsView: View {
    let store: SettingsStore
    @ObservedObject var app: AppDelegate
    let saved: () -> Void
    private let enumerateMicrophones: Bool
    @State private var page: SettingsPage
    @State private var preferences: Preferences
    @State private var prompt: String
    @State private var dictionary: String
    @State private var error = ""
    @State private var shortcut: String
    @State private var recordingShortcut = false
    @State private var microphones: [MicrophoneDevice] = []

    init(store: SettingsStore, app: AppDelegate, page: SettingsPage = .general,
         enumerateMicrophones: Bool = true, saved: @escaping () -> Void) {
        self.store = store; self.app = app; self.saved = saved; self.enumerateMicrophones = enumerateMicrophones
        _page = State(initialValue: page)
        _preferences = State(initialValue: store.preferences)
        _prompt = State(initialValue: (try? store.privateText("prompt.txt")) ?? SettingsStore.defaultPrompt)
        _dictionary = State(initialValue: (try? store.privateText("dictionary.txt")) ?? "")
        _shortcut = State(initialValue: Self.selection(for: store.preferences.hotkey))
    }
    private static func selection(for hotkey: HotkeyConfiguration) -> String {
        if hotkey == .init() { return "fn" }
        else if hotkey == .init(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue) { return "ctrl-space" }
        else if hotkey == .init(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue) { return "ctrl-alt-space" }
        else { return "custom" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
                        .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whispr Lite").font(.title2.weight(.semibold))
                        Text("Hold your shortcut, speak, then release.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                statusCard
                Picker("Settings page", selection: $page) {
                    ForEach(SettingsPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general: general
                    case .cleanup: cleanup
                    case .advanced: advanced
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Changes apply when saved.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save settings", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if enumerateMicrophones { microphones = MicrophoneDevice.available() } }
        .sheet(isPresented: $recordingShortcut, onDismiss: { app.endShortcutRecording() }) {
            ShortcutRecordingSheet(recorded: { configuration in
                preferences.hotkey = configuration
                shortcut = Self.selection(for: configuration)
                recordingShortcut = false
            }, cancelled: { recordingShortcut = false })
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: app.readinessState == .ready ? "checkmark.circle.fill" : app.readinessState == .preparing ? "hourglass" : "exclamationmark.circle.fill")
                .foregroundStyle(app.readinessState == .ready ? Color.green : Color.orange).font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.status).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if !app.statusDetail.isEmpty {
                    Text(app.statusDetail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Check readiness") { app.retry() }.disabled(app.readinessState == .preparing)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var general: some View {
        Group {
            card("Recording") {
                row("Speech recognition") {
                    Picker("Speech recognition", selection: $preferences.backend) {
                        Text("Parakeet — on this Mac").tag(BackendMode.parakeet)
                        Text("Local HTTP server").tag(BackendMode.http)
                        if preferences.backend == .demo { Text("DEMO — simulated output").tag(BackendMode.demo) }
                    }.labelsHidden()
                }
                if preferences.backend == .parakeet {
                    row("Speech model") {
                        Picker("Speech model", selection: $preferences.asrModel) {
                            ForEach(ParakeetModel.allCases, id: \.self) { Text($0.name).tag($0) }
                        }.labelsHidden()
                    }
                    help("Models are prepared before recording. If a model is missing, enable downloads in Advanced, then save.")
                }
                row("Hold shortcut") {
                    Picker("Hold shortcut", selection: $shortcut) {
                        Text("Globe / Fn").tag("fn")
                        Text("Control + Space").tag("ctrl-space")
                        Text("Control + Option + Space").tag("ctrl-alt-space")
                        if shortcut == "custom" { Text(ShortcutLabel.name(preferences.hotkey)).tag("custom") }
                    }.labelsHidden()
                    Button("Record…") {
                        app.beginShortcutRecording()
                        recordingShortcut = true
                    }.help("Record any hold key or combination, including Left or Right Control.")
                }
                row("Microphone") {
                    Picker("Microphone", selection: $preferences.microphoneUID) {
                        Text("System default").tag("")
                        ForEach(microphones) { Text($0.name).tag($0.id) }
                        if !preferences.microphoneUID.isEmpty && !microphones.contains(where: { $0.id == preferences.microphoneUID }) {
                            Text("Saved microphone — currently unavailable").tag(preferences.microphoneUID)
                        }
                    }.labelsHidden()
                }
                help(preferences.backend == .parakeet ? "Speech recognition runs directly on your Mac. Model setup is in Advanced." : preferences.backend == .http ? "Uses your local speech server. Its address is in Advanced." : "Demo produces fabricated text and bypasses real speech recognition and cleanup.")
            }
            card("While recording") {
                Toggle("Keep the microphone ready", isOn: $preferences.warmCapture)
                help("Keeps a short audio buffer in memory to preserve the first word. The macOS microphone indicator stays on. Turn this off to reduce idle power.")
                Toggle("Show audio activity in the listening pill", isOn: $preferences.showAudioActivity)
                help("A small wave reacts to microphone level while recording. It does not change the audio or detect speech with a model.")
                Divider()
                Toggle("Pause media while recording", isOn: $preferences.pauseMedia)
                help(preferences.pauseMedia && app.readinessState == .ready ? app.mediaStatus : "Media control starts when dictation is ready. Playback resumes only when this recording owns the pause.")
            }
            card("Permissions") {
                help("Microphone, Accessibility and Input Monitoring access are needed for recording and inserting text.")
                HStack(spacing: 10) {
                    Button("Microphone…") { app.requestMicrophone() }
                    Button("Accessibility…") { app.requestAccessibility() }
                    Button("Input Monitoring…") { app.inputMonitoring() }
                }
            }
        }
    }

    private var cleanup: some View {
        Group {
            card("Cleanup prompt") {
                help("The default makes minimal edits and preserves your meaning. Add a short context line for your work or terminology.")
                editor("Cleanup prompt", text: $prompt, height: 150)
                Button("Use default prompt") { prompt = SettingsStore.defaultPrompt }
                    .help("Replace the editor text with the default. Changes apply when saved.")
            }
            card("Dictionary and phrases") {
                help("Names and terms guide the local model. For an exact conversion, add spoken phrase > Written phrase on its own line. Conversions ignore case and keep your chosen spelling.")
                editor("Dictionary", text: $dictionary, height: 110)
            }
            help("The cleanup service address and response deadlines are in Advanced.")
        }
    }

    private var advanced: some View {
        Group {
            if preferences.backend == .parakeet {
                card("Speech models") {
                    Toggle("Download missing models when preparing", isOn: $preferences.allowASRDownloads)
                    help("Downloads require internet access. Once cached, speech recognition runs locally.")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model cache folder").font(.callout.weight(.medium))
                        HStack {
                            TextField("Use the default FluidAudio model cache", text: $preferences.asrModelDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…", action: chooseCache)
                        }
                        help("Leave blank to use ~/Library/Application Support/FluidAudio/Models.")
                    }
                }
            }
            if preferences.backend != .demo {
                card("Local services") {
                    if preferences.backend == .http {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Speech server").font(.callout.weight(.medium))
                            TextField("http://127.0.0.1:11435", text: $preferences.asrEndpoint).textFieldStyle(.roundedBorder)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cleanup server").font(.callout.weight(.medium))
                        TextField("http://127.0.0.1:11436", text: $preferences.cleanupEndpoint).textFieldStyle(.roundedBorder)
                    }
                    help("Use local base addresses without /v1. Saving settings does not start or replace a service.")
                    Picker("Cleanup input format", selection: $preferences.cleanupInputFormat) {
                        Text("Plain transcript").tag(CleanupInputFormat.plain)
                        Text("OpenWhispr transcript tags").tag(CleanupInputFormat.openWhispr)
                    }
                }
            }
            card("Microphone capture") {
                Toggle("Low-latency capture", isOn: $preferences.lowLatencyCapture)
                help("Reads the microphone about every 10 ms instead of every 100 ms, so text arrives sooner after you release. Turn off if a microphone records silence or fails.")
            }
            card("Response deadlines") {
                row("Speech recognition") {
                    TextField("Speech deadline", value: $preferences.asrTimeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("seconds").foregroundStyle(.secondary)
                }
                row("Cleanup") {
                    TextField("Cleanup deadline", value: $preferences.cleanupTimeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("seconds").foregroundStyle(.secondary)
                }
                help("Allowed range: 1–120 seconds. A cleanup failure offers the raw transcript for copying.")
            }
            card("Diagnostics") {
                Toggle("Record debug timings", isOn: $preferences.debugLogging)
                help("Logs timing stages, readiness, paste checks and media replies locally. Audio, dictated text, prompts, clipboard contents and media titles are excluded. Two files retain up to 4 MB in total.")
                Button("Show logs in Finder", action: app.showDiagnosticLogs)
                help("~/Library/Application Support/WhisprLite/Diagnostics · Enable logging and save first.")
                if app.diagnosticLogFailed { Text("Logging stopped after a file error. Check free space and folder permissions, then turn logging off and on.").font(.caption).foregroundStyle(.orange) }
            }
            card("Development") {
                Toggle("Use demo output", isOn: Binding(get: { preferences.backend == .demo }, set: { preferences.backend = $0 ? .demo : .parakeet }))
                help("Demo fabricates text and bypasses real speech recognition and cleanup. It is visibly marked while enabled.")
                if preferences.backend == .demo {
                    Toggle("Exercise streaming in demo mode", isOn: $preferences.streamingDemo)
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).font(.callout).frame(width: 140, alignment: .leading)
            HStack(spacing: 8, content: content).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func help(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.body).scrollContentBackground(.hidden).padding(8).frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
            .accessibilityLabel(title)
    }
    private func chooseCache() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url { preferences.asrModelDirectory = url.path }
    }
    private func save() {
        do {
            switch shortcut {
            case "ctrl-space": preferences.hotkey = .init(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue)
            case "ctrl-alt-space": preferences.hotkey = .init(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
            case "fn": preferences.hotkey = .init()
            default: break // Preserve custom saved gestures when changing unrelated settings.
            }
            try store.save(preferences, prompt: prompt, dictionary: dictionary)
            error = ""; saved()
        } catch {
            self.error = "Check local server addresses, the model folder, deadlines (1–120 seconds) and prompt/dictionary size."
        }
    }
}
