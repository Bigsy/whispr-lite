import Testing
import Foundation
@testable import WhisprLiteCore

@MainActor @Suite struct SettingsTests {
    @Test func privatePreferencesVersionAndOldConfigDefaultSafely() throws {
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(defaults == Preferences())
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1,\"backend\":\"http\"}".utf8))
        #expect(!old.warmCapture && old.pauseMedia)
        #expect(old.cleanupInputFormat == .plain)
        // The removed demo streaming setting still loads from older files.
        let removed = try JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1,\"backend\":\"demo\",\"streamingDemo\":true}".utf8))
        #expect(removed.backend == .demo)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        var preferences = Preferences(); preferences.backend = .demo
        try store.save(preferences, prompt: "synthetic prompt", dictionary: "synthetic dictionary")
        #expect(try store.privateText(.dictionary) == "synthetic dictionary")
        #expect(try SettingsStore(directory: root).preferences.backend == .demo)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("dictionary.txt").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try Data("{\"version\":2}".utf8).write(to: root.appendingPathComponent("preferences.json"))
        #expect(throws: AppError.unsupported) { try SettingsStore(directory: root) }
    }
    /// The decoder lists each field; one it misses would load as its default without an error.
    @Test func everySavedPreferenceSurvivesARoundTrip() throws {
        var changed = Preferences()
        changed.backend = .http
        changed.asrModel = .ultra
        changed.allowASRDownloads = true
        changed.asrModelDirectory = "/synthetic/models"
        changed.hotkey = HotkeyConfiguration(keyCode: KeyCode.space, modifiers: 0x40000)
        changed.warmCapture = true
        changed.lowLatencyCapture = false
        changed.pauseMedia = false
        changed.showAudioActivity = false
        changed.debugLogging = true
        changed.saveDebugRecordings = true
        changed.saveDictationHistory = false
        changed.microphoneUID = "synthetic-microphone"
        changed.asrEndpoint = "http://127.0.0.1:1"
        changed.cleanupEndpoint = "http://127.0.0.1:2"
        changed.cleanupInputFormat = .openWhispr
        changed.cleanupDictionaryPrefix = "\nSynthetic dictionary:\n"
        changed.asrTimeoutSeconds = 7
        changed.cleanupTimeoutSeconds = 9
        // A new preference fails here until it is set above, so the round trip covers it.
        let defaults = Dictionary(uniqueKeysWithValues: Mirror(reflecting: Preferences()).children.map {
            ($0.label ?? "", String(describing: $0.value))
        })
        for child in Mirror(reflecting: changed).children where child.label != "version" {
            #expect(String(describing: child.value) != defaults[child.label ?? ""], "\(child.label ?? "") is not changed")
        }
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        #expect(decoded == changed)
    }
    @Test func bundledBenchmarkPromptMatchesAppDefault() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("Resources/cleanup-prompt.txt"), encoding: .utf8)
        #expect(file.trimmingCharacters(in: .newlines) == SettingsStore.defaultPrompt.trimmingCharacters(in: .newlines))
    }
    @Test func invalidSettingsIdentifyTheirFieldBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        let store = try SettingsStore(directory: root)
        var preferences = Preferences()
        preferences.asrTimeoutSeconds = 0
        #expect(throws: SettingsValidationError(.asrTimeout, "Speech recognition deadline must be 1–120 seconds.")) {
            try store.save(preferences, prompt: nil, dictionary: nil)
        }
        preferences.asrTimeoutSeconds = 10
        preferences.cleanupEndpoint = "https://example.com"
        #expect(throws: SettingsValidationError(.cleanupEndpoint, "Cleanup URL must be a local HTTP address.")) {
            try store.save(preferences, prompt: nil, dictionary: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func unreadablePromptIsPreservedWhenOtherSettingsAreSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        try store.save(Preferences(), prompt: "synthetic prompt", dictionary: "synthetic dictionary")
        let promptURL = root.appendingPathComponent("prompt.txt")
        let oversized = Data(repeating: 65, count: 16_385)
        try oversized.write(to: promptURL)
        #expect(throws: AppError.contextLimit) { try store.privateText(.prompt) }
        var preferences = store.preferences
        preferences.pauseMedia = false
        try store.save(preferences, prompt: nil, dictionary: "updated synthetic dictionary")
        #expect(try Data(contentsOf: promptURL) == oversized)
        #expect(try store.privateText(.dictionary) == "updated synthetic dictionary")
        #expect(try SettingsStore(directory: root).preferences.pauseMedia == false)
    }
    @Test func settingsRejectSymlinkAndTightenExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-test-\(UUID())")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        try Data("synthetic outside".utf8).write(to: outside)
        let store = try SettingsStore(directory: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("prompt.txt"), withDestinationURL: outside)
        #expect(throws: CocoaError.self) { try store.save(Preferences(), prompt: "synthetic prompt", dictionary: nil) }
        #expect(throws: CocoaError.self) { try store.privateText(.prompt) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "synthetic outside")
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.json").path))
    }
}
