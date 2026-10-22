import Foundation

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

    private static func helper(in kit: URL) -> URL {
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

    /// Bytes a fresh `prepare` downloads: every pinned model and the llama.cpp release.
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
    public func run(_ step: Step, progress: @escaping @Sendable (CleanupSetupProgress) -> Void) async throws {
        let options = try Self.installedOptions(agent: agent)
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
