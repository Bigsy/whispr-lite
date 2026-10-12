import Foundation
import Testing
@testable import WhisprLiteCore

/// Runs synthetic launchers only; never touches the real cleanup LaunchAgent or service.
@Suite struct CleanupEngineTests {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    private func launcher(_ script: String, owner: String = CleanupEngineLauncher.label,
                          command: String = "run") throws -> (CleanupEngineLauncher, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("Whispr Lite Cleanup")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let agent = directory.appendingPathComponent("agent.plist")
        let plist: [String: Any] = ["Label": CleanupEngineLauncher.label, "WhisprLiteOwner": owner,
            "ProgramArguments": [executable.path, command, "--directory", "/synthetic dir", "--port", "11436"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent)
        return (try CleanupEngineLauncher(agent: agent), directory)
    }

    @Test func readsOnlyAnAgentWhisprLiteInstalled() throws {
        let (accepted, directory) = try launcher("exit 0")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(accepted.executable.lastPathComponent == "Whispr Lite Cleanup")
        #expect(accepted.options == ["--directory", "/synthetic dir", "--port", "11436"])
        #expect(throws: CleanupEngineFailure.self) { try launcher("exit 0", owner: "someone.else") }
        #expect(throws: CleanupEngineFailure.self) { try launcher("exit 0", command: "install") }
        #expect(throws: CleanupEngineFailure.self) {
            try CleanupEngineLauncher(agent: directory.appendingPathComponent("missing.plist"))
        }
    }

    @Test func streamsProgressAndDecodesTheResult() async throws {
        let (engine, directory) = try launcher("""
            echo "progress: Downloading b11602…" >&2
            echo "Cleanup ready at http://127.0.0.1:11436" >&2
            printf '{"schema": 1, "status": "candidate", "current": {"tag": "b11564", "version": "0.6.0", "median_ms": 221.4, "p90_ms": 309.2}, "candidate": {"tag": "b11602", "version": "0.6.1", "median_ms": 204.8, "p90_ms": 288.0, "published": "2026-10-12T00:00:00Z"}, "fixtures": 24, "identical": false, "differences": [{"fixture": "realistic-07", "input": "%s", "current": "%s", "candidate": "%s"}], "machine": {"chip": "Apple M4 Pro"}}\\n' "$1" "$3" "$5"
            """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = Lines()
        let report = try await engine.run(.check) { progress.append($0) }
        #expect(progress.all == ["Downloading b11602…"])
        #expect(report.status == .candidate)
        #expect(report.candidate?.medianMilliseconds == 204.8)
        #expect(report.current.p90Milliseconds == 309.2)
        // The command and the agent's own directory and port reach the launcher.
        #expect(report.differences == [CleanupDifference(fixture: "realistic-07", input: "upgrade-check",
                                                         current: "/synthetic dir", candidate: "11436")])
    }

    @Test func reportsTheServiceErrorWithoutItsPrefix() async throws {
        let (engine, directory) = try launcher("""
            echo "progress: Checking GitHub for llama.cpp builds…" >&2
            echo "Cleanup setup failed: Port 11437 is occupied" >&2
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: CleanupEngineFailure("Port 11437 is occupied")) {
            try await engine.run(.check) { _ in }
        }
    }

    @Test func explainsHowToUpdateARunnerThatPredatesUpgrades() async throws {
        let (engine, directory) = try launcher("""
            echo "cleanup-service.py: error: argument command: invalid choice: 'status'" >&2
            exit 2
            """)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await engine.run(.status) { _ in }
            Issue.record("An old runner must fail")
        } catch let failure as CleanupEngineFailure {
            #expect(failure.message.contains("make cleanup-install"))
        }
    }

    @Test func cancellingStopsTheCommand() async throws {
        let (engine, directory) = try launcher("""
            trap 'echo stopped > "$(dirname "$0")/stopped"; exit 143' TERM
            echo "progress: Comparing outputs: 1 of 96" >&2
            while :; do sleep 0.05; done
            """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Lines()
        let task = Task { try await engine.run(.check) { started.append($0) } }
        let deadline = ContinuousClock.now + .seconds(5)
        while started.all.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stopped").path))
    }
}
