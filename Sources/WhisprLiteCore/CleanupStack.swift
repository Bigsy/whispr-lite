import Foundation
import CryptoKit
import Darwin

/// The same pins as the developer tools, also copied into each immutable native runner.
struct CleanupStack: Codable, Sendable {
    struct Artifact: Codable, Sendable {
        var file: String
        var bytes: Int64
        var sha256: String
    }
    struct Release: Codable, Sendable {
        var file: String
        var bytes: Int64
        var sha256: String
        var url: String
        var tag: String
        var directory: String
        var artifact: Artifact { .init(file: file, bytes: bytes, sha256: sha256) }
    }
    struct Server: Codable, Sendable {
        var path: String
        var version: String
        var commit: String
        var sha256: String
        var revision: String
        var minimum_macos: String
        var release: Release
        var files_sha256: [String: String]

        var buildNumber: Int { Int(release.tag.dropFirst()) ?? -1 }
        var description: CleanupBuild { .init(tag: release.tag, version: version) }
        func validate() throws {
            guard path == "llama-server", CleanupFiles.matches(version, #"^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*$"#),
                  CleanupFiles.matches(commit, #"^[0-9a-f]{7,40}$"#),
                  CleanupFiles.matches(revision, #"^[0-9a-f]{40}$"#), revision.hasPrefix(commit),
                  CleanupFiles.matches(release.tag, #"^b[0-9]+$"#), buildNumber > 0,
                  release.directory == "llama-\(release.tag)",
                  release.file == "llama-\(release.tag)-bin-macos-arm64.tar.gz",
                  release.url == "https://github.com/ggml-org/llama.cpp/releases/download/\(release.tag)/\(release.file)",
                  release.bytes > 0, release.bytes <= 200 * 1024 * 1024,
                  CleanupFiles.validDigest(release.sha256), CleanupFiles.validDigest(sha256),
                  CleanupFiles.matches(minimum_macos, #"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$"#),
                  !files_sha256.isEmpty, files_sha256.count <= 500, files_sha256[path] == sha256,
                  files_sha256.allSatisfy({ CleanupFiles.safeRelativePath($0.key) && CleanupFiles.validDigest($0.value) })
            else { throw CleanupEngineFailure("Invalid llama.cpp runtime pin") }
        }
    }
    /// A cleanup model the user can install in place of the default one. It shares the
    /// llama.cpp runtime and port, and has its own files, alias and prompt format.
    struct Alternative: Codable, Sendable {
        var name: String
        var repository: String
        var revision: String
        var artifacts: [String: Artifact]
        var alias: String
        var format: String
    }
    /// The id of the model described by the top-level fields of the bundled stack.
    static let defaultModel = "gemma-4-e2b"
    static let defaultName = "Gemma 4 E2B"
    var schema: Int
    var repository: String
    var revision: String
    var artifacts: [String: Artifact]
    var llama_server: Server
    var port: Int
    var alias: String
    /// Display name, prompt format and id of the selected model; absent for the default one.
    var name: String? = nil
    var format: String? = nil
    var model: String? = nil
    /// The alternatives by id. A staged runner's pin holds only its selected model.
    var models: [String: Alternative]? = nil

    var promptFormat: CleanupPromptFormat { format.flatMap(CleanupPromptFormat.init(rawValue:)) ?? .chat }
    /// Files in download order: the model, then its optional speculative drafter.
    var files: [Artifact] { ["model", "drafter"].compactMap { artifacts[$0] } }

    static func load(_ file: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: CleanupFiles.read(file, limit: 1 << 20))
        try value.validate()
        return value
    }
    private static func validModel(repository: String, revision: String, artifacts: [String: Artifact],
                                   alias: String, format: String?) -> Bool {
        !alias.isEmpty && alias.utf8.count <= 128
            && CleanupFiles.matches(repository, #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#)
            && CleanupFiles.matches(revision, #"^[0-9a-f]{40}$"#)
            && (Set(artifacts.keys) == ["model", "drafter"] || Set(artifacts.keys) == ["model"])
            && artifacts.values.allSatisfy({ CleanupFiles.safeName($0.file) && $0.bytes > 0
                && $0.bytes <= 20_000_000_000 && CleanupFiles.validDigest($0.sha256) })
            && Set(artifacts.values.map(\.file)).count == artifacts.count
            && (format.map { CleanupPromptFormat(rawValue: $0) != nil } ?? true)
    }
    func validate() throws {
        guard schema == 1, (1024...65535).contains(port),
              Self.validModel(repository: repository, revision: revision, artifacts: artifacts, alias: alias, format: format),
              (name ?? "x").utf8.count <= 128, !(name ?? "x").isEmpty, model.map(CleanupFiles.safeName) ?? true,
              (models ?? [:]).count <= 16, (models ?? [:]).allSatisfy({ id, value in
                  CleanupFiles.safeName(id) && id != Self.defaultModel && !value.name.isEmpty && value.name.utf8.count <= 128
                      && Self.validModel(repository: value.repository, revision: value.revision,
                                         artifacts: value.artifacts, alias: value.alias, format: value.format)
              })
        else { throw CleanupEngineFailure("Invalid cleanup model pin") }
        // Models share the folder, so a file name may belong to only one of them.
        let names = files.map(\.file) + (models ?? [:]).values.flatMap { $0.artifacts.values.map(\.file) }
        guard Set(names).count == names.count else { throw CleanupEngineFailure("Invalid cleanup model pin") }
        try llama_server.validate()
    }
    /// This stack with one model selected: the default one, or an alternative by id.
    /// A runner's pin already holds its selection and accepts only that id.
    func selecting(_ id: String?) throws -> Self {
        guard let id, id != (model ?? Self.defaultModel) else { return self }
        guard model == nil, let choice = models?[id] else {
            throw CleanupEngineFailure("This version of Whispr Lite does not know the cleanup model \"\(id)\". Use Install… in Settings.")
        }
        var result = self
        result.repository = choice.repository; result.revision = choice.revision
        result.artifacts = choice.artifacts; result.alias = choice.alias
        result.name = choice.name; result.format = choice.format; result.model = id; result.models = nil
        try result.validate()
        return result
    }
    /// The model the installed service was last switched to, recorded beside its accepted build.
    static func acceptedModel(in directory: URL) throws -> String? {
        let file = directory.appendingPathComponent("cleanup-model.json")
        guard try PrivateFiles.regularFileExists(at: file) else { return nil }
        struct Accepted: Decodable { let model: String }
        guard let accepted = try? JSONDecoder().decode(Accepted.self, from: CleanupFiles.read(file, limit: 4096)),
              CleanupFiles.safeName(accepted.model) else { throw CleanupEngineFailure("Invalid cleanup model record") }
        return accepted.model
    }
    func acceptModel(in directory: URL) throws {
        try CleanupFiles.write(["model": model ?? Self.defaultModel], to: directory.appendingPathComponent("cleanup-model.json"))
    }
    func effective(in directory: URL) throws -> Self {
        let file = directory.appendingPathComponent("cleanup-stack.local.json")
        guard try PrivateFiles.regularFileExists(at: file) else { return self }
        let server = try Self.readServer(file)
        guard server.buildNumber > llama_server.buildNumber else { return self }
        var result = self; result.llama_server = server
        return result
    }
    static func readServer(_ file: URL) throws -> Server {
        let block = try JSONDecoder().decode(Server.self, from: CleanupFiles.read(file, limit: 1 << 20))
        try block.validate()
        return block
    }
    func serverArguments(directory: URL, port: Int) -> [String] {
        // Multi-token prediction needs the model's own drafter; a model without one runs plain.
        let speculation = artifacts["drafter"].map {
            ["--spec-type", "draft-mtp", "-md", directory.appendingPathComponent($0.file).path,
             "--spec-draft-n-max", "6", "--swa-full"]
        } ?? []
        return ["-m", directory.appendingPathComponent(artifacts["model"]!.file).path] + speculation
            + ["-c", "4096", "-np", "1", "-fa", "on",
               "--load-mode", "mmap+mlock", "--reasoning", "off", "--temp", "0",
               "--alias", alias, "--host", "127.0.0.1", "--port", String(port),
               "--no-webui", "--no-slots", "--no-context-shift",
               "--cors-origins", "http://127.0.0.1:\(port)", "--log-disable"]
    }
    static func runtimeEnvironment(_ supplied: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = supplied.filter { !$0.key.hasPrefix("LLAMA_ARG_") && !$0.key.hasPrefix("DYLD_") }
        result["GGML_METAL_RESIDENCY_KEEP_ALIVE_S"] = "86400"
        return result
    }
}

enum CleanupFiles {
    static func matches(_ value: String, _ expression: String) -> Bool {
        value.range(of: expression, options: .regularExpression) != nil
    }
    static func validDigest(_ value: String) -> Bool { matches(value, #"^[0-9a-f]{64}$"#) }
    static func safeName(_ value: String) -> Bool { matches(value, #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#) }
    static func safeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\0")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
    static func read(_ file: URL, limit: Int) throws -> Data {
        guard try PrivateFiles.regularFileExists(at: file),
              try size(file) <= limit
        else { throw CleanupEngineFailure("Missing or oversized cleanup file: \(file.lastPathComponent)") }
        return try Data(contentsOf: file)
    }
    /// URL resource values can cache the size across a resumed download. Always stat it.
    static func size(_ file: URL) throws -> Int64 {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CleanupEngineFailure("Missing or non-regular cleanup file: \(file.lastPathComponent)")
        }
        return info.st_size
    }
    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func verified(_ file: URL, _ artifact: CleanupStack.Artifact) throws -> Bool {
        guard try PrivateFiles.regularFileExists(at: file) else { return false }
        return try size(file) == artifact.bytes
            && digest(file) == artifact.sha256
    }
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFiles.writeAtomically(encoder.encode(value), to: file)
    }
    static func contained(_ file: URL, in root: URL) -> Bool {
        file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }
    static func runtimeHashes(_ runtime: URL) throws -> [String: String] {
        var hashes: [String: String] = [:], count = 0
        guard let enumerator = FileManager.default.enumerator(at: runtime, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else {
            throw CleanupEngineFailure("Could not inspect the cleanup runtime")
        }
        for case let path as URL in enumerator {
            count += 1
            guard count <= 500, contained(path, in: runtime) else { throw CleanupEngineFailure("Unsafe cleanup runtime layout") }
            let values = try path.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw CleanupEngineFailure("Unsupported cleanup runtime file") }
            let relative = String(path.path.dropFirst(runtime.path.count + 1))
            hashes[relative] = try digest(path)
        }
        return hashes
    }
}

/// Serialises setup and upgrades across app instances and CLI invocations. Never waits.
final class CleanupOperationLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        try PrivateFiles.ensureDirectory(at: directory)
        descriptor = open(directory.appendingPathComponent(".setup.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CleanupEngineFailure("Could not lock the cleanup folder") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CleanupEngineFailure("Another cleanup setup or update is running. Try again when it finishes.")
        }
    }
    deinit { close(descriptor) }
}
