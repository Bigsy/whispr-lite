import Foundation
import Testing
import Darwin
@testable import WhisprLiteCore

/// Only synthetic files and an in-memory launchctl stand-in. No user services or downloads.
@Suite struct NativeCleanupTests {
    final class LaunchState: @unchecked Sendable {
        let lock = NSLock()
        var running = false
        var rejectNative = false
        var commands: [[String]] = []
        let agent: URL
        init(_ agent: URL) { self.agent = agent }
        func run(_ path: String, _ args: [String], _ env: [String: String]?, _ limit: Int) async throws -> CleanupCommandResult {
            guard path == "/bin/launchctl" else { return try await CleanupProcess.run(path, args, env, limit) }
            return lock.withLock {
                commands.append(args)
                switch args.first {
                case "print": return .init(status: running ? 0 : 1)
                case "bootout": running = false; return .init(status: 0)
                case "bootstrap":
                    let data = try? Data(contentsOf: agent)
                    let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                    if rejectNative && (plist?["ProgramArguments"] as? [String])?.first != "/synthetic/native-helper" {
                        return .init(status: 1)
                    }
                    running = true; return .init(status: 0)
                default: return .init(status: 1)
                }
            }
        }
    }
    struct Fixture {
        let root: URL
        let kit: URL
        let directory: URL
        let agent: URL
        let helper: URL
        let state: LaunchState
        var stack: CleanupStack
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-cleanup-\(UUID())")
            kit = root.appendingPathComponent("kit"); directory = root.appendingPathComponent("Cleanup")
            agent = root.appendingPathComponent("agents/cleanup.plist"); helper = kit.appendingPathComponent("Whispr Lite Cleanup")
            state = LaunchState(agent)
            try PrivateFiles.ensureDirectory(at: kit.appendingPathComponent("Resources"))
            try PrivateFiles.ensureDirectory(at: directory)
            try Data("synthetic native helper".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            for name in CleanupService.resources {
                let file = kit.appendingPathComponent(name)
                try PrivateFiles.ensureDirectory(at: file.deletingLastPathComponent())
                try Data("synthetic public resource".utf8).write(to: file)
            }
            let model = Data("synthetic model".utf8), draft = Data("synthetic drafter".utf8)
            stack = CleanupStack(schema: 1, repository: "synthetic/model", revision: String(repeating: "a", count: 40),
                artifacts: ["model": .init(file: "model.gguf", bytes: Int64(model.count), sha256: CleanupFiles.digest(model)),
                            "drafter": .init(file: "draft.gguf", bytes: Int64(draft.count), sha256: CleanupFiles.digest(draft))],
                llama_server: Self.block(11564), port: try FreePort.number(), alias: "synthetic-cleanup")
            stack.llama_server = try addBuild(11564)
            try CleanupFiles.write(stack, to: kit.appendingPathComponent("Resources/cleanup-stack.json"))
            try model.write(to: directory.appendingPathComponent("model.gguf"))
            try draft.write(to: directory.appendingPathComponent("draft.gguf"))
        }
        static func block(_ number: Int) -> CleanupStack.Server {
            let digest = String(repeating: "a", count: 64), tag = "b\(number)"
            return .init(path: "llama-server", version: "0.6.0", commit: "abcdef01", sha256: digest,
                revision: "abcdef01" + String(repeating: "a", count: 32), minimum_macos: "14.0",
                release: .init(file: "llama-\(tag)-bin-macos-arm64.tar.gz", bytes: 100, sha256: digest,
                    url: "https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/llama-\(tag)-bin-macos-arm64.tar.gz",
                    tag: tag, directory: "llama-\(tag)"), files_sha256: ["llama-server": digest])
        }
        func addBuild(_ number: Int) throws -> CleanupStack.Server {
            var block = Self.block(number)
            let runtime = directory.appendingPathComponent("Binaries/\(block.release.directory)")
            try PrivateFiles.ensureDirectory(at: runtime)
            let binary = runtime.appendingPathComponent("llama-server")
            let text = """
            #!/bin/sh
            if [ "$1" = --version ]; then
              echo 'version: 0.6.0 (build \(number), commit abcdef01)'
            else
              echo '--spec-type draft-mtp --spec-draft-n-max --swa-full --load-mode mmap+mlock --reasoning --temp --alias --host --port --no-webui --no-slots --no-context-shift --cors-origins --log-disable'
            fi
            """
            try Data(text.utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            block.sha256 = try CleanupFiles.digest(binary); block.files_sha256["llama-server"] = block.sha256
            return block
        }
        func service() throws -> CleanupService {
            let system = CleanupSystem(command: state.run, ready: { _, _ in })
            return try CleanupService(kit: kit, executable: helper, directory: directory, agent: agent, system: system)
        }
        func existingAgent(owner: String = CleanupEngineLauncher.label) throws -> Data {
            try PrivateFiles.ensureDirectory(at: agent.deletingLastPathComponent())
            let plist: [String: Any] = ["Label": CleanupEngineLauncher.label, "WhisprLiteOwner": owner,
                "WhisprLiteNativeRunner": true,
                "ProgramArguments": ["/synthetic/native-helper", "run", "--directory", directory.path, "--port", String(stack.port)]]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agent)
            state.running = true
            return data
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func pinnedFilesAreVerifiedBeforeAnyServiceActionAndLibraryAliasesStayInsideRuntime() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var service = try fixture.service()
        let library = service.runtime.appendingPathComponent("libnative.1.dylib")
        try Data("synthetic library".utf8).write(to: library)
        let link = service.runtime.appendingPathComponent("libnative.dylib")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: library.lastPathComponent)
        service.stack.llama_server.files_sha256[link.lastPathComponent] = try CleanupFiles.digest(library)
        _ = try await service.verify()
        try Data("tampered".utf8).write(to: library)
        await #expect(throws: CleanupEngineFailure.self) { try await service.install() }
        #expect(fixture.state.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.path))
    }

