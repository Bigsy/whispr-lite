import Foundation
import Darwin
import WhisprLiteCore

/// The signed executable is also copied into the owned service folder. Only explicit CLI
/// or Settings actions install/download; login launches `run` against its immutable pin.
@main struct CleanupMain {
    static let usage = """
    Usage: Whispr Lite Cleanup COMMAND [OPTIONS]
    Commands: prepare, verify, install, uninstall, run, status,
              upgrade-check, upgrade-apply, upgrade-rollback
    Options: --directory PATH, --port 1024...65535, --settings-directory PATH,
             --rounds 1...10, --progress, --kit PATH
    """
    struct Options: Sendable {
        var command: String
        var kit: URL?
        var directory = CleanupService.defaultDirectory
        var settings = CleanupService.defaultDirectory.deletingLastPathComponent()
        var port: Int?
        var rounds = 3
        var progress = false
        init(_ arguments: [String]) throws {
            let commands = ["prepare", "verify", "install", "uninstall", "run", "status", "upgrade-check", "upgrade-apply", "upgrade-rollback"]
            guard let first = arguments.first, commands.contains(first) else { throw CleanupEngineFailure("Unknown or missing cleanup command") }
            command = first
            var index = 1, seen = Set<String>()
            while index < arguments.count {
                let option = arguments[index]
                guard seen.insert(option).inserted else { throw CleanupEngineFailure("Repeated cleanup option: \(option)") }
                if option == "--progress" { progress = true; index += 1; continue }
                guard ["--kit", "--directory", "--settings-directory", "--port", "--rounds"].contains(option),
                      index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                    throw CleanupEngineFailure("Invalid cleanup option: \(option)")
                }
                let value = arguments[index + 1]
                switch option {
                case "--kit": kit = Self.path(value)
                case "--directory": directory = Self.path(value)
                case "--settings-directory": settings = Self.path(value)
                case "--port":
                    guard let number = Int(value), (1024...65535).contains(number) else { throw CleanupEngineFailure("Port must be between 1024 and 65535") }
                    port = number
                case "--rounds":
                    guard let number = Int(value), (1...10).contains(number) else { throw CleanupEngineFailure("Rounds must be between 1 and 10") }
                    rounds = number
                default: break
                }
                index += 2
            }
        }
        static func path(_ value: String) -> URL {
            URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }
    }
    // An install/switch must finish if the app quits and closes its progress pipe.
    static func error(_ text: String) { try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8)) }
    static func main() async {
        _ = signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] { print(usage); return }
        let options: Options
        do { options = try Options(arguments) }
        catch {
            Self.error((error as? CleanupEngineFailure)?.message ?? "Invalid cleanup arguments")
            Self.error(usage); exit(2)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let parent = executable.deletingLastPathComponent()
        let kit = options.kit ?? (FileManager.default.fileExists(atPath: parent.appendingPathComponent("Resources/cleanup-stack.json").path)
            ? parent : parent.deletingLastPathComponent().appendingPathComponent("Resources/CleanupSetup"))
        do {
            let service = try CleanupService(kit: kit, executable: executable, directory: options.directory,
                port: options.port, useAcceptedBuild: options.command != "run") { progress in
                    guard options.progress else { return }
                    let fraction = progress.fraction.map { String(format: "[%.3f] ", $0) } ?? ""
                    Self.error("progress: \(fraction)\(progress.text)")
                }
            let operation = Task { try await service.perform(options.command, settingsDirectory: options.settings, rounds: options.rounds) }
            _ = signal(SIGTERM, SIG_IGN); _ = signal(SIGINT, SIG_IGN)
            let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { @Sendable in operation.cancel() }; source.resume(); return source
            }
            defer { sources.forEach { $0.cancel() } }
            if let result = try await operation.value {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                var object = try JSONSerialization.jsonObject(with: encoder.encode(result)) as! [String: Any]
                object["schema"] = 1
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
        } catch is CancellationError { exit(143) }
        catch {
            let message = (error as? CleanupEngineFailure)?.message ?? "Cleanup operation failed (\(type(of: error)))"
            Self.error("Cleanup setup failed: \(message)"); exit(1)
        }
    }
}
