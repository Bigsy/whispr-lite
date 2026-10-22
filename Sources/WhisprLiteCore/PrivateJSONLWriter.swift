import Foundation

/// Used only on its PrivateJSONLSink's serial utility queue.
final class PrivateJSONLWriter<Value: Encodable>: @unchecked Sendable {
    enum OversizePolicy { case skip, fail }
    let directory: URL
    private let current: URL
    private let previous: URL
    private let maximumBytes: Int
    private let excludeFromBackup: Bool
    private let oversize: OversizePolicy
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var bytes = 0

    init(directory: URL, fileName: String, previousFileName: String, maximumBytes: Int,
         excludeFromBackup: Bool, oversize: OversizePolicy) {
        self.directory = directory
        current = directory.appendingPathComponent(fileName)
        previous = directory.appendingPathComponent(previousFileName)
        self.maximumBytes = max(1024, maximumBytes)
        self.excludeFromBackup = excludeFromBackup
        self.oversize = oversize
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func close() { try? handle?.close(); handle = nil }

    func deleteAll() throws {
        close(); bytes = 0
        for file in [current, previous] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func write(_ value: Value) throws {
        var data = try encoder.encode(value)
        data.append(10)
        if data.count > maximumBytes {
            switch oversize {
            case .skip: return
            case .fail: throw CocoaError(.fileWriteUnknown)
            }
        }
        if handle == nil { try open() }
        if bytes + data.count > maximumBytes {
            try handle?.close(); handle = nil
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: current, to: previous)
            try open()
        }
        try handle?.write(contentsOf: data)
        bytes += data.count
    }

    private func open() throws {
        try PrivateFiles.ensureDirectory(at: directory)
        if excludeFromBackup {
            var folder = directory, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        }
        try PrivateFiles.ensureFile(at: current)
        handle = try FileHandle(forWritingTo: current)
        bytes = Int(try handle!.seekToEnd())
    }

    deinit { try? handle?.close() }
}