    @Test func downloadResumesPublishesVerifiedBytesAndPreservesBadExistingFiles() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bytes = Data("resumed synthetic download".utf8)
        let artifact = CleanupStack.Artifact(file: "download.gguf", bytes: Int64(bytes.count), sha256: CleanupFiles.digest(bytes))
        let destination = fixture.directory.appendingPathComponent(artifact.file)
        let partial = destination.appendingPathExtension("partial")
        try bytes.prefix(6).write(to: partial)
        let system = CleanupSystem(command: { path, arguments, _, _ in
            #expect(path == "/usr/bin/curl")
            #expect(arguments.contains("--continue-at"))
            #expect(arguments.last == "https://example.invalid/model")
            #expect(try Data(contentsOf: partial) == bytes.prefix(6))
            try bytes.write(to: partial)
            return .init(status: 0)
        }, ready: { _, _ in })
        let service = try CleanupService(kit: fixture.kit, executable: fixture.helper, directory: fixture.directory,
                                        agent: fixture.agent, system: system)
        try await service.fetch(artifact, from: "https://example.invalid/model", to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        try Data("bad existing data".utf8).write(to: destination)
        await #expect(throws: CleanupEngineFailure.self) { try await service.fetch(artifact, from: "https://example.invalid/model", to: destination) }
        #expect(try Data(contentsOf: destination) == Data("bad existing data".utf8))
    }

