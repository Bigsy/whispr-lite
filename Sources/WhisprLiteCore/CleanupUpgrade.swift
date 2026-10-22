import Foundation
import Darwin

struct CleanupGitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        var name: String
        var size: Int64
        var digest: String?
        var browser_download_url: String
    }
    var tag_name: String
    var assets: [Asset]
    static func newest(_ values: [Self]) -> CleanupStack.Release? {
        values.compactMap { value -> CleanupStack.Release? in
            guard CleanupFiles.matches(value.tag_name, #"^b[0-9]+$"#), Int(value.tag_name.dropFirst()) != nil else { return nil }
            let name = "llama-\(value.tag_name)-bin-macos-arm64.tar.gz"
            let url = "https://github.com/ggml-org/llama.cpp/releases/download/\(value.tag_name)/\(name)"
            guard let asset = value.assets.first(where: { $0.name == name && $0.browser_download_url == url
                && $0.size > 0 && $0.size <= 200 * 1024 * 1024
                && $0.digest?.hasPrefix("sha256:") == true && CleanupFiles.validDigest(String($0.digest!.dropFirst(7))) }) else { return nil }
            return .init(file: name, bytes: asset.size, sha256: String(asset.digest!.dropFirst(7)),
                         url: url, tag: value.tag_name, directory: "llama-\(value.tag_name)")
        }.max { (Int($0.tag.dropFirst()) ?? -1) < (Int($1.tag.dropFirst()) ?? -1) }
    }
}

