import Darwin
import Foundation

/// Whether two regular files are the same counterpart: equal bytes, permission bits, user-visible flags,
/// extended attributes, and extended ACL. Used to tell a strict clone of a source file from a different file
/// that happens to share its name.
///
/// Comparing reads payload bytes, and strict CoW never authorizes a download: every comparison runs with
/// dataless materialization denied, and a dataless file fails closed before any read. Files are opened from
/// already-open descriptors or descriptor-relative beneath a no-symlink administration root.
enum WorktreeForkFileEquivalence {
    /// A file named by the administration root it lies beneath and its `/`-separated path below that root.
    struct ContainedFile: Equatable, Sendable {
        let root: URL
        let remainder: String
    }

    /// Kernel-managed attributes a copy may carry differently from its original.
    private static let kernelManagedAttributes: Set<String> = ["com.apple.provenance"]
    private static let readChunkSize = 64 * 1024

    /// Compares two already-open files.
    static func isEquivalent(_ first: Int32, _ second: Int32, reportPath: String) throws(GitWorktreeForkError) -> Bool {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            try compare(first, second, reportPath: reportPath)
        }
    }

    /// Compares two contained files; a file that is missing, or a symlink, is never equivalent.
    static func isEquivalent(
        _ first: ContainedFile,
        _ second: ContainedFile,
        reportPath: String
    ) throws(GitWorktreeForkError) -> Bool {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            guard let firstDescriptor = try open(first, reportPath: reportPath) else {
                return false
            }
            defer { close(firstDescriptor) }
            guard let secondDescriptor = try open(second, reportPath: reportPath) else {
                return false
            }
            defer { close(secondDescriptor) }
            return try compare(firstDescriptor, secondDescriptor, reportPath: reportPath)
        }
    }

    /// Opens `file` beneath its root with no symlink anywhere in the path; nil when it is missing or a symlink.
    static func open(_ file: ContainedFile, reportPath: String) throws(GitWorktreeForkError) -> Int32? {
        let root: Int32
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: file.root) {
        case .success(let descriptor):
            root = descriptor
        case .failure(let failure) where failure.code == ENOENT:
            return nil
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
        defer { close(root) }
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(file.remainder)
        let parent: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: root, relativePath: parentPath) {
        case .success(let descriptor):
            parent = descriptor
        case .failure(let failure) where failure.code == ENOENT:
            return nil
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
        defer { close(parent) }
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP {
                return nil
            }
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: errno)
        }
        return descriptor
    }

    /// Runs with materialization denied; checks both files for a dataless payload before reading either.
    private static func compare(_ first: Int32, _ second: Int32, reportPath: String) throws(GitWorktreeForkError)
        -> Bool
    {
        try WorktreeForkDatalessGuardedRead.rejectDataless(first, reportPath: reportPath)
        try WorktreeForkDatalessGuardedRead.rejectDataless(second, reportPath: reportPath)
        guard case .success(let firstInfo) = WorktreeForkDescriptors.statDescriptor(first),
            case .success(let secondInfo) = WorktreeForkDescriptors.statDescriptor(second)
        else {
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: errno)
        }
        guard firstInfo.st_mode & S_IFMT == S_IFREG, secondInfo.st_mode & S_IFMT == S_IFREG,
            firstInfo.st_size == secondInfo.st_size,
            firstInfo.st_mode & WorktreeForkEntryMetadata.permissionMask
                == secondInfo.st_mode & WorktreeForkEntryMetadata.permissionMask,
            firstInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask
                == secondInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask,
            let firstAttributes = extendedAttributes(first), let secondAttributes = extendedAttributes(second),
            firstAttributes == secondAttributes,
            accessControlText(first) == accessControlText(second)
        else {
            return false
        }
        return contentsMatch(first, second, size: Int(firstInfo.st_size))
    }

    private static func contentsMatch(_ first: Int32, _ second: Int32, size: Int) -> Bool {
        var firstBuffer = [UInt8](repeating: 0, count: readChunkSize)
        var secondBuffer = [UInt8](repeating: 0, count: readChunkSize)
        var offset = 0
        while offset < size {
            let length = min(readChunkSize, size - offset)
            let firstRead = pread(first, &firstBuffer, length, off_t(offset))
            let secondRead = pread(second, &secondBuffer, length, off_t(offset))
            guard firstRead == length, secondRead == length, firstBuffer[0..<length] == secondBuffer[0..<length] else {
                return false
            }
            offset += length
        }
        return true
    }

    /// Name to value, without kernel-managed attributes; nil when the attributes cannot be read.
    private static func extendedAttributes(_ descriptor: Int32) -> [String: [UInt8]]? {
        let namesSize = flistxattr(descriptor, nil, 0, 0)
        guard namesSize >= 0 else {
            return errno == ENOTSUP ? [:] : nil
        }
        var names = [CChar](repeating: 0, count: namesSize)
        guard namesSize == 0 || flistxattr(descriptor, &names, names.count, 0) == namesSize else {
            return nil
        }
        var attributes: [String: [UInt8]] = [:]
        for nameBytes in names.split(separator: 0) {
            guard let name = String(bytes: nameBytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                return nil
            }
            guard !kernelManagedAttributes.contains(name) else {
                continue
            }
            let valueSize = fgetxattr(descriptor, name, nil, 0, 0, 0)
            guard valueSize >= 0 else {
                return nil
            }
            var value = [UInt8](repeating: 0, count: valueSize)
            guard fgetxattr(descriptor, name, &value, value.count, 0, 0) == valueSize else {
                return nil
            }
            attributes[name] = value
        }
        return attributes
    }

    private static func accessControlText(_ descriptor: Int32) -> String? {
        guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        guard let text = acl_to_text(accessControlList, nil) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }
}
