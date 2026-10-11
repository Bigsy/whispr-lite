import Foundation

public enum ReportStatistics {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    public static func nearestRank(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty, (0...1).contains(fraction) else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
}

/// Writes explicit synthetic or aggregate check reports; callers choose the schema and contents.
public enum JSONReport {
    public static func write(_ value: Any, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let report: Any
        if var dictionary = value as? [String: Any] {
            dictionary["percentile_method"] = "nearest-rank"
            report = dictionary
        } else { report = value }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
    }
}