enum CleanupMachO {
    static func minimumOS(_ data: Data) throws -> String {
        func word(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        guard data.count >= 32, word(0) == 0xFEEDFACF, word(4) == 0x0100000C else {
            throw CleanupEngineFailure("The cleanup runtime is not an arm64 Mach-O executable")
        }
        var offset = 32
        guard word(16) <= 4096 else { throw CleanupEngineFailure("Invalid cleanup Mach-O header") }
        for _ in 0..<word(16) {
            guard offset + 8 <= data.count else { break }
            let command = word(offset), size = Int(word(offset + 4))
            guard size >= 8, offset + size <= data.count else { break }
            if command == 0x32 && size >= 24 || command == 0x24 && size >= 16 {
                guard command != 0x32 || word(offset + 8) == 1 else {
                    throw CleanupEngineFailure("The cleanup runtime does not target macOS")
                }
                let value = word(offset + (command == 0x32 ? 12 : 8))
                return "\(value >> 16).\((value >> 8) & 0xff).\(value & 0xff)"
            }
            offset += size
        }
        throw CleanupEngineFailure("The cleanup runtime has no supported minimum macOS version")
    }
    static func supports(_ minimum: String, current: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        let needed = minimum.split(separator: ".").compactMap { Int($0) }
        guard (2...3).contains(needed.count) else { return false }
        return ![current.majorVersion, current.minorVersion, current.patchVersion]
            .lexicographicallyPrecedes(needed + Array(repeating: 0, count: 3 - needed.count))
    }
}

/// Owns a temporary candidate only. Installed services are always managed through launchctl.
private final class CleanupCandidate: @unchecked Sendable {
    let process = Process()
    init(_ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: arguments[0]); process.arguments = Array(arguments.dropFirst())
        process.environment = CleanupStack.runtimeEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func stop() {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

extension CleanupService {
    public func perform(_ command: String, settingsDirectory: URL? = nil, rounds: Int = 3) async throws -> CleanupEngineReport? {
        guard (1...10).contains(rounds) else { throw CleanupEngineFailure("Rounds must be between 1 and 10") }
        let exclusive = ["prepare", "install", "uninstall", "upgrade-check", "upgrade-apply", "upgrade-rollback"].contains(command)
            ? try CleanupOperationLock(directory: directory) : nil
        defer { withExtendedLifetime(exclusive) {} }
        switch command {
        case "prepare": try await prepare()
        case "verify": _ = try await verify()
        case "install": try await install()
        case "uninstall": try await uninstall()
        case "run": try await run()
        case "status": return try status()
        case "upgrade-check": return try await checkUpgrade(settingsDirectory: settingsDirectory ?? directory.deletingLastPathComponent(), rounds: rounds)
        case "upgrade-apply": return try await applyUpgrade()
        case "upgrade-rollback":
            let file = directory.appendingPathComponent("cleanup-stack.previous.json")
            guard try PrivateFiles.regularFileExists(at: file) else { throw CleanupEngineFailure("No previous cleanup build to roll back to") }
            return try await switchBuild(CleanupStack.readServer(file))
        default: throw CleanupEngineFailure("Unknown cleanup command")
        }
        return nil
    }

    func github<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let result = try await system.checked("/usr/bin/curl", ["--fail", "--location", "--show-error", "--silent",
            "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "20", "--max-time", "30",
            "--header", "Accept: application/vnd.github+json", "https://api.github.com/repos/ggml-org/llama.cpp" + path], limit: 6 << 20)
        return try JSONDecoder().decode(type, from: result.output)
    }

    func candidateBlock(runtime: URL, release: CleanupStack.Release, revision: String) async throws -> CleanupStack.Server {
        let file = runtime.appendingPathComponent("llama-server")
        guard CleanupFiles.contained(file, in: runtime), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CleanupEngineFailure("Release archive has no llama-server")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let minimum = try CleanupMachO.minimumOS(handle.read(upToCount: 65536) ?? Data())
        guard CleanupMachO.supports(minimum) else { throw CleanupEngineFailure("\(release.tag) needs macOS \(minimum) or later") }
        let result = try await system.checked(file.path, ["--version"], environment: CleanupStack.runtimeEnvironment())
        let expression = try NSRegularExpression(pattern: #"version: (\S+) \(build ([0-9]+), commit ([0-9a-f]+)\)"#)
        let text = result.text
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let versionRange = Range(match.range(at: 1), in: text),
              let numberRange = Range(match.range(at: 2), in: text),
              let commitRange = Range(match.range(at: 3), in: text),
              "b" + text[numberRange] == release.tag, revision.hasPrefix(String(text[commitRange])) else {
            throw CleanupEngineFailure("Release version does not match its tag and commit")
        }
        let hashes = try CleanupFiles.runtimeHashes(runtime)
        var block = CleanupStack.Server(path: "llama-server", version: String(text[versionRange]), commit: String(text[commitRange]),
            sha256: hashes["llama-server"] ?? "", revision: revision, minimum_macos: minimum, release: release, files_sha256: hashes)
        block.release.directory = "llama-\(release.tag)"
        try block.validate()
        return block
    }

    func prepareCandidate(_ release: CleanupStack.Release) async throws -> CleanupStack.Server {
        let binaries = directory.appendingPathComponent("Binaries")
        try PrivateFiles.ensureDirectory(at: binaries)
        let archive = binaries.appendingPathComponent(release.file)
        try await fetch(release.artifact, from: release.url, to: archive)
        struct Commit: Decodable { var sha: String }
        let revision = try await github("/commits/\(release.tag)", as: Commit.self).sha
        let staged = try await extract(archive, root: release.directory)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let block = try await candidateBlock(runtime: staged, release: release, revision: revision)
        let target = binaries.appendingPathComponent(release.directory)
        if try PrivateFiles.directoryExists(at: target) {
            var candidate = self; candidate.stack.llama_server = block
            try candidate.verifyRuntime(target)
        } else { try FileManager.default.moveItem(at: staged, to: target) }
        return block
    }

    func checkUpgrade(settingsDirectory: URL, rounds: Int) async throws -> CleanupEngineReport {
        report("Checking GitHub for llama.cpp builds…")
        guard let release = CleanupGitHubRelease.newest(try await github("/releases?per_page=20", as: [CleanupGitHubRelease].self)) else {
            throw CleanupEngineFailure("No llama.cpp build with a verified macOS arm64 archive was found")
        }
        guard (Int(release.tag.dropFirst()) ?? -1) > stack.llama_server.buildNumber else {
            return .init(status: .upToDate, current: stack.llama_server.description, newest: release.tag)
        }
        try await waitReady(port: port, timeout: .seconds(15))
        let block = try await prepareCandidate(release)
        let comparison = try await compareCandidate(block, settingsDirectory: settingsDirectory, rounds: rounds)
        try CleanupFiles.write(block, to: directory.appendingPathComponent("upgrade-candidate.json"))
        let previous = try status().previous?.tag
        try prune(keeping: Set([stack.llama_server.release.tag, block.release.tag] + (previous.map { [$0] } ?? [])))
        return comparison
    }

    func compareCandidate(_ block: CleanupStack.Server, settingsDirectory: URL, rounds: Int) async throws -> CleanupEngineReport {
        var candidate = self; candidate.stack.llama_server = block
        let candidatePort = port == 11437 ? 11438 : 11437
        let arguments = try await candidate.verifiedBinary(port: candidatePort)
        try CleanupPort.checkFree(candidatePort)
        report("Starting \(block.release.tag) beside the running service…")
        let server = try CleanupCandidate(arguments)
        defer { server.stop() }
        try await candidate.waitReady(port: candidatePort, process: server.process)
        return try await compare(block: block, candidatePort: candidatePort, settingsDirectory: settingsDirectory, rounds: rounds)
    }

    struct Fixture: Decodable, Sendable { var id: String; var raw: String }
    func compare(block: CleanupStack.Server, candidatePort: Int, settingsDirectory: URL, rounds: Int) async throws -> CleanupEngineReport {
        let saved = try await MainActor.run {
            let store = try SettingsStore(directory: settingsDirectory)
            return (store.preferences, try store.prompt(), try store.privateText(.dictionary) ?? "")
        }
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: CleanupFiles.read(kit.appendingPathComponent("Resources/cleanup-fixtures.json"), limit: 1 << 20))
        guard !fixtures.isEmpty, fixtures.count <= 256, Set(fixtures.map(\.id)).count == fixtures.count else {
            throw CleanupEngineFailure("Invalid synthetic cleanup comparison fixtures")
        }
        let clients = try [port, candidatePort].map { port -> HTTPCleanup in
            var preferences = saved.0; preferences.cleanupEndpoint = "http://127.0.0.1:\(port)"
            var configuration = try CleanupConfiguration(preferences: preferences, prompt: saved.1, dictionary: saved.2)
            configuration.model = stack.alias
            return HTTPCleanup(configuration)
        }
        for client in clients { try await client.preparePrefix() }
        var timings: [[Double]] = [[], []], outputs: [[String: String]] = [[:], [:]]
        for round in 0...rounds {
            let order = round % 2 == 0 ? [0, 1] : [1, 0]
            for (index, fixture) in fixtures.enumerated() {
                for which in order {
                    try Task.checkCancellation()
                    let start = ContinuousClock.now
                    let output = try await withDeadline(.seconds(30), stage: "Cleanup comparison") { try await clients[which].clean(fixture.raw) }
                    let elapsed = start.duration(to: .now).milliseconds
                    if let previous = outputs[which][fixture.id], previous != output {
                        throw CleanupEngineFailure("Cleanup output varied between repetitions; candidate was not accepted")
                    }
                    outputs[which][fixture.id] = output
                    if round > 0 { timings[which].append(elapsed) }
                }
                report("Comparing outputs: \(round * fixtures.count + index + 1) of \((rounds + 1) * fixtures.count)")
            }
        }
        let differences = fixtures.compactMap { fixture -> CleanupDifference? in
            let current = outputs[0][fixture.id]!, proposed = outputs[1][fixture.id]!
            return current == proposed ? nil : .init(fixture: fixture.id, input: fixture.raw, current: current, candidate: proposed)
        }
        // A model must not echo a private system prompt/dictionary into a public comparison.
        try Self.checkPrivate(differences, forbidden: [saved.1, saved.2])
        func describe(_ server: CleanupStack.Server, _ values: [Double]) -> CleanupBuild {
            let sorted = values.sorted(), count = sorted.count
            let median = (sorted[(count - 1) / 2] + sorted[count / 2]) / 2
            let p90 = sorted[max(0, Int(ceil(Double(count) * 0.9)) - 1)]
            return .init(tag: server.release.tag, version: server.version,
                         medianMilliseconds: (median * 10).rounded() / 10, p90Milliseconds: (p90 * 10).rounded() / 10)
        }
        return .init(status: .candidate, current: describe(stack.llama_server, timings[0]),
                     candidate: describe(block, timings[1]), fixtures: fixtures.count, differences: differences)
    }
    static func checkPrivate(_ differences: [CleanupDifference], forbidden: [String]) throws {
        for value in forbidden where value.count >= 16 {
            guard !differences.contains(where: { [$0.input, $0.current, $0.candidate].contains(where: { $0.contains(value) }) }) else {
                throw CleanupEngineFailure("Comparison result contained private cleanup text; result was discarded")
            }
        }
    }

    func applyUpgrade() async throws -> CleanupEngineReport {
        let file = directory.appendingPathComponent("upgrade-candidate.json")
        guard try PrivateFiles.regularFileExists(at: file) else { throw CleanupEngineFailure("No checked candidate; run Check for update first") }
        let block = try CleanupStack.readServer(file)
        guard block.buildNumber > stack.llama_server.buildNumber else {
            try FileManager.default.removeItem(at: file)
            throw CleanupEngineFailure("The checked build is no newer than the one installed; check again")
        }
        let result = try await switchBuild(block)
        try FileManager.default.removeItem(at: file)
        return result
    }
    func switchBuild(_ block: CleanupStack.Server) async throws -> CleanupEngineReport {
        try block.validate()
        let local = directory.appendingPathComponent("cleanup-stack.local.json")
        let previous = directory.appendingPathComponent("cleanup-stack.previous.json")
        let saved = try [local, previous].map { file in
            try PrivateFiles.regularFileExists(at: file) ? CleanupFiles.read(file, limit: 1 << 20) : nil
        }
        report("Restarting cleanup with \(block.release.tag)…")
        do {
            try CleanupFiles.write(stack.llama_server, to: previous)
            try CleanupFiles.write(block, to: local)
            var changed = self; changed.stack.llama_server = block
            try await changed.install()
        } catch {
            for (file, contents) in zip([local, previous], saved) {
                if let contents { try PrivateFiles.writeAtomically(contents, to: file) }
                else if try PrivateFiles.regularFileExists(at: file) { try FileManager.default.removeItem(at: file) }
            }
            throw error
        }
        let candidate = directory.appendingPathComponent("upgrade-candidate.json")
        let checked = try PrivateFiles.regularFileExists(at: candidate) ? CleanupStack.readServer(candidate).release.tag : nil
        try prune(keeping: Set([block.release.tag, stack.llama_server.release.tag] + (checked.map { [$0] } ?? [])))
        return .init(status: .switched, current: block.description, previous: stack.llama_server.description)
    }
    func prune(keeping tags: Set<String>) throws {
        let binaries = directory.appendingPathComponent("Binaries")
        guard try PrivateFiles.directoryExists(at: binaries) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: binaries, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let name = file.lastPathComponent
            guard CleanupFiles.matches(name, #"^llama-b[0-9]+(?:-bin-macos-arm64\.tar\.gz(?:\.partial)?)?$"#),
                  (try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let number = name.dropFirst("llama-b".count).prefix { $0.isNumber }
            if !tags.contains("b" + number) { try FileManager.default.removeItem(at: file) }
        }
    }
}
