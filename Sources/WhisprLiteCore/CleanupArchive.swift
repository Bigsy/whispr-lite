import Foundation

/// Small tar reader for official llama.cpp archives. Validates the entire archive before
/// extraction; no archive-supplied path or link is ever handed to a shell or tar utility.
enum CleanupArchive {
    static let maximumBytes = 200 * 1024 * 1024
    private struct Entry {
        var path: String
        var type: UInt8
        var contents: Range<Int>
        var link: String
        var executable: Bool
    }
    static func extract(_ data: Data, to destination: URL, root: String) throws {
        var entries: [Entry] = [], offset = 0, total: Int64 = 0, headers = 0
        var extended: [String: String] = [:]
        var paths = Set<String>()
        func invalid() -> CleanupEngineFailure { .init("Unsafe or unsupported cleanup runtime archive") }
        func string(_ range: Range<Int>) throws -> String {
            let bytes = data[range].prefix { $0 != 0 }
            guard let value = String(data: Data(bytes), encoding: .utf8) else { throw invalid() }
            return value
        }
        func number(_ range: Range<Int>) throws -> Int {
            let value = try string(range).trimmingCharacters(in: .whitespaces)
            guard value.allSatisfy({ ("0"..."7").contains(String($0)) }),
                  let number = Int(value.isEmpty ? "0" : value, radix: 8) else { throw invalid() }
            return number
        }
        while offset + 512 <= data.count {
            try Task.checkCancellation()
            let header = offset
            if data[header..<(header + 512)].allSatisfy({ $0 == 0 }) { break }
            headers += 1
            guard headers <= 500 else { throw invalid() }
            let checksum = try number((header + 148)..<(header + 156))
            let actual = data[header..<(header + 512)].enumerated().reduce(0) { sum, item in
                sum + ((148..<156).contains(item.offset) ? 32 : Int(item.element))
            }
            guard checksum == actual else { throw invalid() }
            let size = try number((header + 124)..<(header + 136))
            guard size <= maximumBytes, header + 512 + size <= data.count else { throw invalid() }
            let contents = (header + 512)..<(header + 512 + size)
            let type = data[header + 156]
            offset = header + 512 + ((size + 511) / 512) * 512
            guard offset <= data.count else { throw invalid() }
            if type == 120 || type == 103 { // POSIX per-file/global extended metadata.
                let values = try pax(Data(data[contents]))
                guard values.keys.allSatisfy({ !$0.contains("sparse") && $0 != "size" }),
                      type != 103 || (values["path"] == nil && values["linkpath"] == nil) else { throw invalid() }
                if type == 120 { extended = values }
                continue
            }
            let name = try string(header..<(header + 100))
            let prefix = try string((header + 345)..<(header + 500))
            var path = extended["path"] ?? (prefix.isEmpty ? name : prefix + "/" + name)
            while path.hasSuffix("/") { path.removeLast() }
            let link = try extended["linkpath"] ?? string((header + 157)..<(header + 257))
            extended = [:]
            guard CleanupFiles.safeRelativePath(path), path == root || path.hasPrefix(root + "/"),
                  paths.insert(path).inserted, [0, 48, 50, 53].contains(type),
                  type != 50 || CleanupFiles.safeRelativePath(link),
                  (type == 0 || type == 48) || size == 0 else { throw invalid() }
            total += Int64(size)
            guard total <= maximumBytes else { throw invalid() }
            entries.append(.init(path: path, type: type, contents: contents, link: link,
                                 executable: try number((header + 100)..<(header + 108)) & 0o111 != 0))
        }
        guard !entries.isEmpty, extended.isEmpty else { throw invalid() }
        let links = Set(entries.filter { $0.type == 50 }.map(\.path))
        for entry in entries {
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !links.contains(parent) else { throw invalid() }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        try PrivateFiles.ensureDirectory(at: destination)
        // Materialise regular files before links, so symlinks cannot redirect a write.
        for entry in entries where entry.type != 50 {
            let file = destination.appendingPathComponent(entry.path)
            guard CleanupFiles.contained(file, in: destination) else { throw invalid() }
            if entry.type == 53 { try PrivateFiles.ensureDirectory(at: file) }
            else {
                try PrivateFiles.ensureDirectory(at: file.deletingLastPathComponent())
                try PrivateFiles.writeAtomically(Data(data[entry.contents]), to: file)
                try FileManager.default.setAttributes([.posixPermissions: entry.executable ? 0o700 : 0o600], ofItemAtPath: file.path)
            }
        }
        for entry in entries where entry.type == 50 {
            let file = destination.appendingPathComponent(entry.path)
            try PrivateFiles.ensureDirectory(at: file.deletingLastPathComponent())
            guard CleanupFiles.contained(file.deletingLastPathComponent().appendingPathComponent(entry.link), in: destination) else {
                throw invalid()
            }
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: entry.link)
        }
    }
    private static func pax(_ data: Data) throws -> [String: String] {
        var result: [String: String] = [:], offset = 0
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 32),
                  let count = Int(String(decoding: data[offset..<space], as: UTF8.self)),
                  count > space - offset + 2, count <= data.count - offset,
                  data[offset + count - 1] == 10,
                  let record = String(data: data[(space + 1)..<(offset + count - 1)], encoding: .utf8),
                  let equals = record.firstIndex(of: "=") else {
                throw CleanupEngineFailure("Invalid cleanup runtime archive metadata")
            }
            result[String(record[..<equals])] = String(record[record.index(after: equals)...])
            offset += count
        }
        return result
    }
}
