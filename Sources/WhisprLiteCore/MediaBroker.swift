import Foundation
import Darwin

private func brokerReadChunk(_ handle: FileHandle) -> Data {
    // Foundation's read(upToCount:) can wait to fill a pipe read. One POSIX read
    // returns the bytes currently available and keeps the allocation bounded.
    var bytes = [UInt8](repeating: 0, count: 8192)
    var count: Int
    repeat {
        count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
    } while count < 0 && errno == EINTR
    return count > 0 ? Data(bytes.prefix(count)) : Data()
}

public struct BrokerEvent: Decodable, Sendable {
    public struct State: Decodable, Sendable {
        public let known: Bool
        public let playing: Bool?
        public let trustworthy: Bool
        public let subscriptionHealthy: Bool?
    }
    public let state: State?
    public let version: Int
    public let type: String
    public let generation: String
    public let request: String
    public let session: String
    public let reason: String?
}
public struct JSONLineDecoder: Sendable {
    private var pending = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [BrokerEvent] {
        var result: [BrokerEvent] = []
        for byte in data {
            if byte == 10 {
                let event = try JSONDecoder().decode(BrokerEvent.self, from: pending)
                guard event.version == 1, event.generation.count <= 64, event.request.count <= 64,
                      event.session.count <= 64, (event.reason?.count ?? 0) <= 64,
                      ["ready", "snapshot", "issued", "paused", "released", "resumed", "skipped", "unconfirmed", "fatal"].contains(event.type) else { throw AppError.protocolViolation }
                result.append(event); pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < 8192 else { throw AppError.protocolViolation }
                pending.append(byte)
            }
        }
        return result
    }
    public func finish() throws { guard pending.isEmpty else { throw AppError.protocolViolation } }
}

/// One bounded inbox/dispatch, even if the helper writes faster than the main actor reads.
private final class BrokerInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var eof = false, overflow = false, scheduled = false
    private let consume: @MainActor @Sendable (Data, Bool, Bool) -> Void
    init(consume: @escaping @MainActor @Sendable (Data, Bool, Bool) -> Void) { self.consume = consume }
    func append(_ bytes: Data) {
        lock.lock()
        eof = eof || bytes.isEmpty
        if data.count + bytes.count > 65_536 { overflow = true; data.removeAll() }
        else if !overflow { data.append(bytes) }
        let notify = !scheduled; scheduled = true
        lock.unlock()
        if notify { DispatchQueue.main.async { self.flush() } }
    }
    @MainActor private func flush() {
        lock.lock()
        let bytes = data, ended = eof, exceeded = overflow
        data = Data(); scheduled = false
        lock.unlock()
        consume(bytes, ended, exceeded)
    }
}
private final class BrokerWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WhisprLite.media.write")
    private let lock = NSLock()
    private var outstanding = 0
    func send(_ data: Data, to handle: FileHandle, failed: @escaping @MainActor @Sendable () -> Void) -> Bool {
        lock.lock()
        guard outstanding < 16 else { lock.unlock(); return false }
        outstanding += 1; lock.unlock()
        queue.async {
            var didFail = false
            do { try handle.write(contentsOf: data) } catch { didFail = true }
            self.lock.lock(); self.outstanding -= 1; self.lock.unlock()
            if didFail { DispatchQueue.main.async(execute: failed) }
        }
        return true
    }
    func close(_ handle: FileHandle?) { queue.async { try? handle?.close() } }
}

public enum MediaReadiness: Sendable, Equatable { case disabled, starting, ready, recovering, unavailable }

/// Recovery never transfers a lease across helper generations or blocks microphone/ASR work.
@MainActor public final class MediaBroker: MediaDriver {
    public private(set) var status = "Media disabled"
    public private(set) var readiness: MediaReadiness = .disabled
    public var onChange: (() -> Void)?
    public var diagnostics: DiagnosticLogger?
    private var process: Process?
    private var settling: Process?
    private var input: FileHandle?
    private var configuration: (script: URL, framework: URL)?
    private var generation: String?
    private var decoder = JSONLineDecoder()
    private var pending: Set<String> = []
    private var session: UUID?
    private var enabled = false
    private var disabledForRun = false
    private var epoch = UUID()
    private var recoveries = 0
    private var restartTask: Task<Void, Never>?
    private let writes = BrokerWriter()
    public init() {}