    @Test func cancelledDownloadStopsItsChildAndKeepsItsPartialFile() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("cancelled.gguf")
        let partial = file.appendingPathExtension("partial")
        let system = CleanupSystem(command: { _, _, _, _ in
            try await CleanupProcess.run("/bin/sh", ["-c", "printf partial > \"$1\"; exec sleep 30", "synthetic", partial.path])
        }, ready: { _, _ in })
        let service = try CleanupService(kit: fixture.kit, executable: fixture.helper, directory: fixture.directory,
                                        agent: fixture.agent, system: system)
        let artifact = CleanupStack.Artifact(file: file.lastPathComponent, bytes: 100, sha256: String(repeating: "a", count: 64))
        let task = Task { try await service.fetch(artifact, from: "https://example.invalid/model", to: file) }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? Data(contentsOf: partial)) != Data("partial".utf8), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: partial) == Data("partial".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func partialSymlinksCannotOverwriteAnotherFile() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let unrelated = fixture.root.appendingPathComponent("unrelated")
        try Data("keep me".utf8).write(to: unrelated)
        let file = fixture.directory.appendingPathComponent("download.gguf")
        try FileManager.default.createSymbolicLink(at: file.appendingPathExtension("partial"), withDestinationURL: unrelated)
        let service = try fixture.service()
        let artifact = CleanupStack.Artifact(file: "download.gguf", bytes: 10, sha256: String(repeating: "a", count: 64))
        await #expect(throws: (any Error).self) { try await service.fetch(artifact, from: "https://example.invalid/model", to: file) }
        #expect(try Data(contentsOf: unrelated) == Data("keep me".utf8))
    }

    @Test func nativeReinstallReusesModelsAndInstallsAnImmutableRunner() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.existingAgent()
        let before = try Data(contentsOf: fixture.directory.appendingPathComponent("model.gguf"))
        let service = try fixture.service()
        try await service.prepare() // No curl: every pinned file is already cached.
        try await service.install()
        let launcher = try CleanupEngineLauncher(agent: fixture.agent)
        #expect(try Data(contentsOf: launcher.executable) == Data(contentsOf: fixture.helper))
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("model.gguf")) == before)
        let installed = launcher.executable.deletingLastPathComponent()
        #expect(try CleanupStack.load(installed.appendingPathComponent("Resources/cleanup-stack.json")).llama_server.release.tag == "b11564")
        #expect(FileManager.default.isExecutableFile(atPath: launcher.executable.path))
        try Data("changed runner".utf8).write(to: launcher.executable)
        #expect(throws: CleanupEngineFailure.self) { try service.stageRunner() }
        #expect(try String(contentsOf: launcher.executable, encoding: .utf8) == "changed runner")
    }

    @Test func foreignAgentsArePreservedAndNeverStopped() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let original = try fixture.existingAgent(owner: "another.app")
        let service = try fixture.service()
        await #expect(throws: CleanupEngineFailure.self) { try await service.install() }
        #expect(try Data(contentsOf: fixture.agent) == original)
        #expect(fixture.state.commands.isEmpty)
    }

    @Test func occupiedPortsLeaveTheirListenersAndExistingSettingsAlone() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let listener = try FreePort()
        defer { listener.close() }
        let service = try CleanupService(kit: fixture.kit, executable: fixture.helper, directory: fixture.directory,
            agent: fixture.agent, port: listener.port, system: .init(command: fixture.state.run, ready: { _, _ in }))
        await #expect(throws: CleanupEngineFailure.self) { try await service.install() }
        #expect(fixture.state.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.path))
    }

    @Test func failedBootstrapRestoresThePreviousNativeAgentExactly() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let original = try fixture.existingAgent()
        fixture.state.rejectNative = true
        let service = try fixture.service()
        await #expect(throws: CleanupEngineFailure.self) { try await service.install() }
        #expect(try Data(contentsOf: fixture.agent) == original)
        #expect(fixture.state.running)
        #expect(fixture.state.commands.filter { $0.first == "bootstrap" }.count == 2)
    }

    @Test func failedHealthCheckStopsTheNewAgentAndRemovesOnlyItsPlist() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var service = try CleanupService(kit: fixture.kit, executable: fixture.helper, directory: fixture.directory,
            agent: fixture.agent, system: .init(command: fixture.state.run, ready: { _, _ in throw AppError.notReady }))
        service.startupTimeout = .milliseconds(1)
        await #expect(throws: CleanupEngineFailure.self) { try await service.install() }
        #expect(!fixture.state.running)
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.path))
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("model.gguf")) == Data("synthetic model".utf8))
    }

    @Test func upgradeAndRollbackKeepAcceptedPinsAndRestoreFailedSwitches() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.existingAgent()
        let newer = try fixture.addBuild(11602)
        let candidate = fixture.directory.appendingPathComponent("upgrade-candidate.json")
        try CleanupFiles.write(newer, to: candidate)
        let service = try fixture.service()
        let changed = try await service.applyUpgrade()
        #expect(changed.current.tag == "b11602")
        #expect(changed.previous?.tag == "b11564")
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        let accepted = try fixture.service()
        #expect(accepted.stack.llama_server.release.tag == "b11602")
        let previous = try CleanupStack.readServer(fixture.directory.appendingPathComponent("cleanup-stack.previous.json"))
        let rolled = try await accepted.switchBuild(previous)
        #expect(rolled.current.tag == "b11564")
        #expect(rolled.previous?.tag == "b11602")
        let local = fixture.directory.appendingPathComponent("cleanup-stack.local.json")
        let previousFile = fixture.directory.appendingPathComponent("cleanup-stack.previous.json")
        let savedLocal = try Data(contentsOf: local), savedPrevious = try Data(contentsOf: previousFile)
        fixture.state.rejectNative = true
        // A foreign agent fails before it can be stopped and still restores both pin files.
        let foreign = try fixture.existingAgent(owner: "another.app")
        await #expect(throws: CleanupEngineFailure.self) { try await service.switchBuild(newer) }
        #expect(try Data(contentsOf: local) == savedLocal)
        #expect(try Data(contentsOf: previousFile) == savedPrevious)
        #expect(try Data(contentsOf: fixture.agent) == foreign)
    }

    @Test func uncheckedUpgradesAreRefusedAndPruningPreservesUnrelatedFiles() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let service = try fixture.service()
        await #expect(throws: CleanupEngineFailure.self) { try await service.applyUpgrade() }
        let binaries = fixture.directory.appendingPathComponent("Binaries")
        try Data("keep".utf8).write(to: binaries.appendingPathComponent("unrelated-model.gguf"))
        try Data("obsolete".utf8).write(to: binaries.appendingPathComponent("llama-b100-bin-macos-arm64.tar.gz"))
        try service.prune(keeping: ["b11564"])
        #expect(FileManager.default.fileExists(atPath: binaries.appendingPathComponent("unrelated-model.gguf").path))
        #expect(!FileManager.default.fileExists(atPath: binaries.appendingPathComponent("llama-b100-bin-macos-arm64.tar.gz").path))
        #expect(FileManager.default.fileExists(atPath: service.runtime.path))
    }

    @Test func operationLockSerialisesMutationsAndOutputIsBounded() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        do {
            let first = try CleanupOperationLock(directory: fixture.directory)
            #expect(throws: CleanupEngineFailure.self) { try CleanupOperationLock(directory: fixture.directory) }
            withExtendedLifetime(first) {}
        }
        _ = try CleanupOperationLock(directory: fixture.directory)
        await #expect(throws: CleanupEngineFailure.self) {
            try await CleanupProcess.run("/bin/sh", ["-c", "trap '' TERM; exec /usr/bin/yes synthetic"], nil, 8)
        }
    }

    @Test func runtimeEnvironmentCannotOverridePinnedArgumentsAndPrivateComparisonsAreDiscarded() throws {
        let cleaned = CleanupStack.runtimeEnvironment(["LLAMA_ARG_MODEL": "foreign", "DYLD_INSERT_LIBRARIES": "foreign", "PATH": "/usr/bin"])
        #expect(cleaned["LLAMA_ARG_MODEL"] == nil && cleaned["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(cleaned["PATH"] == "/usr/bin")
        #expect(cleaned["GGML_METAL_RESIDENCY_KEEP_ALIVE_S"] == "86400")
        let privateText = "synthetic private prompt that must never appear"
        #expect(throws: CleanupEngineFailure.self) {
            try CleanupService.checkPrivate([.init(fixture: "1", input: "public", current: "public", candidate: privateText)], forbidden: [privateText])
        }
    }

    @Test func onlyDigestPublishedOfficialArm64ReleasesAreCandidates() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        func release(_ tag: String, digest: String?, host: String = "https://github.com") -> CleanupGitHubRelease {
            .init(tag_name: tag, assets: [.init(name: "llama-\(tag)-bin-macos-arm64.tar.gz", size: 100, digest: digest,
                browser_download_url: "\(host)/ggml-org/llama.cpp/releases/download/\(tag)/llama-\(tag)-bin-macos-arm64.tar.gz")])
        }
        let result = CleanupGitHubRelease.newest([release("b9", digest: digest), release("b10", digest: digest),
            release("b11", digest: nil), release("b12", digest: digest, host: "https://example.invalid")])
        #expect(result?.tag == "b10")
        #expect(CleanupGitHubRelease.newest([release("b11", digest: "sha256:invalid")]) == nil)
    }

    @Test func machOHeaderRequiresArm64AndAnOSThisMacSupports() throws {
        var data = Data()
        for value: UInt32 in [0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0, 0x32, 24, 1, 14 << 16, 0, 0] {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        #expect(try CleanupMachO.minimumOS(data) == "14.0.0")
        #expect(CleanupMachO.supports("14.0", current: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        #expect(!CleanupMachO.supports("15.0", current: .init(majorVersion: 14, minorVersion: 7, patchVersion: 0)))
        data[4] = 7
        #expect(throws: CleanupEngineFailure.self) { try CleanupMachO.minimumOS(data) }
    }
}

private final class FreePort {
    let descriptor: Int32
    let port: Int
    init() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        descriptor = socketDescriptor
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(socketDescriptor, 1) == 0 else { Darwin.close(socketDescriptor); throw AppError.notReady }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &size) } }
        port = Int(UInt16(bigEndian: address.sin_port))
    }
    func close() { Darwin.close(descriptor) }
    static func number() throws -> Int { let listener = try FreePort(); defer { listener.close() }; return listener.port }
}
