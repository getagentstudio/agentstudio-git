import AgentStudioGitContracts
import Darwin
import Foundation

/// Metadata rules for nodes that have no regular-file CoW payload (directories, symlinks, FIFOs) and the
/// comparison that decides whether a cloned regular file lost metadata that must be reported or failed.
enum WorktreeForkEntryMetadata {
    /// User-visible flags that must survive; compression, tracking, and dataless bits describe storage.
    static let reproducibleFlagMask = UInt32(
        UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_OPAQUE | UF_HIDDEN | SF_ARCHIVED | SF_IMMUTABLE | SF_APPEND)
    static let permissionMask: mode_t = 0o1777

    /// Reproduces ACL, extended attributes, flags, mode, and timestamps from `source` onto `destination`.
    /// Ownership the caller cannot assign is returned as normalization rather than attempted.
    static func copyInodeMetadata(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        sourceInfo: Darwin.stat,
        relativePath: String
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        try copyExtendedAttributes(from: sourceDescriptor, to: destinationDescriptor, relativePath: relativePath)
        try copyAccessControlList(from: sourceDescriptor, to: destinationDescriptor, relativePath: relativePath)
        guard fchmod(destinationDescriptor, sourceInfo.st_mode & (permissionMask | S_ISUID | S_ISGID)) == 0 else {
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        var times = [sourceInfo.st_atimespec, sourceInfo.st_mtimespec]
        guard futimens(destinationDescriptor, &times) == 0 else {
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        let flags = sourceInfo.st_flags & reproducibleFlagMask
        if flags != 0, fchflags(destinationDescriptor, flags) != 0 {
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        switch WorktreeForkDescriptors.statDescriptor(destinationDescriptor) {
        case .success(let destinationInfo):
            return try normalization(source: sourceInfo, destination: destinationInfo, relativePath: relativePath)
        case .failure(let failure):
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: failure.code)
        }
    }

    /// Copies every extended attribute through descriptors so directories, symlinks (`O_SYMLINK`), and FIFOs
    /// share one path. A node kind that cannot carry attributes reports `ENOTSUP` and has none to lose.
    /// A kernel-managed attribute the destination already carries (for example provenance) is accepted.
    static func copyExtendedAttributes(
        from source: Int32,
        to destination: Int32,
        relativePath: String
    ) throws(GitWorktreeForkError) {
        let namesSize = flistxattr(source, nil, 0, 0)
        if namesSize < 0, errno == ENOTSUP {
            return
        }
        guard namesSize >= 0 else {
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        guard namesSize > 0 else {
            return
        }
        var names = [CChar](repeating: 0, count: namesSize)
        guard flistxattr(source, &names, names.count, 0) == namesSize else {
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        for name in names.split(separator: 0).map({ Array($0) + [0] }) {
            let valueSize = fgetxattr(source, name, nil, 0, 0, 0)
            guard valueSize >= 0 else {
                throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
            }
            var value = [UInt8](repeating: 0, count: valueSize)
            guard fgetxattr(source, name, &value, value.count, 0, 0) == valueSize else {
                throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
            }
            if fsetxattr(destination, name, value, value.count, 0, 0) != 0 {
                let failureCode = errno
                guard failureCode == EPERM, fgetxattr(destination, name, nil, 0, 0, 0) >= 0 else {
                    throw .entryFailed(
                        relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: failureCode)
                }
            }
        }
    }

    private static func copyAccessControlList(
        from source: Int32,
        to destination: Int32,
        relativePath: String
    ) throws(GitWorktreeForkError) {
        guard let accessControlList = acl_get_fd_np(source, ACL_TYPE_EXTENDED) else {
            // ENOENT: no extended ACL. ENOTSUP: the node kind cannot carry one.
            guard errno == ENOENT || errno == ENOTSUP else {
                throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
            }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        guard acl_set_fd_np(destination, accessControlList, ACL_TYPE_EXTENDED) == 0 else {
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }

    /// Compares a realized node with its source. Ownership and setuid/setgid loss are reportable
    /// normalization; any other permission or flag loss is a failure.
    static func normalization(
        source: Darwin.stat,
        destination: Darwin.stat,
        relativePath: String
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        guard source.st_mode & permissionMask == destination.st_mode & permissionMask,
            source.st_flags & reproducibleFlagMask == destination.st_flags & reproducibleFlagMask
        else {
            throw .entryFailed(relativePath: relativePath, reason: .metadataNotReproducible, errorNumber: nil)
        }
        var normalized: [GitWorktreeMaterializationNormalizedEntry] = []
        if source.st_uid != destination.st_uid {
            normalized.append(.init(relativePath: relativePath, attribute: .ownerUser, reason: .ownershipNotAssignable))
        }
        if source.st_gid != destination.st_gid {
            normalized.append(
                .init(relativePath: relativePath, attribute: .ownerGroup, reason: .ownershipNotAssignable))
        }
        if source.st_mode & S_ISUID != 0, destination.st_mode & S_ISUID == 0 {
            normalized.append(
                .init(relativePath: relativePath, attribute: .setUserIDBit, reason: .clearedByCopyOnWriteClone))
        }
        if source.st_mode & S_ISGID != 0, destination.st_mode & S_ISGID == 0 {
            normalized.append(
                .init(relativePath: relativePath, attribute: .setGroupIDBit, reason: .clearedByCopyOnWriteClone))
        }
        return normalized
    }
}

/// Thread-scoped denial of dataless-file materialization for one leaf worker. A worker that cannot
/// establish and verify the denial must not clone, because the process default could download content.
enum WorktreeForkDatalessPolicy {
    struct PriorPolicy: Equatable, Sendable {
        let value: Int32
    }

    static func denyMaterializationOnCurrentThread() -> Result<PriorPolicy, WorktreeForkErrno> {
        let prior = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard prior >= 0 else {
            return .failure(WorktreeForkErrno.current)
        }
        guard
            setiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                IOPOL_SCOPE_THREAD,
                IOPOL_MATERIALIZE_DATALESS_FILES_OFF
            ) == 0
        else {
            return .failure(WorktreeForkErrno.current)
        }
        let established = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard established == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, prior)
            return .failure(WorktreeForkErrno(code: EPERM))
        }
        return .success(PriorPolicy(value: prior))
    }

    static func restore(_ prior: PriorPolicy) {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, prior.value)
    }

    /// Runs `body` with materialization denied on the current thread and restores the prior policy on every
    /// exit path. Failing to establish the denial fails the operation instead of running unprotected.
    static func withMaterializationDenied<ReturnValue>(
        reportPath: String,
        _ body: () throws(GitWorktreeForkError) -> ReturnValue
    ) throws(GitWorktreeForkError) -> ReturnValue {
        let prior: PriorPolicy
        switch denyMaterializationOnCurrentThread() {
        case .success(let established):
            prior = established
        case .failure(let failure):
            throw .entryFailed(relativePath: reportPath, reason: .datalessPolicyUnavailable, errorNumber: failure.code)
        }
        defer { restore(prior) }
        return try body()
    }

    static func currentThreadPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }
}
