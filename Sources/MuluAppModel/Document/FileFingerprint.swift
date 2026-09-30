import Foundation

/// What identifies the file as it was opened: size, modification time and (device, inode).
/// Writing refuses when the input no longer matches (GUI_SPEC §5.11).
public struct FileFingerprint: Sendable, Hashable {
    public var size: Int
    public var modified: Date
    public var device: UInt64
    public var inode: UInt64

    public init(size: Int, modified: Date, device: UInt64, inode: UInt64) {
        self.size = size
        self.modified = modified
        self.device = device
        self.inode = inode
    }

    /// stat(2) of the file (symbolic links followed).
    public static func of(_ url: URL) throws -> FileFingerprint {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let t = st.st_mtimespec
        return FileFingerprint(
            size: Int(st.st_size),
            modified: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9),
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(st.st_ino))
    }
}

enum FileIdentity {
    /// (device, inode) of an existing file, symbolic links followed.
    static func of(_ url: URL) -> (UInt64, UInt64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino))
    }

    /// Same file: equal paths once standardized with symbolic links resolved, or the same
    /// (device, inode) (hard links, case-insensitive names).
    static func same(_ a: URL, _ b: URL) -> Bool {
        let ua = a.standardizedFileURL.resolvingSymlinksInPath()
        let ub = b.standardizedFileURL.resolvingSymlinksInPath()
        if ua.path == ub.path { return true }
        if let x = of(a), let y = of(b), x == y { return true }
        return false
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The whole file as bytes, read straight into the array (no intermediate `Data` copy).
    static func readBytes(_ url: URL) throws -> [UInt8] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return [UInt8](unsafeUninitializedCapacity: data.count) { buffer, count in
            count = data.copyBytes(to: buffer)
        }
    }

    /// Whether `bytes` starts with `prefix` (memcmp, no copies).
    static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        guard !prefix.isEmpty else { return true }
        return bytes.withUnsafeBufferPointer { b in
            prefix.withUnsafeBufferPointer { p in memcmp(b.baseAddress!, p.baseAddress!, p.count) == 0 }
        }
    }

    /// A hidden temporary name next to `url` (same folder, so the rename stays on one volume).
    static func temporaryURL(next url: URL) -> URL {
        let dest = url.standardizedFileURL
        return dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).mulu-\(getpid())-\(UUID().uuidString).tmp")
    }

    /// Creates `url` (it must not exist) with `bytes` and flushes it to the disk (F_FULLFSYNC).
    static func writeNewFile(_ bytes: UnsafeRawBufferPointer, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else {
            throw WriteError.io("cannot write \(url.deletingLastPathComponent().path): \(String(cString: strerror(errno)))")
        }
        var written = 0
        var failure: Int32 = 0
        while written < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
            if n < 0 {
                if errno == EINTR { continue }
                failure = errno
                break
            }
            written += n
        }
        if failure == 0, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { failure = errno }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure != 0 {
            try? FileManager.default.removeItem(at: url)
            throw WriteError.io("cannot write \(url.deletingLastPathComponent().path): \(String(cString: strerror(failure)))")
        }
    }

    /// Renames `tmp` over `url` (atomic; an existing file at `url` is replaced).
    static func moveIntoPlace(_ tmp: URL, to url: URL) throws {
        let dest = url.standardizedFileURL
        if rename(tmp.path, dest.path) != 0 {
            let reason = String(cString: strerror(errno))
            throw WriteError.io("cannot write \(dest.path): \(reason)")
        }
    }

    /// Writes `bytes` to a temporary file next to `url` and renames it into place (never a
    /// partial file; an existing file at `url` is replaced).
    static func writeAtomically(_ bytes: [UInt8], to url: URL) throws {
        let tmp = temporaryURL(next: url)
        do {
            try bytes.withUnsafeBytes { try writeNewFile($0, to: tmp) }
            try moveIntoPlace(tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
