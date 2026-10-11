import Foundation

/// Writes explicit synthetic or aggregate check reports; callers choose the schema and contents.
public enum JSONReport {
    public static func write(_ value: Any, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
    }
}
