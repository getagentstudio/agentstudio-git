import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

enum GitWorktreeRemovalPathStatus: Equatable, Sendable {
    case present
    case absent
    case inaccessible
}

struct GitWorktreeRemovalPathObserver: Sendable {
    static let live = Self(inspectPath: inspectGitWorktreeRemovalPath)

    private let inspectPath: @Sendable (URL) -> GitWorktreeRemovalPathStatus

    init(inspectPath: @escaping @Sendable (URL) -> GitWorktreeRemovalPathStatus) {
        self.inspectPath = inspectPath
    }

    func status(of path: URL) -> GitWorktreeRemovalPathStatus {
        inspectPath(path)
    }
}

func inspectGitWorktreeRemovalPath(at path: URL) -> GitWorktreeRemovalPathStatus {
    var fileStatus = stat()
    let result = path.path.withCString { pathPointer in
        lstat(pathPointer, &fileStatus)
    }
    guard result != 0 else {
        return .present
    }

    let errorNumber = errno
    if errorNumber == ENOENT || errorNumber == ENOTDIR {
        return .absent
    }
    return .inaccessible
}

func administrationRemovalEffect(
    pathStatus: GitWorktreeRemovalPathStatus,
    pruneFailed: Bool
) -> GitRemovalEffect {
    switch pathStatus {
    case .present:
        return pruneFailed ? .partial : .retained
    case .absent:
        return .removed
    case .inaccessible:
        return .unknown
    }
}

func workingDirectoryRemovalEffect(
    pathStatus: GitWorktreeRemovalPathStatus,
    removeRequested: Bool,
    administration: GitRemovalEffect,
    pruneFailed: Bool
) -> GitRemovalEffect {
    guard removeRequested else {
        return .notRequested
    }

    switch pathStatus {
    case .absent:
        return .removed
    case .inaccessible:
        return .unknown
    case .present:
        guard pruneFailed else {
            return .retained
        }
        switch administration {
        case .removed:
            return .partial
        case .partial, .retained:
            return .retained
        case .unknown, .notRequested:
            return .unknown
        }
    }
}

struct ResolvedWorktreeRemovalRequest: Sendable {
    let repositoryPath: URL
    let worktreeID: GitWorktreeID
}

struct WorktreeDirtiness: Sendable {
    var hasStagedChanges = false
    var hasDirtyTrackedChanges = false
    var hasUntrackedFiles = false
}

func worktreeDirtiness(at path: URL) throws -> WorktreeDirtiness {
    var dirtiness = WorktreeDirtiness()
    let largeFilePointerCleanliness = LibGit2LargeFilePointerCleanliness()
    try LibGit2Runtime.shared.ensureInitialized()
    var repository: OpaquePointer?
    let openResult = path.path.withCString { pathPointer in
        git_repository_open_ext(&repository, pathPointer, 0, nil)
    }
    guard openResult >= 0, let repository else {
        throw repositoryOpenFailure(code: openResult, path: path)
    }
    defer { git_repository_free(repository) }

    var options = git_status_options()
    let optionsResult = git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
    guard optionsResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: optionsResult)
    }
    options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue

    var statusList: OpaquePointer?
    let statusResult = git_status_list_new(&statusList, repository, &options)
    guard statusResult >= 0, let statusList else {
        throw LibGit2ErrorCapture.failure(code: statusResult)
    }
    defer { git_status_list_free(statusList) }

    for index in 0..<git_status_list_entrycount(statusList) {
        guard let entry = git_status_byindex(statusList, index) else {
            continue
        }
        let flags = entry.pointee.status
        if flags.containsAny(indexStatusFlags) || flags.containsAny([GIT_STATUS_CONFLICTED]) {
            dirtiness.hasStagedChanges = true
        }
        if flags.containsAny(dirtyWorktreeStatusFlags),
            !isCleanLargeFileWorktreeModification(
                entry: entry.pointee,
                repository: repository,
                cleanliness: largeFilePointerCleanliness
            )
        {
            dirtiness.hasDirtyTrackedChanges = true
        }
        if flags.containsAny([GIT_STATUS_WT_NEW]) {
            dirtiness.hasUntrackedFiles = true
        }
    }

    return dirtiness
}

private func isCleanLargeFileWorktreeModification(
    entry: git_status_entry,
    repository: OpaquePointer,
    cleanliness: LibGit2LargeFilePointerCleanliness
) -> Bool {
    let flags = entry.status
    guard flags.containsAny([GIT_STATUS_WT_MODIFIED]),
        !flags.containsAny([
            GIT_STATUS_CONFLICTED,
            GIT_STATUS_WT_DELETED,
            GIT_STATUS_WT_TYPECHANGE,
            GIT_STATUS_WT_RENAMED,
            GIT_STATUS_WT_UNREADABLE,
        ]),
        let delta = entry.index_to_workdir,
        let pathPointer = delta.pointee.new_file.path ?? delta.pointee.old_file.path
    else {
        return false
    }

    return
        (try? cleanliness.isCleanSmudgedFile(
            delta: delta.pointee,
            repository: repository,
            worktreePath: String(cString: pathPointer)
        )) == true
}

extension Optional where Wrapped == String {
    func withOptionalCString<ReturnValue>(_ body: (UnsafePointer<CChar>?) -> ReturnValue) -> ReturnValue {
        switch self {
        case .some(let value):
            return value.withCString(body)
        case .none:
            return body(nil)
        }
    }
}

private let indexStatusFlags: [git_status_t] = [
    GIT_STATUS_INDEX_NEW,
    GIT_STATUS_INDEX_MODIFIED,
    GIT_STATUS_INDEX_DELETED,
    GIT_STATUS_INDEX_RENAMED,
    GIT_STATUS_INDEX_TYPECHANGE,
]

private let dirtyWorktreeStatusFlags: [git_status_t] = [
    GIT_STATUS_WT_MODIFIED,
    GIT_STATUS_WT_DELETED,
    GIT_STATUS_WT_TYPECHANGE,
    GIT_STATUS_WT_RENAMED,
    GIT_STATUS_WT_UNREADABLE,
]

extension git_status_t {
    fileprivate func containsAny(_ masks: [git_status_t]) -> Bool {
        masks.contains { mask in
            rawValue & mask.rawValue != 0
        }
    }
}
