import AgentStudioGitContracts
import Darwin
import Foundation

/// `(device, inode)` identity of a filesystem node, used to detect replacement races and hard links.
struct WorktreeForkEntryIdentity: Hashable, Sendable {
    let deviceID: Int32
    let inode: UInt64

    init(_ info: Darwin.stat) {
        deviceID = info.st_dev
        inode = info.st_ino
    }
}

enum WorktreeForkEntryKind: Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case fifo
    case unixSocket
    case characterDevice
    case blockDevice
    case unknown

    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFDIR: self = .directory
        case S_IFREG: self = .regularFile
        case S_IFLNK: self = .symbolicLink
        case S_IFIFO: self = .fifo
        case S_IFSOCK: self = .unixSocket
        case S_IFCHR: self = .characterDevice
        case S_IFBLK: self = .blockDevice
        default: self = .unknown
        }
    }

    var publicKind: GitWorktreeFilesystemEntryKind {
        switch self {
        case .directory: .directory
        case .regularFile: .regularFile
        case .symbolicLink: .symbolicLink
        case .fifo: .fifo
        case .unixSocket: .unixSocket
        case .characterDevice: .characterDevice
        case .blockDevice: .blockDevice
        case .unknown: .unknown
        }
    }
}

/// Root-descriptor-relative filesystem access. The source and destination root descriptors are the
/// containment authority: every traversal opens directories beneath them with no symlink allowed in
/// the path, so a symlink inserted during traversal fails instead of escaping the root.
enum WorktreeForkDescriptors {
    static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC

    static func openRoot(atCanonicalPath path: URL) -> Result<Int32, WorktreeForkErrno> {
        let descriptor = path.path.withCString { open($0, directoryOpenFlags) }
        return descriptor >= 0 ? .success(descriptor) : .failure(WorktreeForkErrno.current)
    }

    /// Opens `relativePath` (empty for the root itself) beneath `rootDescriptor`.
    static func openDirectory(beneath rootDescriptor: Int32, relativePath: String) -> Result<Int32, WorktreeForkErrno> {
        let path = relativePath.isEmpty ? "." : relativePath
        let descriptor = path.withCString { openat(rootDescriptor, $0, directoryOpenFlags | O_RESOLVE_BENEATH) }
        return descriptor >= 0 ? .success(descriptor) : .failure(WorktreeForkErrno.current)
    }

    static func statEntry(in directoryDescriptor: Int32, name: String) -> Result<Darwin.stat, WorktreeForkErrno> {
        var info = Darwin.stat()
        let result = name.withCString { fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        return result == 0 ? .success(info) : .failure(WorktreeForkErrno.current)
    }

    static func statDescriptor(_ descriptor: Int32) -> Result<Darwin.stat, WorktreeForkErrno> {
        var info = Darwin.stat()
        return fstat(descriptor, &info) == 0 ? .success(info) : .failure(WorktreeForkErrno.current)
    }

    static func lstatPath(_ path: URL) -> Result<Darwin.stat, WorktreeForkErrno> {
        var info = Darwin.stat()
        let result = path.path.withCString { lstat($0, &info) }
        return result == 0 ? .success(info) : .failure(WorktreeForkErrno.current)
    }

    /// Whether something is at `path` (never followed): false only when it does not exist. Any other failure
    /// (no search permission, an I/O error, a non-directory ancestor) is an error, never absence.
    static func existence(_ path: URL) -> Result<Bool, WorktreeForkErrno> {
        switch lstatPath(path) {
        case .success:
            return .success(true)
        case .failure(let failure) where failure.code == ENOENT:
            return .success(false)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func realpathURL(_ path: URL) -> Result<URL, WorktreeForkErrno> {
        guard let resolved = path.path.withCString({ realpath($0, nil) }) else {
            return .failure(WorktreeForkErrno.current)
        }
        defer { free(resolved) }
        return .success(URL(fileURLWithPath: String(cString: resolved), isDirectory: true))
    }

    /// Reads a `readdir` record's name through the record pointer, bounded by `d_namlen`. Records are
    /// variable length, so copying the fixed-size `dirent` (with its 1024-byte `d_name`) reads past the
    /// allocation. Names are UTF-8 on APFS; anything else returns nil.
    static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String? {
        guard let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name),
            let lengthOffset = MemoryLayout<dirent>.offset(of: \dirent.d_namlen)
        else {
            return nil
        }
        let record = UnsafeRawPointer(entry)
        let length = Int(record.loadUnaligned(fromByteOffset: lengthOffset, as: UInt16.self))
        let bytes = UnsafeRawBufferPointer(start: record.advanced(by: nameOffset), count: length)
        return String(bytes: bytes, encoding: .utf8)
    }

    static func joined(_ directoryRelativePath: String, _ name: String) -> String {
        directoryRelativePath.isEmpty ? name : "\(directoryRelativePath)/\(name)"
    }

    static func splitParent(_ relativePath: String) -> (parent: String, name: String) {
        guard let slash = relativePath.lastIndex(of: "/") else {
            return ("", relativePath)
        }
        return (String(relativePath[..<slash]), String(relativePath[relativePath.index(after: slash)...]))
    }
}

struct WorktreeForkErrno: Error, Equatable, Sendable {
    let code: Int32

    static var current: Self {
        Self(code: errno)
    }
}
