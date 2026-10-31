import Accelerate
import AVFoundation
import CoreAudio
import Foundation

public struct MicrophoneDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let deviceID: AudioDeviceID
    public static func available() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        return ids.compactMap { id in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(privateAggregatePrefix),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return .init(id: uid, name: name, deviceID: id)
        }
    }
    /// AVAudioEngine's aggregate of the default devices. It has input streams and joins this
    /// process's device list (with a new UID each time) once an engine touches its input node.
    static let privateAggregatePrefix = "CADefaultDeviceAggregate-"
    /// The saved microphone. A USB device's UID includes its port's location ID
    /// (`AppleUSBAudioEngine:maker:product:location:interface`), so the same microphone on
    /// another port or hub gets a new UID; accept it when it is the only such device.
    public static func saved(_ uid: String, in devices: [MicrophoneDevice]) -> MicrophoneDevice? {
        if let exact = devices.first(where: { $0.id == uid }) { return exact }
        guard let key = portIndependentKey(uid) else { return nil }
        let moved = devices.filter { portIndependentKey($0.id) == key }
        return moved.count == 1 ? moved[0] : nil
    }
    private static func portIndependentKey(_ uid: String) -> [Substring]? {
        var parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[0] == "AppleUSBAudioEngine" else { return nil }
        parts.remove(at: parts.count - 2)
        return parts
    }
}
// AVAudioConverter invokes the input provider synchronously on the conversion queue.
private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
}
/// Where a long recording's speculative early chunks end, in 16 kHz samples.
enum EarlyChunkRule {
    /// A chunk may end at a pause once it is this long. On synthetic 5 to 23 s dictations 6 s
    /// saved 84 ms at release on average against 61 ms for 10 s, with fewer seams that changed
    /// the cleaned text; shorter minimums saved more but changed more outputs.
    static let minimumSamples = 6 * PCM16k.rate
    /// One Parakeet window: a chunk ends here even mid-speech.
    static let limitSamples = 15 * PCM16k.rate
    /// A pause is this many consecutive 80 ms frames below the speech level (240 ms). Frame
    /// RMS against `TranscriptTail`'s adaptive level tolerates a noise floor that a
    /// per-sample amplitude test (any sample over 0.01 resets it) never treats as quiet.
    static let pauseFrames = 3
    /// Recent nonzero frame levels the speech level is taken from (about 15 s).
    static let levelFrames = limitSamples / TranscriptTail.frameSamples
}
/// Decides where early chunks end, one 16 kHz sample at a time. Preallocated: appending
/// never allocates, so it runs on the serial audio worker.
struct EarlyChunker {
    var minimumSamples = EarlyChunkRule.minimumSamples
    private(set) var length = 0
    private var frameEnergy: Float = 0
    private var frameFill = 0
    private var quietFrames = 0
    private var levels = [Float](repeating: 0, count: EarlyChunkRule.levelFrames)
    private var sortedLevels = [Float](repeating: 0, count: EarlyChunkRule.levelFrames)
    private var levelCount = 0
    private var levelHead = 0
    mutating func reset() {
        length = 0; frameEnergy = 0; frameFill = 0; quietFrames = 0; levelCount = 0; levelHead = 0
    }
    /// Whether the current chunk ends with this sample: at a pause once it is long enough,
    /// or at the window limit. The speech level carries over to the next chunk.
    mutating func append(_ value: Float) -> Bool {
        length += 1
        frameEnergy += value * value; frameFill += 1
        if frameFill == TranscriptTail.frameSamples {
            let level = (frameEnergy / Float(frameFill)).squareRoot()
            frameEnergy = 0; frameFill = 0
            if level <= speechThreshold(adding: level) { quietFrames += 1 } else { quietFrames = 0 }
        }
        guard (length >= minimumSamples && quietFrames >= EarlyChunkRule.pauseFrames)
            || length >= EarlyChunkRule.limitSamples else { return false }
        length = 0; quietFrames = 0
        return true
    }
    /// `TranscriptTail`'s adaptive speech level over recent nonzero frames, once per 80 ms frame.
    private mutating func speechThreshold(adding level: Float) -> Float {
        if level > 0 {
            levels[levelHead] = level
            levelHead = (levelHead + 1) % levels.count
            levelCount = min(levels.count, levelCount + 1)
        }
        for index in 0..<levelCount { sortedLevels[index] = levels[index] }
        let count = levelCount
        sortedLevels.withUnsafeMutableBufferPointer { vDSP_vsort($0.baseAddress!, vDSP_Length(count), 1) }
        return TranscriptTail.speechThreshold(sortedLevels: sortedLevels[..<levelCount])
    }
}
/// Fixed pool: the callback claims slots in order and the serial worker returns them in the
/// same order, so a counting semaphore replaces a lock. The callback never waits.
final class AudioWorker: @unchecked Sendable {
    /// Taps deliver 100-400 ms packets whatever size is requested (4,410 frames at 44.1 kHz on
    /// the development Mac), so their slots hold the longest packet at the hardware rate. A sink
    /// node delivers each hardware I/O cycle (512 frames, about 11.6 ms, there): many small slots
    /// keep a similar stall tolerance.
    let maximumInputFrames: AVAudioFrameCount
    let queue = DispatchQueue(label: "WhisprLite.audio", qos: .userInitiated)
    private let pool: [AVAudioPCMBuffer]
    private let freeSlots = DispatchSemaphore(value: 0)
    private var nextSlot = 0 // Callback only.
    private let bufferCount: Int
    private let bytesPerFrame: UInt32
    private var callbackOverflow = false
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var recording = false
    private var activityEnabled = false
    private var timingEnabled = false
    private var meter = AudioActivityMeter()
    let activity = AudioActivityValue()
    private var firstAudio: Double?
    private var samples = [Float](repeating: 0, count: PCM16k.maximumSamples)
    private var count = 0
    private var preRoll = [Float](repeating: 0, count: 2400)
    private var rollCount = 0
    private var rollHead = 0
    private var failure: CaptureReport.Failure?
    /// Fixed for the engine's lifetime, so the real-time callback reads it without a race.
    let measured: Bool
    private var callbackTicks: UInt64 = 0 // Callback only: the previous callback's duration.
    private var stats = CaptureReport()
    private var firstPacketHost: Double?
    private var startedAt: Double?
    private let reportLock = NSLock()
    private var finishedReport: CaptureReport?
    /// The last recording's report, published before its end() resumes.
    var lastReport: CaptureReport? { reportLock.withLock { finishedReport } }
    private var audioEpoch: Double?
    private var outputPosition = 0
    private var earlyContinuation: EarlyChunks.Continuation?
    private var earlyStart = 0
    private var chunker = EarlyChunker()
    private var endBoundary: Double?
    private var completion: CheckedContinuation<CapturedAudio, any Error>?
    private var lastPacketSeconds = 0.0
    private var drainSerial = 0
    private var drainTimedOut = false
    init(format: AVAudioFormat, lowLatency: Bool = false, measured: Bool = false) throws {
        self.measured = measured
        maximumInputFrames = lowLatency ? max(4096, AVAudioFrameCount((format.sampleRate * 0.05).rounded(.up)))
            : max(8192, AVAudioFrameCount((format.sampleRate * 0.4).rounded(.up)))
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PCM16k.rate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { throw AppError.capture }
        self.converter = converter; self.output = output
        let frames = maximumInputFrames
        let slots = lowLatency ? 128 : 16
        pool = (0..<slots).compactMap { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) }
        guard pool.count == slots else { throw AppError.capture }
        bufferCount = Int(pool[0].audioBufferList.pointee.mNumberBuffers)
        bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        // Start at zero and signal: libdispatch traps if a semaphore is freed below its initial value.
        for _ in pool { freeSlots.signal() }
    }
    func receive(_ input: AVAudioPCMBuffer, hostSeconds: Double? = nil) {
        receive(input.audioBufferList, frames: input.frameLength, hostSeconds: hostSeconds)
    }
    /// Safe on the real-time I/O thread: no lock, no wait, a bounded copy and one handoff.
    func receive(_ list: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount, hostSeconds: Double? = nil) {
        let entered = measured ? mach_absolute_time() : 0
        // Each packet carries the previous callback's duration to the worker: no extra dispatch.
        let previousTicks = callbackTicks
        defer { if measured { callbackTicks = mach_absolute_time() - entered } }
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let bytes = frames * bytesPerFrame
        guard frames <= maximumInputFrames, src.count == bufferCount, src.allSatisfy({ $0.mDataByteSize <= bytes }) else {
            markOverflow(oversize: true); return
        }
        guard freeSlots.wait(timeout: .now()) == .success else { markOverflow(oversize: false); return }
        let index = nextSlot; nextSlot = (nextSlot + 1) % pool.count
        let buffer = pool[index]
        buffer.frameLength = frames
        let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channel in 0..<src.count {
            if let source = src[channel].mData, let target = dst[channel].mData { memcpy(target, source, Int(src[channel].mDataByteSize)) }
        }
        queue.async { [self] in
            if audioEpoch == nil { audioEpoch = hostSeconds }
            let packet = pool[index]
            lastPacketSeconds = Double(packet.frameLength) / packet.format.sampleRate
            stats.packets += 1
            if firstPacketHost == nil, let hostSeconds {
                firstPacketHost = hostSeconds
                if let startedAt { stats.firstPacketMS = (hostSeconds - startedAt) * 1000 }
            }
            if measured { measure(callbackTicks: previousTicks, packetEnd: hostSeconds.map { $0 + lastPacketSeconds }) }
            convert(packet)
            if let endBoundary, let host = hostSeconds, host + lastPacketSeconds >= endBoundary {
                finalize()
            }
            freeSlots.signal()
        }
    }
    private func markOverflow(oversize: Bool) {
        queue.async { [self] in
            callbackOverflow = true
            if oversize { stats.oversizePackets += 1 } else { stats.droppedPackets += 1 }
        }
    }
    /// Lost audio a recording tolerates after the device settles. First presses after a long idle
    /// lost one 20 to 45 ms skip just past the settle window (16 and 20 October); a real stall
    /// still fails rather than leave a hole in the transcript.
    static let lateGapBudgetMS = 100.0
    /// A skipped I/O cycle. The recording splices across it and the timeline advances, so the
    /// release trim stays exact. Gaps while the device settles are free; later ones are lost
    /// speech and fail the recording once they total more than the budget.
    /// Host/sample time is checked before receive in the tap owner.
    func markGap(frames: AVAudioFramePosition, settling: Bool, hostSeconds: Double?) {
        queue.async { [self] in
            let rate = pool[0].format.sampleRate
            let ms = Double(abs(frames)) / rate * 1000
            if frames > 0 { outputPosition += Int((Double(frames) * Double(PCM16k.rate) / rate).rounded()) }
            if settling { stats.settlingGaps += 1; stats.settlingGapMS += ms; return }
            stats.gaps += 1; stats.gapMS += ms; stats.largestGapMS = max(stats.largestGapMS, ms)
            if stats.firstGapAtMS == nil, let hostSeconds, let firstPacketHost {
                stats.firstGapAtMS = (hostSeconds - firstPacketHost) * 1000
            }
            if stats.gapMS > Self.lateGapBudgetMS { fail(.gap) }
        }
    }
    private func fail(_ reason: CaptureReport.Failure) { if failure == nil { failure = reason } }
    private func measure(callbackTicks: UInt64, packetEnd: Double?) {
        let callback = AVAudioTime.seconds(forHostTime: callbackTicks) * 1000
        stats.maxCallbackMS = max(stats.maxCallbackMS ?? 0, callback)
        guard let packetEnd else { return }
        let delay = (AVAudioTime.seconds(forHostTime: mach_absolute_time()) - packetEnd) * 1000
        stats.maxQueueDelayMS = max(stats.maxQueueDelayMS ?? 0, delay)
    }
    private func publish(_ report: CaptureReport?) { reportLock.withLock { finishedReport = report } }
    /// The first excluded sample begins at the release boundary. Only the serial worker calls this.
    private func allowedSamples(until boundary: Double?) -> Int? {
        guard let boundary, let audioEpoch, boundary.isFinite else { return nil }
        let value = ceil((boundary - audioEpoch) * Double(PCM16k.rate))
        guard !value.isNaN else { return nil }
        if value <= 0 { return 0 }
        if value >= Double(Int.max) { return Int.max }
        var allowed = Int(value)
        // Subtracting large host timestamps can shift ceil by one. Match the previous
        // per-sample comparison at the two candidate positions without scanning samples.
        if allowed > 0, audioEpoch + Double(allowed - 1) / Double(PCM16k.rate) >= boundary {
            allowed -= 1
        } else if allowed < Int.max, audioEpoch + Double(allowed) / Double(PCM16k.rate) < boundary {
            allowed += 1
        }
        return allowed
    }
    private func convert(_ input: AVAudioPCMBuffer?) {
        let supply = ConverterInput(input)
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if let input = supply.buffer, !supply.supplied { supply.supplied = true; state.pointee = .haveData; return input }
                state.pointee = supply.buffer == nil ? .endOfStream : .noDataNow
                return nil
            }
            if error != nil || status == .error { fail(.converter); return }
            if let floats = output.floatChannelData?[0] {
                let produced = Int(output.frameLength)
                if recording, produced > 0 {
                    if timingEnabled && firstAudio == nil { firstAudio = ProcessInfo.processInfo.systemUptime }
                    if activityEnabled, let value = meter.consume(UnsafeBufferPointer(start: floats, count: produced)) {
                        activity.publish(value)
                    }
                }
                let start = outputPosition
                outputPosition += produced
                if recording {
                    let allowed = allowedSamples(until: endBoundary)
                    let withinBoundary = allowed.map { max(0, min(produced, $0 - start)) } ?? produced
                    let copied = min(withinBoundary, samples.count - count)
                    if copied < withinBoundary { fail(.full) }
                    if copied > 0 {
                        samples.withUnsafeMutableBufferPointer { destination in
                            _ = memcpy(destination.baseAddress!.advanced(by: count), floats,
                                       copied * MemoryLayout<Float>.stride)
                        }
                        // Deliver still advances each count for early-chunk boundaries.
                        for index in 0..<copied { count += 1; deliver(floats[index]) }
                    }
                } else {
                    for index in 0..<produced {
                        preRoll[rollHead] = floats[index]
                        rollHead = (rollHead + 1) % preRoll.count
                        rollCount = min(preRoll.count, rollCount + 1)
                    }
                }
            }
            if status != .haveData { break }
        }
    }
    func begin(warm: Bool, earlyChunks: Bool = false,
               activity: Bool = false, timings: Bool = false, startedAt: Double? = nil,
               startEngine: () throws -> Void = {}) throws -> EarlyChunks? {
        let stream = try queue.sync {
            guard !recording, completion == nil else { throw AppError.capture }
            let overflow = callbackOverflow; callbackOverflow = false
            guard !overflow else { throw AppError.overflow }
            failure = nil; stats = .init(); firstPacketHost = nil; self.startedAt = startedAt; publish(nil)
            drainTimedOut = false; count = 0
            firstAudio = nil; timingEnabled = timings; activityEnabled = activity; meter = .init(); self.activity.publish(0)
            var stream: EarlyChunks?
            if earlyChunks {
                let pair = EarlyChunks.makeStream(bufferingPolicy: .bufferingOldest(1))
                earlyContinuation = pair.continuation; stream = pair.stream
            } else { earlyContinuation = nil }
            earlyStart = 0; chunker.reset()
            if warm { appendPreRoll() }
            else { converter.reset(); audioEpoch = nil; outputPosition = 0 }
            rollCount = 0; recording = true
            return stream
        }
        // Engine.start can deliver packets before it returns. Arm the serial worker first,
        // keeping all post-press audio without changing the warm microphone's pre-roll.
        do { try startEngine() }
        catch {
            queue.sync {
                earlyContinuation?.finish(throwing: AppError.capture); earlyContinuation = nil
                converter.reset(); recording = false; count = 0; rollCount = 0
                callbackOverflow = false
                audioEpoch = nil; outputPosition = 0; endBoundary = nil
                activityEnabled = false; self.activity.publish(0)
            }
            throw error
        }
        return stream
    }
    private func appendPreRoll() {
        var index = (rollHead - rollCount + preRoll.count) % preRoll.count
        for _ in 0..<rollCount {
            let value = preRoll[index]
            samples[count] = value
            count += 1
            deliver(value)
            index += 1
            if index == preRoll.count { index = 0 }
        }
    }
    private func deliver(_ value: Float) {
        // The final full transcription verifies every seam.
        if earlyContinuation != nil, chunker.append(value) { flushEarlyChunk() }
    }
    private func flushEarlyChunk() {
        guard let continuation = earlyContinuation else { return }
        let end = count
        guard let pcm = try? PCM16k(Array(samples[earlyStart..<end])) else {
            continuation.finish(throwing: AppError.capture); earlyContinuation = nil; return
        }
        earlyStart = end
        // A cancelled consumer terminates the stream; stop producing early chunks.
        if case .enqueued = continuation.yield(pcm) { return }
        else {
            continuation.finish(throwing: AppError.overflow); earlyContinuation = nil
        }
    }
    func end(at boundary: Double? = nil) async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard recording else {
                    publish(.init(failure: .notRecording)); continuation.resume(throwing: AppError.capture); return
                }
                completion = continuation; endBoundary = boundary
                drainSerial &+= 1; let serial = drainSerial
                if let allowed = allowedSamples(until: boundary) {
                    count -= min(count, max(0, outputPosition - allowed))
                }
                if boundary == nil || (allowedSamples(until: boundary).map { outputPosition >= $0 } ?? false) {
                    finalize()
                } else {
                    // Keep capture alive for the callback containing the release sample, then drain once.
                    // A late packet (Bluetooth, system load) costs only the unseen tail, never the recording.
                    let wait = min(0.5, max(0.15, lastPacketSeconds + 0.1))
                    queue.asyncAfter(deadline: .now() + wait) { [self] in
                        if completion != nil, drainSerial == serial { drainTimedOut = true; finalize() }
                    }
                }
            }
        }
    }
    private func finalize() {
        guard let continuation = completion else { return }
        completion = nil
        convert(nil); converter.reset(); recording = false
        activityEnabled = false; activity.publish(0)
        let overflow = callbackOverflow; callbackOverflow = false
        defer { count = 0; rollCount = 0; endBoundary = nil; audioEpoch = nil; outputPosition = 0 }
        if overflow { fail(stats.oversizePackets > 0 ? .oversize : .overflow) }
        var report = stats; report.failure = failure
        publish(report)
        guard failure == nil else {
            earlyContinuation?.finish(throwing: AppError.overflow); earlyContinuation = nil
            continuation.resume(throwing: AppError.overflow); return
        }
        earlyContinuation?.finish(); earlyContinuation = nil
        do {
            let pcm = try PCM16k(Array(samples.prefix(count)))
            continuation.resume(returning: .init(pcm: pcm, firstAudioUptime: firstAudio,
                                                drainTimedOut: drainTimedOut))
        }
        catch { continuation.resume(throwing: error) }
    }
}
final class AudioTap: @unchecked Sendable {
    let worker: AudioWorker
    private var expectedSample: AVAudioFramePosition?
    /// After an on-demand start the device can skip its first cycles under load (the HAL logs
    /// "skipping cycle due to overload"). Gaps then re-sync instead of failing the recording.
    static let startupSettleSeconds = 0.25
    private var settling = false
    private var settleUntil: Double?
    init(_ worker: AudioWorker) { self.worker = worker }
    /// A stopped engine starts again on a new I/O timeline; only a gap after it settles is lost
    /// speech. Call only while the engine is stopped, so no render callback reads these values.
    func restart() { expectedSample = nil; settling = true; settleUntil = nil }
    // Construct outside MainActor isolation: AVAudioEngine invokes this on its audio
    // queue. An inline non-Sendable closure in prepare inherits MainActor in Swift 6.
    func callback() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, time in receive(buffer, time: time) }
    }
    func sinkCallback() -> AVAudioSinkNodeReceiverBlock {
        { [self] time, frames, list in
            let stamp = time.pointee
            receive(list, frames: frames, sampleTime: stamp.mFlags.contains(.sampleTimeValid) ? AVAudioFramePosition(stamp.mSampleTime) : nil,
                    hostSeconds: stamp.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: stamp.mHostTime) : nil)
            return noErr
        }
    }
    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        receive(buffer.audioBufferList, frames: buffer.frameLength, sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                hostSeconds: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
    }
    private func receive(_ list: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount, sampleTime: AVAudioFramePosition?, hostSeconds: Double?) {
        if settling {
            if let hostSeconds, let settleUntil { settling = hostSeconds < settleUntil }
            else if let hostSeconds { settleUntil = hostSeconds + Self.startupSettleSeconds }
            else { settling = false }
        }
        if let sampleTime {
            if let expectedSample, sampleTime != expectedSample {
                worker.markGap(frames: sampleTime - expectedSample, settling: settling, hostSeconds: hostSeconds)
            }
            expectedSample = sampleTime + AVAudioFramePosition(frames)
        }
        worker.receive(list, frames: frames, hostSeconds: hostSeconds)
    }
}
public struct CaptureOptions: Sendable {
    public let warm: Bool
    public let microphoneUID: String
    public let earlyChunks: Bool
    public let lowLatency: Bool
    public init(_ preferences: Preferences) {
        warm = preferences.warmCapture
        microphoneUID = preferences.microphoneUID
        earlyChunks = preferences.backend == .parakeet && preferences.cleanupEnabled
        lowLatency = preferences.lowLatencyCapture
    }
}
/// A device switch updates the hardware format before the input node's client format.
/// Setup can also deliver a delayed configuration notification after both already match.
struct CaptureInputConfiguration: Equatable {
    let deviceID: AudioDeviceID
    let format: AVAudioFormat
    init(deviceID: AudioDeviceID, format: AVAudioFormat) {
        self.deviceID = deviceID; self.format = format
    }
    init?(_ input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return nil }
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, &size) == noErr,
              device != kAudioObjectUnknown else { return nil }
        self.init(deviceID: device, format: input.inputFormat(forBus: 0))
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.deviceID == rhs.deviceID && lhs.format.isEqual(rhs.format)
    }
    func requiresRecovery(current: Self?, clientFormat: AVAudioFormat,
                          expectsRunning: Bool, isRunning: Bool) -> Bool {
        current != self || !format.isEqual(clientFormat) || (expectsRunning && !isRunning)
    }
}
@MainActor public final class AudioCapture: CaptureDriver {
    private var engine: AVAudioEngine?
    private var worker: AudioWorker?
    private var tap: AudioTap?
    private var tapInstalled = false
    private var warm = false
    private var recording = false
    private var earlyChunksEnabled = false
    private var engineEpoch = UUID()
    public var showAudioActivity = true
    public var debugTimings = false
    public var recordingActivity: Float { worker?.activity.read() ?? 0 }
    /// Capture needs rebuilding: the engine's input changed, or after a failed prepare the
    /// set of microphones changed (a USB microphone can take seconds to reappear).
    public var onFailure: (() -> Void)?
    private var changeObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var watchedMicrophones: Set<String> = []
    /// The last recording's capture report, for diagnostics.
    public private(set) var captureReport: CaptureReport?
    private var stoppedAt: ContinuousClock.Instant?
    private var onDemandStart: (idleSeconds: Double?, engineStartMS: Double)?
    public init() {}
    /// `lowLatency` reads each hardware I/O cycle through a sink node instead of a 100 ms tap,
    /// so release waits about 6 ms rather than about 50 ms for the packet holding its boundary.
    public func prepare(_ options: CaptureOptions) throws {
        do {
            try prepare(warm: options.warm, microphoneUID: options.microphoneUID,
                        earlyChunks: options.earlyChunks, lowLatency: options.lowLatency)
        } catch {
            // No engine is left to notice the microphone coming back, so watch the device list.
            watchMicrophones(); throw error
        }
    }
    private static var devicesAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    /// Reports through `onFailure` until the next prepare or suspend. Compares microphones rather
    /// than raw device changes: a failed prepare can add the engine's own private aggregate.
    private func watchMicrophones() {
        let epoch = engineEpoch
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.engineEpoch == epoch else { return }
                let microphones = Set(MicrophoneDevice.available().map(\.id))
                guard microphones != self.watchedMicrophones else { return }
                self.watchedMicrophones = microphones
                self.onFailure?()
            }
        }
        var address = Self.devicesAddress
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else { return }
        deviceListener = listener
        // After registering: a microphone that appears from here on is a change. Listener
        // calls queue on main, so none runs before this.
        watchedMicrophones = Set(MicrophoneDevice.available().map(\.id))
    }
    private func prepare(warm: Bool, microphoneUID: String, earlyChunks: Bool, lowLatency: Bool) throws {
        suspend(); self.warm = warm; earlyChunksEnabled = earlyChunks
        let engine = AVAudioEngine()
        if !microphoneUID.isEmpty {
            guard var device = MicrophoneDevice.saved(microphoneUID, in: MicrophoneDevice.available())?.deviceID,
                  let unit = engine.inputNode.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw AppError.capture }
        }
        guard let configuration = CaptureInputConfiguration(engine.inputNode) else { throw AppError.capture }
        // CurrentDevice changes the hardware side synchronously, but outputFormat can
        // still describe the old default-output aggregate (e.g. 192 kHz vs a 48 kHz mic).
        let format = configuration.format
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError.capture }
        let worker = try AudioWorker(format: format, lowLatency: lowLatency, measured: debugTimings)
        let tap = AudioTap(worker)
        if lowLatency {
            let sink = AVAudioSinkNode(receiverBlock: tap.sinkCallback())
            engine.attach(sink); engine.connect(engine.inputNode, to: sink, format: format)
        } else {
            engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: format, block: tap.callback())
            tapInstalled = true
        }
        engine.prepare()
        self.engine = engine; self.worker = worker; self.tap = tap
        let epoch = engineEpoch
        changeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engineEpoch == epoch, let engine = self.engine else { return }
                // Ignore a completed setup change and output-only notifications while
                // input remains usable. A stopped active engine still needs recovery.
                guard configuration.requiresRecovery(current: CaptureInputConfiguration(engine.inputNode),
                    clientFormat: engine.inputNode.outputFormat(forBus: 0),
                    expectsRunning: self.warm || self.recording, isRunning: engine.isRunning) else { return }
                self.onFailure?()
            }
        }
        if warm { try engine.start() }
    }
    public func begin() throws -> EarlyChunks? {
        captureReport = nil; onDemandStart = nil
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            captureReport = .init(failure: .permission); throw AppError.capture
        }
        guard let engine, let worker else { captureReport = .init(failure: .notPrepared); throw AppError.notReady }
        let needsStart = !engine.isRunning
        let began = ContinuousClock.now
        let startedAt = needsStart ? AVAudioTime.seconds(forHostTime: mach_absolute_time()) : nil
        // On-demand capture stopped the engine after the last recording.
        if needsStart { tap?.restart() }
        do {
            let chunks = try worker.begin(warm: warm, earlyChunks: earlyChunksEnabled,
                activity: showAudioActivity, timings: debugTimings, startedAt: startedAt) {
                if needsStart {
                    do { try engine.start() }
                    catch {
                        engine.stop()
                        var report = CaptureReport(failure: .engineStart)
                        report.engineStatus = (error as NSError).code
                        self.captureReport = report; throw error
                    }
                }
            }
            if needsStart {
                onDemandStart = (stoppedAt.map { $0.duration(to: began).milliseconds / 1000 },
                                 began.duration(to: .now).milliseconds)
            }
            recording = true
            return chunks
        } catch {
            if captureReport == nil {
                captureReport = withStart(.init(failure: error as? AppError == .overflow ? .overflow : .busy))
            }
            throw error
        }
    }
    private func withStart(_ report: CaptureReport) -> CaptureReport {
        var report = report
        report.idleSeconds = onDemandStart?.idleSeconds; report.engineStartMS = onDemandStart?.engineStartMS
        return report
    }
    public func releaseBoundary() -> Double? { AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime()) }
    public func end(at boundary: Double?) async throws -> CapturedAudio {
        guard let worker else { captureReport = .init(failure: .notPrepared); throw AppError.capture }
        defer {
            // A route recovery can replace capture while this worker is draining.
            if self.worker === worker {
                recording = false
                if !warm { engine?.stop(); stoppedAt = .now }
                captureReport = worker.lastReport.map(withStart)
            }
        }
        return try await worker.end(at: boundary ?? releaseBoundary())
    }
    public func suspend() {
        engineEpoch = UUID(); recording = false
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver); self.changeObserver = nil }
        if let deviceListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
            self.deviceListener = nil
        }
        if engine?.isRunning == true || stoppedAt == nil { stoppedAt = .now }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine = nil; worker = nil; tap = nil
    }
}
