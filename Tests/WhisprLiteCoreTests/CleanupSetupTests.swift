import Testing
import Foundation
@testable import WhisprLiteCore

/// Synthetic only: a stand-in native helper and kit. Nothing is downloaded or installed.
@Suite struct CleanupSetupTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-setup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func executable(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func kit(in directory: URL) throws -> URL {
        let kit = directory.appendingPathComponent("CleanupSetup")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try executable(kit.appendingPathComponent("Whispr Lite Cleanup"), "exit 0\n")
        for path in CleanupService.resources {
            let file = kit.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: file)
        }
        let lock = #"{"artifacts": {"model": {"bytes": 2000}, "drafter": {"bytes": 300}}, "llama_server": {"release": {"bytes": 45}}}"#
        try Data(lock.utf8).write(to: kit.appendingPathComponent("Resources/cleanup-stack.json"))
        return kit
    }

    @Test func progressLinesCarryAnOptionalFraction() {
        #expect(CleanupSetupProgress(line: "[0.452] Downloading the cleanup model: 1.2 GB of 2.6 GB")
                == .init(fraction: 0.452, text: "Downloading the cleanup model: 1.2 GB of 2.6 GB"))
        #expect(CleanupSetupProgress(line: "Starting the cleanup service") == .init(fraction: nil, text: "Starting the cleanup service"))
        #expect(CleanupSetupProgress(line: "[7] Not a fraction") == .init(fraction: nil, text: "[7] Not a fraction"))
    }

    @Test func kitNeedsItsNativeHelperAndResourcesAndReportsTheDownloadSize() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(CleanupSetup.kit(resources: directory) == nil)
        let kit = try kit(in: directory)
        #expect(CleanupSetup.kit(resources: directory)?.path == kit.path)
        #expect(CleanupSetup.downloadBytes(kit: kit) == 2_345)
    }

    @Test func modelsComeFromTheKitAndTheInstalledOneFromTheServiceRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kit = try kit(in: directory)
        #expect(CleanupSetup.models(kit: kit).isEmpty) // The size-only lock above is not a full pin.
        let digest = String(repeating: "a", count: 64)
        var stack = CleanupStack(schema: 1, repository: "synthetic/model", revision: String(repeating: "a", count: 40),
            artifacts: ["model": .init(file: "model.gguf", bytes: 2000, sha256: digest), "drafter": .init(file: "draft.gguf", bytes: 300, sha256: digest)],
            llama_server: NativeCleanupTests.Fixture.block(11564), port: 11436, alias: "synthetic-cleanup")
        stack.models = ["small": .init(name: "Synthetic Small", repository: "synthetic/small", revision: String(repeating: "b", count: 40),
            artifacts: ["model": .init(file: "small.gguf", bytes: 400, sha256: digest)], alias: "synthetic-small", format: "s1-mini")]
        try CleanupFiles.write(stack, to: kit.appendingPathComponent("Resources/cleanup-stack.json"))
        let models = CleanupSetup.models(kit: kit)
        #expect(models == [.init(id: CleanupStack.defaultModel, name: "Gemma 4 E2B", alias: "synthetic-cleanup", format: .chat, modelBytes: 2300, downloadBytes: 2400),
                           .init(id: "small", name: "Synthetic Small", alias: "synthetic-small", format: .s1Mini, modelBytes: 400, downloadBytes: 500)])
        #expect(models[0].followsInstructions && !models[1].followsInstructions)

        let agent = directory.appendingPathComponent("agent.plist"), service = directory.appendingPathComponent("Cleanup")
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        #expect(CleanupSetup.installedModel(kit: kit, agent: agent) == nil)
        let plist: [String: Any] = ["Label": CleanupEngineLauncher.label, "WhisprLiteOwner": CleanupEngineLauncher.label,
            "WhisprLiteNativeRunner": true,
            "ProgramArguments": ["/synthetic/native-helper", "run", "--directory", service.path, "--port", "12345"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent)
        // A service installed before there was a choice runs the default model.
        #expect(CleanupSetup.installedModel(kit: kit, agent: agent)?.id == CleanupStack.defaultModel)
        try Data(#"{"model": "small"}"#.utf8).write(to: service.appendingPathComponent("cleanup-model.json"))
        #expect(CleanupSetup.installedModel(kit: kit, agent: agent) == models[1])
        try Data(#"{"model": "newer"}"#.utf8).write(to: service.appendingPathComponent("cleanup-model.json"))
        #expect(CleanupSetup.installedModel(kit: kit, agent: agent) == nil)

        // A chosen model reaches the helper after the service's own folder and port.
        try executable(kit.appendingPathComponent("Whispr Lite Cleanup"), """
            [ "$5 $6 $7 $8 $9 ${10}" = "--directory \(service.path) --port 12345 --model small" ] || exit 9
            """)
        try await CleanupSetup(kit: kit, agent: agent).run(.prepare, model: "small") { _ in }
        await #expect(throws: CleanupEngineFailure.self) { try await CleanupSetup(kit: kit, agent: agent).run(.prepare) { _ in } }
    }

    @Test func stepsRunTheNativeHelperWithProgressAndSurfaceItsError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kit = try kit(in: directory)
        let helper = kit.appendingPathComponent("Whispr Lite Cleanup")
        try executable(helper, """
            [ "$2 $3 $4" = "--kit \(kit.path) --progress" ] || exit 9
            echo "progress: [0.250] Downloading the cleanup model: 0.7 GB of 2.6 GB" >&2
            echo "Verified model" # stdout is not progress
            if [ "$1" = install ]; then
              echo "Cleanup setup failed: Port 11436 is occupied; existing services were left running." >&2; exit 1
            fi
            """)
        let setup = CleanupSetup(kit: kit, agent: directory.appendingPathComponent("absent.plist"))
        let lines = LockedLines()
        try await setup.run(.prepare) { lines.append($0) }
        #expect(lines.values == [.init(fraction: 0.25, text: "Downloading the cleanup model: 0.7 GB of 2.6 GB")])
        await #expect(throws: CleanupEngineFailure("Port 11436 is occupied; existing services were left running.")) {
            try await setup.run(.install) { _ in }
        }
    }

    @Test func cancellingAStepStopsItsProcess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kit = try kit(in: directory)
        try executable(kit.appendingPathComponent("Whispr Lite Cleanup"), "echo 'progress: [0.100] Downloading' >&2\nexec sleep 30\n")
        let started = LockedLines()
        let task = Task { try await CleanupSetup(kit: kit, agent: directory.appendingPathComponent("absent.plist")).run(.prepare) { started.append($0) } }
        let deadline = ContinuousClock.now + .seconds(5)
        while started.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let begun = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(begun.duration(to: .now) < .seconds(5))
    }

    @Test func reinstallKeepsNativeServicePathsAndPortsAndRefusesForeignArguments() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = directory.appendingPathComponent("agent.plist")
        var plist: [String: Any] = ["Label": CleanupEngineLauncher.label, "WhisprLiteOwner": CleanupEngineLauncher.label,
            "WhisprLiteNativeRunner": true,
            "ProgramArguments": ["/synthetic/native-helper", "run", "--directory", "/synthetic custom models", "--port", "12345"]]
        func save() throws { try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent) }
        try save()
        #expect(try CleanupSetup.installedOptions(agent: agent) == ["--directory", "/synthetic custom models", "--port", "12345"])
        plist["WhisprLiteOwner"] = "foreign"; try save()
        #expect(throws: CleanupEngineFailure.self) { try CleanupSetup.installedOptions(agent: agent) }
        plist["WhisprLiteOwner"] = CleanupEngineLauncher.label
        plist["ProgramArguments"] = ["/synthetic/native-helper", "run", "--directory", "/tmp", "--port", "70000"]
        try save()
        #expect(throws: CleanupEngineFailure.self) { try CleanupSetup.installedOptions(agent: agent) }
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [CleanupSetupProgress] = []
    func append(_ line: CleanupSetupProgress) { lock.withLock { lines.append(line) } }
    var values: [CleanupSetupProgress] { lock.withLock { lines } }
}
