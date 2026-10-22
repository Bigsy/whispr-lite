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
