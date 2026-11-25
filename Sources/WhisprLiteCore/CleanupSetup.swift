import Foundation

/// One cleanup model the bundled kit can install, for Settings.
public struct CleanupModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// The name the service answers to, and how requests to it are framed.
    public let alias: String
    public let format: CleanupPromptFormat
    /// The model's own files. llama.cpp is shared between models.
    public let modelBytes: Int64
    /// Everything a fresh install of this model downloads, llama.cpp included.
    public let downloadBytes: Int64
    /// Fixed-prompt fine-tunes take the dictionary but ignore the user's additional instructions.
    public var followsInstructions: Bool { format == .chat }

    public init(id: String, name: String, alias: String, format: CleanupPromptFormat, modelBytes: Int64, downloadBytes: Int64) {
        self.id = id; self.name = name; self.alias = alias; self.format = format
        self.modelBytes = modelBytes; self.downloadBytes = downloadBytes
    }
}

/// Runs the signed native cleanup helper. It needs only the app and macOS's standard tools;
/// no interpreter, developer tools or source checkout is used on an installed Mac.
public struct CleanupSetup: Equatable, Sendable {
    public enum Step: String, Sendable { case prepare, install }

    public let executable: URL
    public let kit: URL
    private let agent: URL

    public init(kit: URL, agent: URL = CleanupEngineLauncher.agent) {
        self.kit = kit
        self.agent = agent
        executable = Self.helper(in: kit)
    }

    static func helper(in kit: URL) -> URL {
        let standalone = kit.appendingPathComponent(CleanupService.runnerName)
        if FileManager.default.isExecutableFile(atPath: standalone.path) { return standalone }
        return kit.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/\(CleanupService.runnerName)")
    }
    /// The bundled resources and executable must both be present.
    public static func kit(resources: URL?) -> URL? {
        guard let kit = resources?.appendingPathComponent("CleanupSetup") else { return nil }
        let required = ["Resources/cleanup-stack.json"] + CleanupService.resources
        return FileManager.default.isExecutableFile(atPath: helper(in: kit).path)
            && required.allSatisfy { FileManager.default.fileExists(atPath: kit.appendingPathComponent($0).path) } ? kit : nil
    }

    /// The cleanup models this kit can install: the default first, then the others by name.
    public static func models(kit: URL) -> [CleanupModelOption] {
        guard let base = try? CleanupStack.load(kit.appendingPathComponent("Resources/cleanup-stack.json")) else { return [] }
        let ids = [CleanupStack.defaultModel] + (base.models ?? [:]).sorted { $0.value.name < $1.value.name }.map(\.key)
        return ids.compactMap { id in
            guard let stack = try? base.selecting(id) else { return nil }
            let bytes = stack.files.reduce(0) { $0 + $1.bytes }
            return .init(id: id, name: stack.name ?? CleanupStack.defaultName, alias: stack.alias, format: stack.promptFormat,
                         modelBytes: bytes, downloadBytes: bytes + stack.llama_server.release.bytes)
        }
    }

    /// Bytes a fresh `prepare` of the default model downloads: its files and the llama.cpp release.
    public static func downloadBytes(kit: URL) -> Int64? {
        struct Lock: Decodable {
            struct Artifact: Decodable { let bytes: Int64 }
            struct Server: Decodable { let release: Artifact }
            let artifacts: [String: Artifact]
            let server: Server
            enum CodingKeys: String, CodingKey { case artifacts, server = "llama_server" }
        }
        guard let data = try? Data(contentsOf: kit.appendingPathComponent("Resources/cleanup-stack.json")),
              let lock = try? JSONDecoder().decode(Lock.self, from: data) else { return nil }
        return lock.artifacts.values.reduce(lock.server.release.bytes) { $0 + $1.bytes }
    }

    /// Whispr Lite's cleanup login item exists; the service may still be starting or stopped.
    public static func isInstalled(agent: URL = CleanupEngineLauncher.agent) -> Bool {
        FileManager.default.fileExists(atPath: agent.path)
    }

    /// The model Whispr Lite's installed service runs: the one its last install recorded, or
    /// the default for a service installed before there was a choice. Nil when no service of
    /// ours is installed or this kit does not know its model.
    public static func installedModel(kit: URL, agent: URL = CleanupEngineLauncher.agent) -> CleanupModelOption? {
        guard let options = try? installedOptions(agent: agent), options.count == 4,
              let id = try? CleanupStack.acceptedModel(in: URL(fileURLWithPath: options[1])) ?? CleanupStack.defaultModel
        else { return nil }
        return models(kit: kit).first { $0.id == id }
    }

    /// Reinstall an owned native service using its model directory and port.
    /// Never infer arguments from a foreign or malformed launch command.
    static func installedOptions(agent: URL) throws -> [String] {
        guard try PrivateFiles.regularFileExists(at: agent) else { return [] }
        let data = try CleanupFiles.read(agent, limit: 64 * 1024)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == CleanupEngineLauncher.label,
              plist["WhisprLiteOwner"] as? String == CleanupEngineLauncher.label,
              plist["WhisprLiteNativeRunner"] as? Bool == true else {
            throw CleanupEngineFailure("Refusing to replace an unrecognised cleanup login item")
        }
        guard let arguments = plist["ProgramArguments"] as? [String], arguments.count == 6, arguments[1] == "run" else {
            throw CleanupEngineFailure("Existing cleanup service arguments are invalid")
        }
        let options = Array(arguments.dropFirst(2))
        var values: [String: String] = [:]
        for offset in stride(from: 0, to: options.count, by: 2) {
            guard ["--directory", "--port"].contains(options[offset]), values[options[offset]] == nil else {
                throw CleanupEngineFailure("Existing cleanup service arguments are invalid")
            }
            values[options[offset]] = options[offset + 1]
        }
        guard let directory = values["--directory"], directory.hasPrefix("/"),
              let text = values["--port"], let port = Int(text), (1024...65535).contains(port) else {
            throw CleanupEngineFailure("Existing cleanup folder or port is invalid")
        }
        return ["--directory", directory, "--port", String(port)]
    }

    /// Runs one step to completion. Cancelling stops it: `prepare` keeps partial downloads for
    /// the next attempt. The helper never writes into the signed app bundle.
    /// `model` is a cleanup model id from `models(kit:)`; nil keeps the installed one, or the
    /// default on a first install.
    public func run(_ step: Step, model: String? = nil,
                    progress: @escaping @Sendable (CleanupSetupProgress) -> Void) async throws {
        let options = try Self.installedOptions(agent: agent) + (model.map { ["--model", $0] } ?? [])
        _ = try await LauncherRun(executable: executable, arguments: [step.rawValue, "--kit", kit.path, "--progress"] + options,
                                  progress: { progress(CleanupSetupProgress(line: $0)) }).run()
    }
}

/// One `progress: [fraction] text` line from the setup script; the fraction is optional.
public struct CleanupSetupProgress: Equatable, Sendable {
    public let fraction: Double?
    public let text: String

    public init(fraction: Double?, text: String) { self.fraction = fraction; self.text = text }

    init(line: String) {
        if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
           let value = Double(line[line.index(after: line.startIndex)..<close]), (0...1).contains(value) {
            fraction = value
            text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        } else {
            fraction = nil; text = line
        }
    }
}
