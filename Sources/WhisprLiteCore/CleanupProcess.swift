import Foundation
import Darwin

struct CleanupCommandResult: Sendable {
    var status: Int32
    var output = Data()
    var error = Data()
    var text: String { String(decoding: output + error, as: UTF8.self) }
}

/// Bounded, cancellable child processes. Used only by the native service helper.
final class CleanupProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var exceeded = false
    private var output = Data(), errors = Data()
    private let limit: Int

    init(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, limit: Int = 1 << 20) {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = environment; process.standardInput = FileHandle.nullDevice
        self.limit = limit
    }
    static func run(_ executable: String, _ arguments: [String], _ environment: [String: String]? = nil,
                    _ limit: Int = 1 << 20) async throws -> CleanupCommandResult {
        try await CleanupProcess(executable, arguments, environment: environment, limit: limit).run()
    }
    func run() async throws -> CleanupCommandResult {
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try self.execute() })
                }
            }
        } onCancel: { self.cancel() }
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if lock.withLock({ exceeded }) { throw CleanupEngineFailure("Cleanup command exceeded its output limit") }
        return result
    }
    private func cancel() {
        lock.withLock {
            cancelled = true
            if started, process.isRunning { process.terminate() }
        }
        forceStopIfNeeded()
    }
    private func forceStopIfNeeded() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            self.lock.withLock {
                if self.started, self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            }
        }
    }
    private func read(_ handle: FileHandle, stderr: Bool) {
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            lock.withLock {
                if output.count + errors.count + chunk.count > limit {
                    if !exceeded {
                        exceeded = true
                        if process.isRunning { process.terminate() }
                        forceStopIfNeeded()
                    }
                } else if stderr { errors.append(chunk) } else { output.append(chunk) }
            }
        }
    }
    private func execute() throws -> CleanupCommandResult {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run(); started = true
        }
        let readers = DispatchGroup()
        for (handle, error) in [(stdout.fileHandleForReading, false), (stderr.fileHandleForReading, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { self.read(handle, stderr: error); readers.leave() }
        }
        process.waitUntilExit(); readers.wait()
        return lock.withLock { .init(status: process.terminationStatus, output: output, error: errors) }
    }
}

struct CleanupSystem: Sendable {
    var command: @Sendable (String, [String], [String: String]?, Int) async throws -> CleanupCommandResult = CleanupProcess.run
    var ready: @Sendable (Int, String) async throws -> Void = { port, alias in
        let endpoint = try LocalEndpoint("http://127.0.0.1:\(port)")
        var configuration = CleanupConfiguration(endpoint: endpoint, prompt: "")
        configuration.model = alias
        try await HTTPCleanup(configuration).checkReadiness()
    }
    func checked(_ path: String, _ args: [String], environment: [String: String]? = nil,
                 limit: Int = 1 << 20) async throws -> CleanupCommandResult {
        let result = try await command(path, args, environment, limit)
        guard result.status == 0 else {
            // Tool errors never include cleanup requests or model output.
            let tail = String(decoding: result.error, as: UTF8.self).split(separator: "\n").suffix(4).joined(separator: "\n")
            throw CleanupEngineFailure("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(result.status))\(tail.isEmpty ? "" : ": \(tail)")")
        }
        return result
    }
}

enum CleanupPort {
    static func checkFree(_ port: Int) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CleanupEngineFailure("Could not check the cleanup port") }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            throw CleanupEngineFailure("Port \(port) is occupied; existing services were left running. Choose another --port.")
        }
    }
}
