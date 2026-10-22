import Testing
import AVFoundation
import Foundation
@testable import WhisprLiteCore

@Suite(.serialized) struct CaptureConfigurationTests {
    @Test func completedDeviceSelectionDoesNotTriggerAnotherRebuild() throws {
        let microphone = CaptureInputConfiguration(deviceID: 1, format: try monoFormat(rate: 48_000))
        // A queued setup notification is harmless both before an on-demand start and
        // after a warm start. Rebuilding here repeats CurrentDevice indefinitely.
        #expect(!microphone.requiresRecovery(current: microphone, clientFormat: microphone.format,
            expectsRunning: false, isRunning: false))
        #expect(!microphone.requiresRecovery(current: microphone, clientFormat: microphone.format,
            expectsRunning: true, isRunning: true))
        // Equal-valued formats need not be the same AVAudioFormat object.
        let same = CaptureInputConfiguration(deviceID: 1, format: try monoFormat(rate: 48_000))
        #expect(!microphone.requiresRecovery(current: same, clientFormat: same.format,
            expectsRunning: false, isRunning: false))
    }

    @Test func staleOutputRateAndRealInputChangesStillRequireRecovery() throws {
        let microphone = CaptureInputConfiguration(deviceID: 1, format: try monoFormat(rate: 48_000))
        // The FiiO's 192 kHz playback format must not be accepted as its 48 kHz input.
        #expect(microphone.requiresRecovery(current: microphone, clientFormat: try monoFormat(rate: 192_000),
            expectsRunning: false, isRunning: false))
        let anotherDevice = CaptureInputConfiguration(deviceID: 2, format: microphone.format)
        #expect(microphone.requiresRecovery(current: anotherDevice, clientFormat: microphone.format,
            expectsRunning: false, isRunning: false))
        let anotherRate = CaptureInputConfiguration(deviceID: 1, format: try monoFormat(rate: 44_100))
        #expect(microphone.requiresRecovery(current: anotherRate, clientFormat: anotherRate.format,
            expectsRunning: false, isRunning: false))
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let anotherChannelCount = CaptureInputConfiguration(deviceID: 1, format: stereo)
        #expect(microphone.requiresRecovery(current: anotherChannelCount, clientFormat: stereo,
            expectsRunning: false, isRunning: false))
        #expect(microphone.requiresRecovery(current: nil, clientFormat: microphone.format,
            expectsRunning: false, isRunning: false))
    }

    @Test func stoppedRecordingOrWarmEngineNeedsRecoveryEvenWithTheSameFormat() throws {
        let microphone = CaptureInputConfiguration(deviceID: 1, format: try monoFormat(rate: 48_000))
        #expect(microphone.requiresRecovery(current: microphone, clientFormat: microphone.format,
            expectsRunning: true, isRunning: false))
    }

    @Test func savedUSBMicrophoneIsFoundOnAnotherPort() {
        let saved = "AppleUSBAudioEngine:TEST:TEST Mic:20120000:3"
        let moved = MicrophoneDevice(id: "AppleUSBAudioEngine:TEST:TEST Mic:20110000:3", name: "TEST Mic", deviceID: 7)
        let builtIn = MicrophoneDevice(id: "BuiltInMicrophoneDevice", name: "Built-in", deviceID: 8)
        let output = MicrophoneDevice(id: "AppleUSBAudioEngine:TEST:TEST Mic:20110000:2", name: "TEST Mic", deviceID: 9)
        #expect(MicrophoneDevice.saved(saved, in: [builtIn, moved, output])?.deviceID == 7)
        let exact = MicrophoneDevice(id: saved, name: "TEST Mic", deviceID: 6)
        #expect(MicrophoneDevice.saved(saved, in: [moved, exact])?.deviceID == 6)
        // Two identical microphones on other ports are ambiguous; other UIDs never match loosely.
        let twin = MicrophoneDevice(id: "AppleUSBAudioEngine:TEST:TEST Mic:20130000:3", name: "TEST Mic", deviceID: 10)
        #expect(MicrophoneDevice.saved(saved, in: [moved, twin]) == nil)
        #expect(MicrophoneDevice.saved("BuiltInMicrophoneDevice", in: [moved]) == nil)
        #expect(MicrophoneDevice.saved("AppleUSBAudioEngine:OTHER:Mic:20120000:3", in: [moved]) == nil)
    }

    /// Explicit native check: prepares only, never starts the microphone or stores audio.
    /// Run with different input/output rates to reproduce the original setup failure.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WHISPR_CAPTURE_FORMAT_CHECK"] == "1"),
                     arguments: [false, true])
    func nativePreparationKeepsUnchangedInputReady(lowLatency: Bool) async throws {
        let uid = try #require(ProcessInfo.processInfo.environment["WHISPR_CAPTURE_MICROPHONE_UID"])
        for microphoneUID in ["", uid] {
            let capture = AudioCapture()
            defer { capture.suspend() }
            var failures = 0
            capture.onFailure = { failures += 1 }
            var preferences = Preferences()
            preferences.microphoneUID = microphoneUID
            preferences.lowLatencyCapture = lowLatency
            preferences.warmCapture = false
            // Repeat on the same owner to include observer replacement and stale events.
            for _ in 0..<3 {
                try capture.prepare(CaptureOptions(preferences))
                try await Task.sleep(for: .milliseconds(500))
                #expect(failures == 0)
            }
        }
    }

    /// A USB microphone can reappear seconds after recovery gave up on it. A private aggregate
    /// of an existing input, visible only to this process, stands in for it reconnecting.
    /// Prepares and lists devices only; never starts the microphone.
    @MainActor @Test func failedPreparationReportsAMicrophoneAppearing() async throws {
        guard let input = MicrophoneDevice.available().first else { return }
        let capture = AudioCapture()
        defer { capture.suspend() }
        var failures = 0
        capture.onFailure = { failures += 1 }
        var preferences = Preferences()
        preferences.microphoneUID = "AppleUSBAudioEngine:TEST:TEST Mic:20120000:3"
        #expect(throws: AppError.capture) { try capture.prepare(CaptureOptions(preferences)) }
        // Touching an engine's input adds its own private aggregate, which is not a microphone.
        let engine = AVAudioEngine()
        _ = engine.inputNode.audioUnit
        try await Task.sleep(for: .milliseconds(300))
        #expect(failures == 0)
        #expect(!MicrophoneDevice.available().contains { $0.id.hasPrefix(MicrophoneDevice.privateAggregatePrefix) })

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "TEST-WhisprLite-\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "TEST Mic",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: input.id]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try #require(AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr)
        defer { AudioHardwareDestroyAggregateDevice(device) }
        for _ in 0..<40 where failures == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(failures == 1)
    }
}
