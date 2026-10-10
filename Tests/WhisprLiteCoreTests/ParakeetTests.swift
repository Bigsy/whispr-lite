import Foundation
import Testing
@testable import WhisprLiteCore

@Suite struct ParakeetIntegrationTests {
    @Test(arguments: ParakeetModel.allCases)
    func realLibraryFailsExplicitlyWithoutCachedModels(_ model: ParakeetModel) async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let backend = ParakeetCoreBackend(cacheRoot: cache, model: model)
        #expect(await backend.readiness() == .unloaded)
        do { try await backend.prepare(); Issue.record("Missing cache must fail, without fake output or a download") }
        catch { #expect(await backend.readiness() == .failed) }
        do { _ = try await backend.transcribe(PCM16k([0.1])); Issue.record("Unprepared models must reject transcription") }
        catch {}
        #expect(BackendFactory.hasParakeetCore)
    }
    @Test func defaultAndSavedHTTPPreferencesStayDistinct() throws {
        #expect(Preferences().backend == .parakeet)
        #expect(Preferences().asrModel == .unified)
        let saved = try JSONDecoder().decode(Preferences.self, from: Data("{\"version\":1,\"backend\":\"http\"}".utf8))
        #expect(saved.backend == .http)
        #expect(saved.asrModel == .unified)
        #expect(!saved.allowASRDownloads && saved.asrModelDirectory.isEmpty)
    }
    @Test func factorySelectsTheRequestedLibraryModel() throws {
        let identifiers: [ParakeetModel: String] = [.unified: "parakeet-unified-en-0.6b", .ultra: "parakeet-ultra",
            .v2: "parakeet-tdt-0.6b-v2", .v3: "parakeet-tdt-0.6b-v3"]
        for model in ParakeetModel.allCases {
            let backend = try #require(BackendFactory.make(mode: .parakeet, endpoint: "http://127.0.0.1:11435", model: model) as? ParakeetCoreBackend)
            #expect(backend.modelID == identifiers[model])
            #expect(!backend.capabilities.streaming)
        }
    }
    @MainActor @Test func savedModelRoundTripsWithoutChangingPrivateTextOrShortcut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        var preferences = Preferences(); preferences.hotkey = .init(keyCode: 62); preferences.debugLogging = true
        for model in ParakeetModel.allCases {
            preferences.asrModel = model
            try store.save(preferences, prompt: "synthetic prompt", dictionary: "synthetic dictionary")
            let restored = try SettingsStore(directory: root)
            #expect(restored.preferences.asrModel == model)
            #expect(restored.preferences.hotkey == preferences.hotkey && restored.preferences.debugLogging)
            #expect(!restored.preferences.allowASRDownloads)
            #expect(try restored.privateText("prompt.txt") == "synthetic prompt")
            #expect(try restored.privateText("dictionary.txt") == "synthetic dictionary")
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Preferences.self, from: Data("{\"asrModel\":\"unknown\"}".utf8))
        }
    }
    @Test func debugConfigurationIdentifiesLocalModelAndDecodesOlderRecords() throws {
        var preferences = Preferences(); preferences.asrModel = .ultra
        #expect(DiagnosticConfiguration(preferences).asrModel == .ultra)
        preferences.backend = .http
        #expect(DiagnosticConfiguration(preferences).asrModel == nil)
        let current = try JSONEncoder().encode(DiagnosticConfiguration(Preferences()))
        var old = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        old.removeValue(forKey: "asrModel")
        let decoded = try JSONDecoder().decode(DiagnosticConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.asrModel == nil && decoded.backend == .parakeet)
    }
}
