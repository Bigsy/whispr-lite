import Foundation
import Darwin

enum PrivateFiles {
    static func directoryExists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadNoPermission)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw CocoaError(.fileReadNoPermission) }
        return true
    }

    static func regularFileExists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadNoPermission)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw CocoaError(.fileReadNoPermission) }
        return true
    }

    static func ensureDirectory(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw CocoaError(.fileWriteNoPermission) }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } else { throw CocoaError(.fileWriteNoPermission) }
        guard chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    static func ensureFile(at url: URL) throws {
        if try !regularFileExists(at: url) {
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            close(descriptor)
        }
        guard try regularFileExists(at: url), chmod(url.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        _ = try regularFileExists(at: url) // Reject existing symlinks and non-files.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try ensureFile(at: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
