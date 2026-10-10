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
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return .init(id: uid, name: name, deviceID: id)
        }
    }
}
// AVAudioConverter invokes the input provider synchronously on the conversion queue.
private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
}
/// Fixed pool: the real-time callback copies into an available slot, never waits for a lock.
final class AudioWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "WhisprLite.audio", qos: .userInitiated)
    private let lock = NSLock()
    private let pool: [AVAudioPCMBuffer]
    private var free: [Int]
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
    private var failed = false
    private var audioEpoch: Double?
    private var outputPosition = 0
    private var stream: AsyncThrowingStream<PCM16k, any Error>?
    private var streamContinuation: AsyncThrowingStream<PCM16k, any Error>.Continuation?
    private var chunk: [Float] = []
    private var streamingEnabled = false
    private var endBoundary: Double?
    private var completion: CheckedContinuation<PCM16k, any Error>?
    init(format: AVAudioFormat) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { throw AppError.capture }
        self.converter = converter; self.output = output
        pool = (0..<16).compactMap { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) }
        guard pool.count == 16 else { throw AppError.capture }
        free = Array(0..<16); free.reserveCapacity(16)
    }
    func receive(_ input: AVAudioPCMBuffer, hostSeconds: Double? = nil) {
        guard lock.try() else { markDiscontinuity(); return }
        guard input.frameLength <= 4096, let index = free.popLast() else { callbackOverflow = true; lock.unlock(); return }
        let buffer = pool[index]
        buffer.frameLength = input.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard src.count == dst.count, (0..<src.count).allSatisfy({ src[$0].mDataByteSize <= dst[$0].mDataByteSize }) else {
            callbackOverflow = true; free.append(index); lock.unlock(); return
        }
        for channel in 0..<src.count {
            if let source = src[channel].mData, let target = dst[channel].mData { memcpy(target, source, Int(src[channel].mDataByteSize)) }
        }
        lock.unlock()
        queue.async { [self] in
            if audioEpoch == nil { audioEpoch = hostSeconds }
            convert(pool[index])
            if let endBoundary, let host = hostSeconds,
               host + Double(pool[index].frameLength) / pool[index].format.sampleRate >= endBoundary {
                finalize()
            }
            lock.lock(); free.append(index); lock.unlock()
        }
    }
    // Runs only on the conversion queue. Host/sample time is checked before receive in the tap owner.
    func markDiscontinuity() { queue.async { self.failed = true } }
    private func convert(_ input: AVAudioPCMBuffer?) {
        let supply = ConverterInput(input)
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if let input = supply.buffer, !supply.supplied { supply.supplied = true; state.pointee = .haveData; return input }
                state.pointee = supply.buffer == nil ? .endOfStream : .noDataNow
                return nil
            }
            if error != nil || status == .error { failed = true; return }
            if let floats = output.floatChannelData?[0] {
                if recording, output.frameLength > 0 {
                    if timingEnabled && firstAudio == nil { firstAudio = ProcessInfo.processInfo.systemUptime }
                    if activityEnabled, let value = meter.consume(UnsafeBufferPointer(start: floats, count: Int(output.frameLength))) { activity.publish(value) }
                }
                for index in 0..<Int(output.frameLength) {
                    let value = floats[index]
                    let sampleTime = audioEpoch.map { $0 + Double(outputPosition) / 16_000 }
                    outputPosition += 1
                    if recording, let endBoundary, let sampleTime, sampleTime >= endBoundary { continue }
                    if recording {
                        if count < samples.count { samples[count] = value; count += 1; deliver(value) }
                        else { failed = true }
                    } else {
                        preRoll[rollHead] = value; rollHead = (rollHead + 1) % preRoll.count
                        rollCount = min(preRoll.count, rollCount + 1)
                    }
                }
            }
            if status != .haveData { break }
        }
    }
    func begin(warm: Bool, streaming: Bool = false, activity: Bool = false, timings: Bool = false) throws {
        try queue.sync {
            guard !recording, completion == nil else { throw AppError.capture }
            lock.lock(); let overflow = callbackOverflow; callbackOverflow = false; lock.unlock()
            guard !overflow else { throw AppError.overflow }
            failed = false; count = 0
            firstAudio = nil; timingEnabled = timings; activityEnabled = activity; meter = .init(); self.activity.publish(0)
            streamingEnabled = streaming; chunk = []; chunk.reserveCapacity(640)
            if streaming {
                let pair = AsyncThrowingStream<PCM16k, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
                stream = pair.stream; streamContinuation = pair.continuation
            } else { stream = nil; streamContinuation = nil }
            if warm {
                for index in 0..<rollCount { let value = preRoll[(rollHead - rollCount + index + preRoll.count) % preRoll.count]; samples[count] = value; count += 1; deliver(value) }
            }
            rollCount = 0; recording = true
        }
    }
    func chunks() -> AsyncThrowingStream<PCM16k, any Error>? { queue.sync { stream } }
    func firstAudioUptime() -> Double? { queue.sync { firstAudio } }
    private func deliver(_ value: Float) {
        guard streamingEnabled, streamContinuation != nil else { return }
        chunk.append(value)
        if chunk.count == 640 { flushChunk() }
    }
    private func flushChunk() {
        guard !chunk.isEmpty, let continuation = streamContinuation, let pcm = try? PCM16k(chunk) else { return }
        if case .dropped = continuation.yield(pcm) {
            continuation.finish(throwing: AppError.overflow); streamContinuation = nil
        }
        chunk.removeAll(keepingCapacity: true)
    }
    func end(at boundary: Double? = nil) async throws -> PCM16k {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard recording else { continuation.resume(throwing: AppError.capture); return }
                completion = continuation; endBoundary = boundary
                if let boundary, let epoch = audioEpoch {
                    let allowed = max(0, Int(ceil((boundary - epoch) * 16_000)))
                    let excess = min(count, max(0, outputPosition - allowed))
                    count -= excess
                    if excess > 0 {
                        // An already-delivered partial cannot retract PCM; retain exact audio for batch fallback.
                        streamContinuation?.finish(throwing: AppError.overflow); streamContinuation = nil
                    }
                }
                if boundary == nil || (audioEpoch.map { $0 + Double(outputPosition) / 16_000 >= boundary! } ?? false) {
                    finalize()
                } else {
                    // Keep capture alive for the callback containing the release sample, then drain once.
                    queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                        if completion != nil { failed = true; finalize() }
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
        lock.lock(); let overflow = callbackOverflow; callbackOverflow = false; lock.unlock()
        defer { count = 0; rollCount = 0; endBoundary = nil; audioEpoch = nil; outputPosition = 0 }
        guard !failed, !overflow else { streamContinuation?.finish(throwing: AppError.overflow); streamContinuation = nil; continuation.resume(throwing: AppError.overflow); return }
        flushChunk(); streamContinuation?.finish(); streamContinuation = nil
        do { continuation.resume(returning: try PCM16k(Array(samples.prefix(count)))) }
        catch { continuation.resume(throwing: error) }
    }
}
final class AudioTap: @unchecked Sendable {
    let worker: AudioWorker
    private var expectedSample: AVAudioFramePosition?
    init(_ worker: AudioWorker) { self.worker = worker }
    // Construct outside MainActor isolation: AVAudioEngine invokes this on its audio
    // queue. An inline non-Sendable closure in prepare inherits MainActor in Swift 6.
    func callback() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, time in receive(buffer, time: time) }
    }
    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        if time.isSampleTimeValid {
            if let expectedSample, time.sampleTime != expectedSample { worker.markDiscontinuity() }
            expectedSample = time.sampleTime + Int64(buffer.frameLength)
        }
        worker.receive(buffer, hostSeconds: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
    }
}
@MainActor public final class AudioCapture: CaptureDriver {
    private var engine: AVAudioEngine?
    private var worker: AudioWorker?
    private var warm = true
    private var streamingEnabled = false
    public var showAudioActivity = true
    public var debugTimings = false
    public var recordingActivity: Float { worker?.activity.read() ?? 0 }
    public var firstAudioUptime: Double? { worker?.firstAudioUptime() }
    public var onFailure: (() -> Void)?
    private var changeObserver: NSObjectProtocol?
    public init() {}
    public func prepare(warm: Bool, microphoneUID: String, streaming: Bool = false) throws {
        suspend(); self.warm = warm; streamingEnabled = streaming
        let engine = AVAudioEngine()
        if !microphoneUID.isEmpty {
            guard var device = MicrophoneDevice.available().first(where: { $0.id == microphoneUID })?.deviceID,
                  let unit = engine.inputNode.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw AppError.capture }
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError.capture }
        let worker = try AudioWorker(format: format)
        let tap = AudioTap(worker)
        engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: format, block: tap.callback())
        engine.prepare()
        self.engine = engine; self.worker = worker
        changeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFailure?() }
        }
        if warm { try engine.start() }
    }
    public func begin() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AppError.capture }
        guard let engine, let worker else { throw AppError.notReady }
        if !engine.isRunning { try engine.start() }
        try worker.begin(warm: warm, streaming: streamingEnabled, activity: showAudioActivity, timings: debugTimings)
    }
    public func chunks() -> AsyncThrowingStream<PCM16k, any Error>? { worker?.chunks() }
    public func end() async throws -> PCM16k {
        guard let worker else { throw AppError.capture }
        let boundary = AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime())
        defer { if !warm { engine?.stop() } }
        return try await worker.end(at: boundary)
    }
    public func suspend() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver); self.changeObserver = nil }
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        engine = nil; worker = nil
    }
}
