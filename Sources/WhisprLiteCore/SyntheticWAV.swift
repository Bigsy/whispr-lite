import Foundation
import AVFoundation

public extension PCM16k {
    init(contentsOfWAV file: URL) throws {
        let input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.processingFormat.sampleRate == Double(Self.rate),
              input.processingFormat.channelCount == 1,
              input.length <= Self.maximumSamples,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: AVAudioFrameCount(input.length))
        else { throw AppError.invalidAudio }
        try input.read(into: buffer)
        guard let samples = buffer.floatChannelData else { throw AppError.invalidAudio }
        try self.init(Array(UnsafeBufferPointer(start: samples[0], count: Int(buffer.frameLength))))
    }

    static func corpus(in directory: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw AppError.invalidAudio }
        return files
    }
}
