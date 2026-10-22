import Foundation
import Testing
@testable import WhisprLiteCore

@Suite struct CleanupArchiveTests {
    private let root = "llama-b11564"
    private func entry(_ path: String, type: UInt8 = 48, text: String = "", link: String = "") -> Data {
        var header = Data(repeating: 0, count: 512)
        func field(_ offset: Int, _ count: Int, _ value: String) {
            header.replaceSubrange(offset..<(offset + count), with: Data(value.utf8).prefix(count) + Data(repeating: 0, count: max(0, count - value.utf8.count)))
        }
        func octal(_ offset: Int, _ count: Int, _ value: Int) {
            let number = String(value, radix: 8)
            field(offset, count, String(repeating: "0", count: count - number.count - 1) + number + "\0")
        }
        field(0, 100, path); octal(100, 8, 0o755); octal(124, 12, text.utf8.count)
        header[156] = type; field(157, 100, link); field(257, 6, "ustar\0"); field(263, 2, "00")
        field(148, 8, "        ")
        field(148, 8, String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ")
        let contents = Data(text.utf8)
        return header + contents + Data(repeating: 0, count: (512 - contents.count % 512) % 512)
    }
    private func archive(_ contents: Data) -> Data { contents + Data(repeating: 0, count: 1024) }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-archive-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func regularFilesExecutablesAndInternalLibraryLinksExtractCorrectly() throws {
        let temporary = try temporary(); defer { try? FileManager.default.removeItem(at: temporary) }
        let bytes = entry(root + "/", type: 53)
            + entry(root + "/llama-server", text: "synthetic executable")
            + entry(root + "/libnative.1.dylib", text: "synthetic library")
            + entry(root + "/libnative.dylib", type: 50, link: "libnative.1.dylib")
        let destination = temporary.appendingPathComponent("extract")
        try CleanupArchive.extract(archive(bytes), to: destination, root: root)
        #expect(try String(contentsOf: destination.appendingPathComponent(root + "/libnative.dylib"), encoding: .utf8) == "synthetic library")
        #expect(FileManager.default.isExecutableFile(atPath: destination.appendingPathComponent(root + "/llama-server").path))
    }

    @Test func unsafePathsLinksSpecialFilesAndTruncationFailBeforeExtraction() throws {
        let temporary = try temporary(); defer { try? FileManager.default.removeItem(at: temporary) }
        var corrupt = archive(entry(root + "/llama-server", text: "synthetic")); corrupt[0] ^= 1
        let cases = [
            archive(entry("/outside", text: "bad")),
            archive(entry(root + "/../outside", text: "bad")),
            archive(entry("another-root/llama-server", text: "bad")),
            archive(entry(root + "/link", type: 50, link: "../outside")),
            archive(entry(root + "/link", type: 50, link: "/outside")),
            archive(entry(root + "/link", type: 49, link: "llama-server")), // hard link
            archive(entry(root + "/device", type: 51)),
            archive(entry(root + "/redirect", type: 50, link: "subdir") + entry(root + "/redirect/llama-server", text: "bad")),
            archive(entry("PaxHeader", type: 120, text: "6 a=1\n9223372036854775807 x=y\n") + entry(root + "/llama-server", text: "bad")),
            Data(entry(root + "/llama-server", text: "truncated").prefix(515)), corrupt
        ]
        for (index, bytes) in cases.enumerated() {
            let destination = temporary.appendingPathComponent("case-\(index)")
            #expect(throws: CleanupEngineFailure.self) { try CleanupArchive.extract(bytes, to: destination, root: root) }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("outside").path))
    }

    @Test func paxNamesAreValidatedAsPathsAndNeverPassedToACommand() throws {
        let temporary = try temporary(); defer { try? FileManager.default.removeItem(at: temporary) }
        func record(_ value: String) -> String {
            var length = value.utf8.count + 3
            while length != value.utf8.count + String(length).count + 2 { length = value.utf8.count + String(length).count + 2 }
            return "\(length) \(value)\n"
        }
        let bytes = entry("PaxHeader", type: 120, text: record("path=\(root)/renamed file")) + entry("placeholder", text: "synthetic")
        let destination = temporary.appendingPathComponent("valid")
        try CleanupArchive.extract(archive(bytes), to: destination, root: root)
        #expect(try String(contentsOf: destination.appendingPathComponent(root + "/renamed file"), encoding: .utf8) == "synthetic")
        let unsafe = entry("PaxHeader", type: 120, text: record("path=../outside")) + entry("placeholder", text: "bad")
        #expect(throws: CleanupEngineFailure.self) {
            try CleanupArchive.extract(archive(unsafe), to: temporary.appendingPathComponent("unsafe"), root: root)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHISPR_CLEANUP_RELEASE_ARCHIVE"] != nil))
    func optionalOfficialReleaseExtractsAndEveryPinnedRuntimeFileMatches() async throws {
        let temporary = try temporary(); defer { try? FileManager.default.removeItem(at: temporary) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = try CleanupService(kit: project, executable: project.appendingPathComponent(".build/debug/WhisprLiteCleanup"),
            directory: temporary.appendingPathComponent("Cleanup"), agent: temporary.appendingPathComponent("agent.plist"))
        let archive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WHISPR_CLEANUP_RELEASE_ARCHIVE"]!)
        #expect(try CleanupFiles.verified(archive, service.stack.llama_server.release.artifact))
        let extracted = try await service.extract(archive, root: service.stack.llama_server.release.directory)
        try service.verifyRuntime(extracted)
        let binary = extracted.appendingPathComponent("llama-server")
        let result = try await CleanupProcess.run(binary.path, ["--version"], CleanupStack.runtimeEnvironment())
        #expect(result.status == 0 && result.text.contains(service.stack.llama_server.commit))
    }
}
