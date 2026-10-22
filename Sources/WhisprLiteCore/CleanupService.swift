import Foundation
import Darwin

/// Explicit setup and lifecycle operations, shared by the app's signed native helper and CLI.
public struct CleanupService: Sendable {
    static let runnerName = "Whispr Lite Cleanup"
    static let resources = ["Resources/cleanup-prompt.txt", "Resources/cleanup-fixtures.json", "LICENSE", "THIRD_PARTY_NOTICES.md"]
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisprLite/Cleanup")
    }
    let kit: URL
    let executable: URL
    let directory: URL
    let agent: URL
    let port: Int
    var stack: CleanupStack
    let system: CleanupSystem
    let progress: @Sendable (CleanupSetupProgress) -> Void
    // A login launch rehashes the models before exec; cold loading under memory
    // pressure can exceed 90 seconds even while the server is making progress.
    var startupTimeout: Duration = .seconds(300)

    public init(kit: URL, executable: URL, directory: URL = Self.defaultDirectory,
                agent: URL = CleanupEngineLauncher.agent, port: Int? = nil, useAcceptedBuild: Bool = true,
                progress: @escaping @Sendable (CleanupSetupProgress) -> Void = { _ in }) throws {
        try self.init(kit: kit, executable: executable, directory: directory, agent: agent, port: port,
                      useAcceptedBuild: useAcceptedBuild, system: .init(), progress: progress)
    }
    init(kit: URL, executable: URL, directory: URL, agent: URL, port: Int? = nil,
         useAcceptedBuild: Bool = true, system: CleanupSystem,
         progress: @escaping @Sendable (CleanupSetupProgress) -> Void = { _ in }) throws {
        let base = try CleanupStack.load(kit.appendingPathComponent("Resources/cleanup-stack.json"))
        stack = try useAcceptedBuild ? base.effective(in: directory) : base
        let selectedPort = port ?? base.port
        guard (1024...65535).contains(selectedPort) else { throw CleanupEngineFailure("Port must be between 1024 and 65535") }
        self.kit = kit; self.executable = executable; self.directory = directory
        self.agent = agent; self.port = selectedPort; self.system = system; self.progress = progress
    }
    func report(_ text: String, fraction: Double? = nil) { progress(.init(fraction: fraction, text: text)) }
    var runtime: URL { directory.appendingPathComponent("Binaries/\(stack.llama_server.release.directory)") }

    public func prepare() async throws {
        try PrivateFiles.ensureDirectory(at: directory)
        let total = stack.artifacts.values.reduce(stack.llama_server.release.bytes) { $0 + $1.bytes }
        var completed: Int64 = 0
        for name in ["model", "drafter"] {
            let artifact = stack.artifacts[name]!
            let source = "https://huggingface.co/\(stack.repository)/resolve/\(stack.revision)/\(artifact.file)"
            try await fetch(artifact, from: source, to: directory.appendingPathComponent(artifact.file),
                            completed: completed, total: total)
            completed += artifact.bytes
        }
        if try PrivateFiles.directoryExists(at: runtime) {
            report("Checking llama.cpp")
            try verifyRuntime(runtime)
        } else {
            let binaries = directory.appendingPathComponent("Binaries")
            try PrivateFiles.ensureDirectory(at: binaries)
            let release = stack.llama_server.release
            let archive = binaries.appendingPathComponent(release.file)
            try await fetch(release.artifact, from: release.url, to: archive, completed: completed, total: total)
            let staged = try await extract(archive, root: release.directory)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            try verifyRuntime(staged)
            try FileManager.default.moveItem(at: staged, to: runtime)
        }
        report("Cleanup downloads verified", fraction: 1)
    }

    func fetch(_ artifact: CleanupStack.Artifact, from source: String, to file: URL,
               completed: Int64 = 0, total: Int64 = 0) async throws {
        report("Checking \(artifact.file)")
        if try CleanupFiles.verified(file, artifact) { return }
        if try PrivateFiles.regularFileExists(at: file) {
            throw CleanupEngineFailure("\(artifact.file) failed checksum; it was preserved. Remove or quarantine it before retrying.")
        }
        let partial = file.appendingPathExtension("partial")
        try PrivateFiles.ensureFile(at: partial)
        let bytes = try CleanupFiles.size(partial)
        guard bytes <= artifact.bytes else {
            throw CleanupEngineFailure("\(partial.lastPathComponent) exceeds its pinned size; it was preserved")
        }
        if try !CleanupFiles.verified(partial, artifact) {
            guard bytes < artifact.bytes else {
                throw CleanupEngineFailure("\(partial.lastPathComponent) failed checksum; it was preserved. Remove or quarantine it before retrying.")
            }
            guard URL(string: source)?.scheme == "https" else { throw CleanupEngineFailure("Cleanup downloads require HTTPS") }
            let monitor = Task {
                while !Task.isCancelled {
                    let count = (try? CleanupFiles.size(partial)) ?? 0
                    let fraction = total > 0 ? min(1, Double(completed + count) / Double(total)) : nil
                    report("Downloading \(artifact.file): \(ByteCountFormatter.string(fromByteCount: count, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))", fraction: fraction)
                    try await Task.sleep(for: .seconds(1))
                }
            }
            defer { monitor.cancel() }
            _ = try await system.checked("/usr/bin/curl", ["--fail", "--location", "--show-error", "--silent",
                "--proto", "=https", "--proto-redir", "=https", "--retry", "3", "--connect-timeout", "20",
                "--speed-time", "60", "--speed-limit", "1024", "--continue-at", "-", "--output", partial.path, source])
        }
        report("Verifying \(artifact.file)")
        guard try CleanupFiles.verified(partial, artifact) else {
            throw CleanupEngineFailure("\(artifact.file) failed size/SHA-256 verification; it was not installed")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: file)
    }

    func extract(_ archive: URL, root: String) async throws -> URL {
        let parent = directory.appendingPathComponent("Binaries")
        try PrivateFiles.ensureDirectory(at: parent)
        let stage = parent.appendingPathComponent(".release-stage-\(UUID())")
        try PrivateFiles.ensureDirectory(at: stage)
        do {
            let data = try await system.checked("/usr/bin/gzip", ["-dc", archive.path], limit: CleanupArchive.maximumBytes + 1024 * 1024)
            try CleanupArchive.extract(data.output, to: stage, root: root)
            let candidate = stage.appendingPathComponent(root)
            guard try PrivateFiles.directoryExists(at: candidate) else { throw CleanupEngineFailure("Unexpected cleanup runtime archive layout") }
            return candidate
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }

    func verifyRuntime(_ runtime: URL) throws {
        // Reject redirected parents as well as a symlink at the runtime itself.
        _ = try PrivateFiles.directoryExists(at: directory.appendingPathComponent("Binaries"))
        guard try PrivateFiles.directoryExists(at: runtime) else { throw CleanupEngineFailure("Cleanup runtime is missing") }
        for (name, expected) in stack.llama_server.files_sha256.sorted(by: { $0.key < $1.key }) {
            let file = runtime.appendingPathComponent(name)
            guard CleanupFiles.contained(file, in: runtime),
                  (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  try CleanupFiles.digest(file) == expected else {
                throw CleanupEngineFailure("Release runtime file missing or changed: \(name). Run cleanup setup again.")
            }
        }
    }

    public func verify() async throws -> [String] {
        guard try PrivateFiles.directoryExists(at: directory) else { throw CleanupEngineFailure("Cleanup is not installed; run setup first") }
        for artifact in stack.artifacts.values {
            guard try CleanupFiles.verified(directory.appendingPathComponent(artifact.file), artifact) else {
                throw CleanupEngineFailure("Missing or unverified \(artifact.file); run cleanup setup first")
            }
        }
        return try await verifiedBinary(port: port)
    }
    func verifiedBinary(port: Int) async throws -> [String] {
        try verifyRuntime(runtime)
        let binary = runtime.appendingPathComponent(stack.llama_server.path)
        let environment = CleanupStack.runtimeEnvironment()
        let version = try await system.checked(binary.path, ["--version"], environment: environment).text
        guard version.contains(stack.llama_server.version), version.contains(stack.llama_server.commit) else {
            throw CleanupEngineFailure("llama.cpp version/commit does not match the pin")
        }
        let help = try await system.checked(binary.path, ["--help"], environment: environment).text
        let flags = stack.serverArguments(directory: directory, port: port)
        let required = flags.filter { $0.hasPrefix("--") } + ["draft-mtp", "mmap+mlock"]
        guard required.allSatisfy({ help.contains($0) }) else { throw CleanupEngineFailure("llama.cpp does not support the required cleanup flags") }
        return [binary.path] + flags
    }

    /// Writes a self-contained, signed native launcher and its accepted pin outside the app.
    func stageRunner() throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let lock = try encoder.encode(stack)
        let helper = try CleanupFiles.read(executable, limit: 100 * 1024 * 1024)
        var identity = Data(CleanupFiles.digest(helper).utf8); identity.append(lock)
        var files: [(String, Data)] = [("Resources/cleanup-stack.json", lock)]
        var resourcePaths = Self.resources
        let licenses = kit.appendingPathComponent("Licenses")
        if try PrivateFiles.directoryExists(at: licenses) {
            let hashes = try CleanupFiles.runtimeHashes(licenses)
            resourcePaths += hashes.keys.sorted().map { "Licenses/" + $0 }
        }
        for path in resourcePaths {
            let data = try CleanupFiles.read(kit.appendingPathComponent(path), limit: 1 << 20)
            identity.append(Data(path.utf8)); identity.append(Data(CleanupFiles.digest(data).utf8))
            files.append((path, data))
        }
        let runtimes = directory.appendingPathComponent("Runtimes")
        try PrivateFiles.ensureDirectory(at: runtimes)
        let runner = runtimes.appendingPathComponent(String(CleanupFiles.digest(identity).prefix(20)))
        try PrivateFiles.ensureDirectory(at: runner)
        for (name, contents) in [(Self.runnerName, helper)] + files {
            let file = runner.appendingPathComponent(name)
            try PrivateFiles.ensureDirectory(at: file.deletingLastPathComponent())
            if try PrivateFiles.regularFileExists(at: file) {
                guard try CleanupFiles.read(file, limit: 100 * 1024 * 1024) == contents else {
                    throw CleanupEngineFailure("Immutable cleanup runner changed")
                }
            } else { try PrivateFiles.writeAtomically(contents, to: file) }
            if name == Self.runnerName { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        }
        return runner.appendingPathComponent(Self.runnerName)
    }

    var domain: String { "gui/\(getuid())" }
    var serviceName: String { domain + "/" + CleanupEngineLauncher.label }
    func launchctl(_ arguments: [String]) async throws -> CleanupCommandResult {
        try await system.command("/bin/launchctl", arguments, nil, 1 << 20)
    }
    func stopOwned() async throws {
        guard try PrivateFiles.regularFileExists(at: agent) else { return }
        let value = try PropertyListSerialization.propertyList(from: CleanupFiles.read(agent, limit: 64 * 1024), format: nil) as? [String: Any]
        guard value?["Label"] as? String == CleanupEngineLauncher.label,
              value?["WhisprLiteOwner"] as? String == CleanupEngineLauncher.label,
              value?["WhisprLiteNativeRunner"] as? Bool == true else {
            throw CleanupEngineFailure("Refusing to replace or remove an unrecognised cleanup login item")
        }
        let state = try await launchctl(["print", serviceName])
        guard state.status == 0 else { return }
        let text = String(decoding: state.output, as: UTF8.self)
        let pattern = #"(?m)^\s*pid = ([0-9]+)\s*$"#
        let match = text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
        let pid = match.flatMap { $0.split(separator: "=").last }.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard try await launchctl(["bootout", serviceName]).status == 0 else {
            throw CleanupEngineFailure("Could not stop the existing cleanup service; it was preserved")
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            let running = try await launchctl(["print", serviceName]).status == 0
            let alive = pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false
            if !running && !alive { return }
            guard ContinuousClock.now < deadline else { throw CleanupEngineFailure("Timed out waiting for cleanup to stop; retry after it settles") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public func install() async throws {
        report("Checking the cleanup models and llama.cpp")
        _ = try await verify()
        let runner = try stageRunner()
        let previous = try PrivateFiles.regularFileExists(at: agent) ? CleanupFiles.read(agent, limit: 64 * 1024) : nil
        try await stopOwned()
        do {
            try CleanupPort.checkFree(port)
            try PrivateFiles.ensureDirectory(at: agent.deletingLastPathComponent())
            let plist: [String: Any] = ["Label": CleanupEngineLauncher.label,
                "WhisprLiteOwner": CleanupEngineLauncher.label, "WhisprLiteNativeRunner": true,
                "ProgramArguments": [runner.path, "run", "--directory", directory.path, "--port", String(port)],
                "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
                "EnvironmentVariables": ["GGML_METAL_RESIDENCY_KEEP_ALIVE_S": "86400"],
                "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
            try PrivateFiles.writeAtomically(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: agent)
            guard try await launchctl(["bootstrap", domain, agent.path]).status == 0 else {
                throw CleanupEngineFailure("Could not start the cleanup login item")
            }
            report("Starting cleanup and loading its model; this can take a few minutes")
            try await waitReady(port: port)
        } catch {
            // Finish compensation even when the request was cancelled mid-install.
            try await Task.detached {
                try await stopOwned()
                if let previous {
                    try PrivateFiles.writeAtomically(previous, to: agent)
                    guard try await launchctl(["bootstrap", domain, agent.path]).status == 0 else {
                        throw CleanupEngineFailure("Cleanup startup failed and its previous login item could not be restarted. The previous configuration was preserved.")
                    }
                } else if try PrivateFiles.regularFileExists(at: agent) { try FileManager.default.removeItem(at: agent) }
            }.value
            throw error
        }
        report("Cleanup is ready")
    }
    func waitReady(port: Int, timeout: Duration? = nil, process: Process? = nil) async throws {
        let deadline = ContinuousClock.now + (timeout ?? startupTimeout)
        repeat {
            try Task.checkCancellation()
            if let process, !process.isRunning { throw CleanupEngineFailure("Candidate llama.cpp exited during startup") }
            do { try await system.ready(port, stack.alias); return }
            catch is CancellationError { throw CancellationError() }
            catch { }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < deadline
        throw CleanupEngineFailure("Cleanup did not become ready before its startup deadline")
    }
    public func uninstall() async throws {
        try await stopOwned()
        if try PrivateFiles.regularFileExists(at: agent) { try FileManager.default.removeItem(at: agent) }
    }
    public func run() async throws -> Never {
        let arguments = try await verify()
        try CleanupPort.checkFree(port)
        let environment = CleanupStack.runtimeEnvironment().map { "\($0.key)=\($0.value)" }
        var argv = arguments.map { strdup($0) } + [nil]
        var env = environment.map { strdup($0) } + [nil]
        defer { for value in argv + env { free(value) } }
        // The helper handles cancellation during validation. The server needs normal signals.
        _ = signal(SIGTERM, SIG_DFL); _ = signal(SIGINT, SIG_DFL)
        argv.withUnsafeMutableBufferPointer { args in
            env.withUnsafeMutableBufferPointer { vars in _ = execve(arguments[0], args.baseAddress!, vars.baseAddress!) }
        }
        throw CleanupEngineFailure("Could not execute llama.cpp: \(String(cString: strerror(errno)))")
    }
    public func status() throws -> CleanupEngineReport {
        let previous = directory.appendingPathComponent("cleanup-stack.previous.json")
        return .init(status: .installed, current: stack.llama_server.description,
                     previous: try PrivateFiles.regularFileExists(at: previous) ? CleanupStack.readServer(previous).description : nil)
    }
}