    public func start(script: URL, framework: URL) {
        guard !disabledForRun, process == nil, restartTask == nil else { return }
        enabled = true; configuration = (script, framework)
        if settling?.isRunning == true { schedule(after: .milliseconds(100)) }
        else { launch() }
    }
    private func launch() {
        guard enabled, !disabledForRun, let configuration else { return }
        guard FileManager.default.fileExists(atPath: configuration.script.path),
              FileManager.default.fileExists(atPath: configuration.framework.path) else { failed(permanent: true); return }
        epoch = UUID(); let owner = epoch
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [configuration.script.path, configuration.framework.path]
        var environment = ProcessInfo.processInfo.environment
        environment["WHISPR_DEBUG_DIAGNOSTICS"] = diagnostics?.isEnabled == true ? "1" : "0"
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        input = stdin.fileHandleForWriting
        let inbox = BrokerInbox { [weak self] data, eof, overflow in
            guard let self, self.epoch == owner else { return }
            if overflow { self.failed(permanent: true); return }
            do {
                for event in try self.decoder.append(data) {
                    guard self.epoch == owner else { break }
                    self.receive(event)
                }
                if eof, self.epoch == owner { try self.decoder.finish(); self.failed() }
            } catch { self.failed(permanent: true) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = brokerReadChunk(handle)
            if data.isEmpty { handle.readabilityHandler = nil }
            inbox.append(data)
        }
        // Discard bounded stderr chunks: diagnostics can contain private media metadata.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if brokerReadChunk(handle).isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in
            guard let self, self.epoch == owner else { return }; self.failed()
        } }
        do {
            try process.run(); self.process = process
            setStatus(.starting, "Media starting")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.epoch == owner, self.generation == nil else { return }
                self.failed()
            }
        } catch { failed(permanent: true) }
    }
    private func receive(_ event: BrokerEvent) {
        // Only protocol enums/booleans enter the diagnostic log, never player metadata.
        if let diagnostics, diagnostics.isEnabled, event.type == "ready" || event.generation == generation {
            var record = DiagnosticRecord(.mediaReply, session: UUID(uuidString: event.session), code: DiagnosticCode(rawValue: event.type))
            record.known = event.state?.known; record.playing = event.state?.playing
            record.trustworthy = event.state?.trustworthy; record.subscriptionHealthy = event.state?.subscriptionHealthy
            record.mediaReason = event.reason.flatMap(MediaDiagnosticReason.init(rawValue:))
            diagnostics.record(record)
        }
        if event.type == "ready" {
            guard generation == nil, !event.generation.isEmpty else { failed(permanent: true); return }
            generation = event.generation
            setStatus(.ready, "Media broker ready (player validation pending)")
            send("snapshot", session: nil)
            return
        }
        guard event.generation == generation else { return }
        if event.type == "fatal" { failed(permanent: true); return }
        pending.remove(event.request)
        if event.type == "snapshot", let state = event.state {
            setStatus(.ready, state.known && state.trustworthy && state.subscriptionHealthy == true ?
                "Media ready" : "Media identity/subscription unavailable; control skipped")
        }
        if event.type == "unconfirmed" {
            setStatus(.ready, "Media pause unconfirmed; automatic resume may be skipped")
        }
    }
    private func send(_ operation: String, session: UUID?) {
        guard let input, let generation else { return }
        guard pending.count < 16 else { failed(); return }
        let request = UUID().uuidString; pending.insert(request)
        let body: [String: Any] = ["version": 1, "operation": operation, "generation": generation,
                                  "request": request, "session": session?.uuidString ?? "", "deadlineMS": 500]
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { pending.remove(request); return }
        data.append(10)
        let owner = epoch
        guard writes.send(data, to: input, failed: { [weak self] in
            guard let self, self.epoch == owner else { return }; self.failed()
        }) else { failed(); return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.epoch == owner else { return }
            self.pending.remove(request) // A response timeout does not discard the helper's own ledger.
        }
    }
    public func begin(_ session: UUID) {
        diagnostics?.record(.init(.mediaCommand, session: session, code: .begin, enabled: enabled && generation != nil))
        guard enabled, generation != nil, self.session == nil else { return }
        self.session = session; send("begin", session: session)
    }
    public func end(_ session: UUID) {
        diagnostics?.record(.init(.mediaCommand, session: session, code: .end, enabled: self.session == session))
        guard self.session == session else { return }
        send("end", session: session); self.session = nil
    }
    public func shutdown() {
        enabled = false; restartTask?.cancel(); restartTask = nil
        if let session { end(session) }
        send("shutdown", session: nil)
        let old = resetTransport()
        setStatus(.disabled, "Media disabled")
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if old?.isRunning == true { old?.terminate() }
        }
    }
    private func resetTransport() -> Process? {
        epoch = UUID() // Invalidate queued reads, writes, timers and termination callbacks first.
        generation = nil; session = nil; pending.removeAll(); decoder = .init()
        writes.close(input); input = nil
        let old = process; settling = old ?? settling
        process = nil
        return old
    }
    private func failed(permanent: Bool = false) {
        let old = resetTransport()
        if old?.isRunning == true { old?.terminate() }
        guard enabled else { return }
        if permanent || recoveries >= 2 {
            disabledForRun = true; enabled = false
            setStatus(.unavailable, "Media unavailable for this run; dictation remains available")
            return
        }
        recoveries += 1
        setStatus(.recovering, "Media restarting; previous playback may need manual resume")
        schedule(after: recoveries == 1 ? .milliseconds(250) : .milliseconds(750))
    }
    private func schedule(after delay: Duration) {
        restartTask?.cancel()
        let owner = epoch
        restartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard let self else { return }
                // Do not overlap an old helper with its replacement, even if termination is slow.
                for _ in 0..<20 {
                    guard self.enabled, self.epoch == owner else { return }
                    if self.settling?.isRunning != true { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard self.enabled, self.epoch == owner else { return }
                self.restartTask = nil
                guard self.settling?.isRunning != true else { self.failed(permanent: true); return }
                self.settling = nil; self.launch()
            } catch {}
        }
    }
    private func setStatus(_ readiness: MediaReadiness, _ status: String) {
        diagnostics?.record(.init(.mediaState, code: DiagnosticCode(rawValue: String(describing: readiness))))
        self.readiness = readiness; self.status = status; onChange?()
    }
}
