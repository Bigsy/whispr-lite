import Foundation

/// The cleanup service's llama.cpp build commands, run for Settings > Advanced. The commands
/// go to the launcher the cleanup LaunchAgent starts, with the same directory and port, so a
/// check or switch acts on exactly the runner and models the service uses.
public enum CleanupEngineCommand: String, Sendable, CaseIterable {
    case status
    case check = "upgrade-check"
    case apply = "upgrade-apply"
    case rollback = "upgrade-rollback"
}

public struct CleanupBuild: Codable, Equatable, Sendable {
    public let tag: String
    public let version: String
    /// Cleanup request timings from a comparison; absent outside a check.
    public let medianMilliseconds: Double?
    public let p90Milliseconds: Double?

    private enum CodingKeys: String, CodingKey {
        case tag, version, medianMilliseconds = "median_ms", p90Milliseconds = "p90_ms"
    }

    public init(tag: String, version: String, medianMilliseconds: Double? = nil, p90Milliseconds: Double? = nil) {
        self.tag = tag; self.version = version
        self.medianMilliseconds = medianMilliseconds; self.p90Milliseconds = p90Milliseconds
    }
}

/// One synthetic dictation that the installed and candidate builds cleaned differently.
public struct CleanupDifference: Codable, Equatable, Sendable, Identifiable {
    public let fixture: String
    public let input: String
    public let current: String
    public let candidate: String
    public var id: String { fixture }

    public init(fixture: String, input: String, current: String, candidate: String) {
        self.fixture = fixture; self.input = input; self.current = current; self.candidate = candidate
    }
}

public struct CleanupEngineReport: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case installed, upToDate = "up-to-date", candidate, switched
    }
    public let status: Status
    public let current: CleanupBuild
    public let previous: CleanupBuild?
    public let candidate: CleanupBuild?
    /// The newest published build, when a check found nothing newer.
    public let newest: String?
    public let fixtures: Int?
    public let differences: [CleanupDifference]

    private enum CodingKeys: String, CodingKey {
        case status, current, previous, candidate, newest, fixtures, differences
    }

    public init(status: Status, current: CleanupBuild, previous: CleanupBuild? = nil, candidate: CleanupBuild? = nil,
                newest: String? = nil, fixtures: Int? = nil, differences: [CleanupDifference] = []) {
        self.status = status; self.current = current; self.previous = previous; self.candidate = candidate
        self.newest = newest; self.fixtures = fixtures; self.differences = differences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        current = try container.decode(CleanupBuild.self, forKey: .current)
        previous = try container.decodeIfPresent(CleanupBuild.self, forKey: .previous)
        candidate = try container.decodeIfPresent(CleanupBuild.self, forKey: .candidate)
        newest = try container.decodeIfPresent(String.self, forKey: .newest)
        fixtures = try container.decodeIfPresent(Int.self, forKey: .fixtures)
        differences = try container.decodeIfPresent([CleanupDifference].self, forKey: .differences) ?? []
    }
}

public struct CleanupEngineFailure: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct CleanupEngineLauncher: Equatable, Sendable {
    public static let label = "com.hedworth.whispr-lite.cleanup"
    public static var agent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static let outputLimit = 1 << 20
    static let reinstall = "Use Install… in Settings to install the cleanup service."

    public let executable: URL
    /// The agent's arguments after its run command: the service directory and port.
    public let options: [String]

    /// Reads the cleanup LaunchAgent and accepts only one that Whispr Lite installed.
    public init(agent: URL = Self.agent) throws {
        guard let data = try? Data(contentsOf: agent) else {
            throw CleanupEngineFailure("The cleanup service is not installed. \(Self.reinstall)")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == Self.label, plist["WhisprLiteOwner"] as? String == Self.label,
              plist["WhisprLiteNativeRunner"] as? Bool == true,
              let program = plist["ProgramArguments"] as? [String], program.count >= 2, program[1] == "run",
              program[0].hasPrefix("/"), FileManager.default.isExecutableFile(atPath: program[0]) else {
            throw CleanupEngineFailure("The cleanup login item was not recognised. \(Self.reinstall)")
        }
        executable = URL(fileURLWithPath: program[0])
        options = Array(program.dropFirst(2))
    }

    /// Runs one command to completion. Progress lines arrive on a background thread as they are
    /// printed; cancelling the task stops the command, which stops any candidate server.
    public func run(_ command: CleanupEngineCommand,
                    progress: @escaping @Sendable (String) -> Void) async throws -> CleanupEngineReport {
        let output = try await LauncherRun(executable: executable, arguments: [command.rawValue] + options,
                                          progress: progress).run()
        let line = output.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? Data()
        guard let report = try? JSONDecoder().decode(CleanupEngineReport.self, from: line) else {
            throw CleanupEngineFailure("The cleanup service returned an unreadable result")
        }
        return report
    }
}

/// One launcher process. Its stderr carries "progress: ..." lines and errors; stdout carries
/// one JSON result.
final class LauncherRun: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let progress: @Sendable (String) -> Void
    private var launched = false
    private var cancelRequested = false
    private var errorLines: [String] = []

    init(executable: URL, arguments: [String], progress: @escaping @Sendable (String) -> Void) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        self.progress = progress
    }

    var cancelled: Bool { lock.withLock { cancelRequested } }

    /// Runs to completion off the caller's thread and returns stdout. Cancelling the task stops
    /// the process; a non-zero exit throws its last stderr line without the setup prefix.
    func run() async throws -> Data {
        let (status, output, errors) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try self.execute() })
                }
            }
        } onCancel: { self.cancel() }
        if cancelled { throw CancellationError() }
        guard status == 0 else {
            let last = errors.last { !$0.isEmpty } ?? "exit status \(status)"
            throw CleanupEngineFailure(last.replacingOccurrences(of: "Cleanup setup failed: ", with: ""))
        }
        return output
    }

    func cancel() {
        lock.withLock {
            cancelRequested = true
            if launched, process.isRunning { process.terminate() }
        }
    }

    /// Blocks until the process exits and both pipes close.
    func execute() throws -> (Int32, Data, [String]) {
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try lock.withLock {
            if cancelRequested { throw CancellationError() }
            try process.run()
            launched = true
        }
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.readLines(errors.fileHandleForReading)
            reader.leave()
        }
        var result = Data()
        while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
            if result.count + chunk.count > CleanupEngineLauncher.outputLimit {
                cancel()
                throw CleanupEngineFailure("The cleanup service returned too much output")
            }
            result.append(chunk)
        }
        reader.wait()
        process.waitUntilExit()
        return (process.terminationStatus, result, lock.withLock { errorLines })
    }

    private func readLines(_ handle: FileHandle) {
        var pending = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if line.hasPrefix("progress: ") { progress(String(line.dropFirst(10))) }
                else { lock.withLock { errorLines = Array((errorLines + [line]).suffix(20)) } }
            }
            if pending.count > 64 * 1024 { pending.removeAll() }
        }
        if !pending.isEmpty {
            lock.withLock { errorLines = Array((errorLines + [String(decoding: pending, as: UTF8.self)]).suffix(20)) }
        }
    }
}
