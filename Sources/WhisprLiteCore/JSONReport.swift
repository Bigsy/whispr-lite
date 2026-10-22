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

/// Identifies the Mac that produced a result so measurements from different machines
/// (e.g. an M4 Pro and an M1 Max) cannot be mistaken for each other.
public enum MachineInfo {
    public static var current: [String: Any] {
        let memory = number("hw.memsize")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "chip": string("machdep.cpu.brand_string") ?? "unknown",
            "model": string("hw.model") ?? "unknown",
            "memory_gb": memory.map { Int((Double($0) / 1_073_741_824).rounded()) } ?? NSNull(),
            "performance_cores": number("hw.perflevel0.physicalcpu") ?? NSNull(),
            "efficiency_cores": number("hw.perflevel1.physicalcpu") ?? NSNull(),
            "macos": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "macos_build": string("kern.osversion") ?? "unknown",
        ]
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }

    private static func number(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var value: Int32 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int64(value) : nil
        case 8:
            var value: Int64 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
        default:
            return nil
        }
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
            dictionary["machine"] = dictionary["machine"] ?? MachineInfo.current
            report = dictionary
        } else { report = value }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
    }
}
