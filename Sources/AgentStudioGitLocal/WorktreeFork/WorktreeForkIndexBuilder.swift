import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Which tracked entries the one-time stat refresh could not mark clean: they differ from the captured
/// tree, are absent, or are skip-worktree. Every other tracked entry must carry refreshed stat data.
struct WorktreeForkIndexRefreshEvidence: Equatable, Sendable {
    let unrefreshedPaths: Set<String>
    /// Entries that took the clone's `lstat` without hashing because they were provably clean.
    let adoptedPaths: Set<String>
}

/// Rebuilds a repository's index from its captured `HEAD` tree, never from source staging, then refreshes
/// stat data once so later status reads that never refresh the index do not re-hash unchanged files.
struct WorktreeForkIndexBuilder: Sendable {
    private let faults: WorktreeForkFaultInjector

    init(faults: WorktreeForkFaultInjector = .production) {
        self.faults = faults
    }

    func buildIndex(
        worktreePath: URL,
        capturedHead: WorktreeForkCapturedHead?,
        skipWorktreePaths: Set<String>,
        adoption: WorktreeForkAdoptionContext?,
        lockWorktreePath: URL? = nil,
        lockTracker: WorktreeForkLockTracker? = nil
    ) throws(GitWorktreeForkError) -> WorktreeForkIndexRefreshEvidence {
        let repository = try openRepository(worktreePath)
        defer { git_repository_free(repository) }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repository))
        guard let index else {
            throw .gitFailure(.unsupported(message: "repository index unavailable"))
        }
        defer { git_index_free(index) }

        if let capturedHead {
            try readCapturedTree(capturedHead.treeOID, into: index, repository: repository)
        } else {
            // An unborn submodule has no captured tree; its index starts empty.
            try check(git_index_clear(index))
        }
        try applySkipWorktree(skipWorktreePaths, to: index)
        let adoptedPaths =
            try adoption.map { context throws(GitWorktreeForkError) in
                try adoptCleanEntries(context, index: index, worktreePath: worktreePath)
            } ?? []
        let indexLockFact = try WorktreeForkGitHandles.lockFact(
            for: .index(worktreePath: lockWorktreePath ?? worktreePath), repository: repository)
        lockTracker?.beginAttempt(for: [indexLockFact])
        errno = 0
        let writeResult = git_index_write(index)
        let writeErrorNumber = errno
        guard writeResult >= 0 else {
            lockTracker?.recordFailure(for: [indexLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: writeResult,
                    lockFacts: [indexLockFact],
                    systemErrorCode: writeErrorNumber
                ))
        }
        let capturedPaths = capturedPathSpellings(index)
        let refreshPaths = trackedPathsNeedingRefresh(index, excluding: adoptedPaths)
        let unrefreshed =
            refreshPaths.isEmpty
            ? Set<String>()
            : try refreshStatData(
                repository: repository,
                index: index,
                onlyPaths: adoptedPaths.isEmpty ? nil : refreshPaths,
                indexLockFact: indexLockFact,
                lockTracker: lockTracker
            )
        try restoreCapturedPathSpellings(capturedPaths, index: index, lockFact: indexLockFact, lockTracker: lockTracker)
        return WorktreeForkIndexRefreshEvidence(unrefreshedPaths: unrefreshed, adoptedPaths: adoptedPaths)
    }

    /// libgit2 refreshes with the workdir spelling under core.ignorecase. The destination index must
    /// still name captured HEAD exactly, so retain that spelling while preserving refreshed stats.
    private func capturedPathSpellings(_ index: OpaquePointer) -> [String: String] {
        guard git_index_caps(index) & GIT_INDEX_CAPABILITY_IGNORE_CASE.rawValue != 0 else { return [:] }
        var spellings: [String: String] = [:]
        for position in 0..<git_index_entrycount(index) {
            guard let path = git_index_get_byindex(index, position)?.pointee.path else { continue }
            let text = String(cString: path)
            spellings[text.lowercased()] = text
        }
        return spellings
    }

    private func restoreCapturedPathSpellings(
        _ spellings: [String: String], index: OpaquePointer,
        lockFact: GitLockFact, lockTracker: WorktreeForkLockTracker?
    ) throws(GitWorktreeForkError) {
        guard !spellings.isEmpty else { return }
        var replacements: [(String, String)] = []
        for position in 0..<git_index_entrycount(index) {
            guard let pointer = git_index_get_byindex(index, position)?.pointee.path else { continue }
            let path = String(cString: pointer)
            if let captured = spellings[path.lowercased()], path != captured {
                replacements.append((path, captured))
            }
        }
        guard !replacements.isEmpty else { return }
        for (currentPath, capturedPath) in replacements {
            guard var entry = currentPath.withCString({ git_index_get_bypath(index, $0, 0) })?.pointee else {
                throw .validationFailed(reason: .indexTreeMismatch, relativePath: capturedPath)
            }
            let result = capturedPath.withCString { pointer in
                entry.path = pointer
                return git_index_add(index, &entry)
            }
            try check(result)
        }
        lockTracker?.beginAttempt(for: [lockFact])
        errno = 0
        let result = git_index_write(index)
        let errorNumber = errno
        try checkStatRefresh(result, systemErrorCode: errorNumber, lockFact: lockFact, lockTracker: lockTracker)
    }

    /// Gives each provably clean entry the clone's own `lstat` data. The source index only proves
    /// cleanliness; no source stat is copied.
    private func adoptCleanEntries(
        _ context: WorktreeForkAdoptionContext,
        index: OpaquePointer,
        worktreePath: URL
    ) throws(GitWorktreeForkError) -> Set<String> {
        let skipWorktree = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        var adoptable: [String] = []
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position)?.pointee, let pathPointer = entry.path,
                entry.flags_extended & skipWorktree == 0
            else {
                continue
            }
            let path = String(cString: pathPointer)
            let rootPath = WorktreeForkDescriptors.joined(context.nodePrefix, path)
            var capturedOID = entry.id
            if WorktreeForkCleanEntryAdoption.isAdoptable(
                path: path,
                capturedObjectID: oidString(&capturedOID),
                capturedMode: entry.mode,
                sourceIndex: context.sourceIndex,
                plannedStat: context.plannedStats[rootPath],
                cloneVerified: context.verifiedClonePaths.contains(rootPath)
            ) {
                adoptable.append(path)
            }
        }
        var adopted = Set<String>()
        for path in adoptable {
            guard let existing = path.withCString({ git_index_get_bypath(index, $0, 0) })?.pointee,
                case .success(let info) = WorktreeForkDescriptors.lstatPath(worktreePath.appending(path: path))
            else {
                continue
            }
            var updated = existing
            updated.ctime = git_index_time(
                seconds: Int32(truncatingIfNeeded: info.st_ctimespec.tv_sec),
                nanoseconds: UInt32(truncatingIfNeeded: info.st_ctimespec.tv_nsec))
            updated.mtime = git_index_time(
                seconds: Int32(truncatingIfNeeded: info.st_mtimespec.tv_sec),
                nanoseconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec))
            updated.dev = UInt32(truncatingIfNeeded: info.st_dev)
            updated.ino = UInt32(truncatingIfNeeded: info.st_ino)
            updated.uid = info.st_uid
            updated.gid = info.st_gid
            updated.file_size = UInt32(truncatingIfNeeded: info.st_size)
            try check(git_index_add(index, &updated))
            adopted.insert(path)
        }
        return adopted
    }

    private func trackedPathsNeedingRefresh(_ index: OpaquePointer, excluding adopted: Set<String>) -> [String] {
        let skipWorktree = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        var paths: [String] = []
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position)?.pointee, let pathPointer = entry.path,
                entry.flags_extended & skipWorktree == 0
            else {
                continue
            }
            let path = String(cString: pathPointer)
            if !adopted.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    private func readCapturedTree(
        _ treeOIDString: String,
        into index: OpaquePointer,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) {
        guard var treeOID = WorktreeForkObjectID.parse(treeOIDString) else {
            throw .gitFailure(.requiredObjectNotFound(oid: treeOIDString))
        }
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repository, &treeOID))
        guard let tree else {
            throw .gitFailure(.requiredObjectNotFound(oid: treeOIDString))
        }
        defer { git_tree_free(tree) }
        try check(git_index_read_tree(index, tree))
    }

    private func applySkipWorktree(_ paths: Set<String>, to index: OpaquePointer) throws(GitWorktreeForkError) {
        guard !paths.isEmpty else {
            return
        }
        for path in paths.sorted() {
            guard let entryPointer = path.withCString({ git_index_get_bypath(index, $0, 0) }) else {
                continue
            }
            var entry = entryPointer.pointee
            entry.flags_extended |= UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
            // Setting any extended flag requires the entry's extended bit for the on-disk format.
            entry.flags |= UInt16(GIT_INDEX_ENTRY_EXTENDED.rawValue)
            try check(git_index_add(index, &entry))
        }
    }

    /// Diffs the index against the working tree with `GIT_DIFF_UPDATE_INDEX`, which re-hashes each entry
    /// whose stat data is unknown and, only when the hash equals the captured blob, stores the working
    /// file's stat data and writes the index. Content is never staged (unlike `git_index_update_all`).
    /// `onlyPaths` restricts the refresh to exact paths so adopted entries are never re-hashed.
    private func refreshStatData(
        repository: OpaquePointer,
        index: OpaquePointer,
        onlyPaths: [String]?,
        indexLockFact: GitLockFact,
        lockTracker: WorktreeForkLockTracker?
    ) throws(GitWorktreeForkError) -> Set<String> {
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_UPDATE_INDEX.rawValue
        options.ignore_submodules = GIT_SUBMODULE_IGNORE_ALL
        var diff: OpaquePointer?
        if let onlyPaths {
            options.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
            let cStrings = onlyPaths.map { strdup($0) }
            defer {
                for cString in cStrings {
                    free(cString)
                }
            }
            var pointers: [UnsafeMutablePointer<CChar>?] = cStrings
            try reachStatRefreshCheckpoint(indexLockFact)
            lockTracker?.beginAttempt(for: [indexLockFact])
            errno = 0
            let result = pointers.withUnsafeMutableBufferPointer { buffer in
                options.pathspec = git_strarray(strings: buffer.baseAddress, count: buffer.count)
                return git_diff_index_to_workdir(&diff, repository, index, &options)
            }
            let systemErrorCode = errno
            try checkStatRefresh(
                result, systemErrorCode: systemErrorCode, lockFact: indexLockFact, lockTracker: lockTracker)
        } else {
            try reachStatRefreshCheckpoint(indexLockFact)
            lockTracker?.beginAttempt(for: [indexLockFact])
            errno = 0
            let result = git_diff_index_to_workdir(&diff, repository, index, &options)
            let systemErrorCode = errno
            try checkStatRefresh(
                result, systemErrorCode: systemErrorCode, lockFact: indexLockFact, lockTracker: lockTracker)
        }
        guard let diff else {
            throw .gitFailure(.unsupported(message: "index refresh produced no diff"))
        }
        defer { git_diff_free(diff) }
        var unrefreshed = Set<String>()
        for deltaIndex in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, deltaIndex), let path = delta.pointee.old_file.path else {
                continue
            }
            unrefreshed.insert(String(cString: path))
        }
        return unrefreshed
    }

    private func reachStatRefreshCheckpoint(_ indexLockFact: GitLockFact) throws(GitWorktreeForkError) {
        try faults.reach(.afterInitialIndexWriteBeforeStatRefresh(lockPath: indexLockFact.path))
    }

    private func checkStatRefresh(
        _ result: Int32,
        systemErrorCode: Int32,
        lockFact: GitLockFact,
        lockTracker: WorktreeForkLockTracker?
    ) throws(GitWorktreeForkError) {
        guard result >= 0 else {
            lockTracker?.recordFailure(for: [lockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: result,
                    lockFacts: [lockFact],
                    systemErrorCode: systemErrorCode
                )
            )
        }
    }

    private func openRepository(_ path: URL) throws(GitWorktreeForkError) -> OpaquePointer {
        var repository: OpaquePointer?
        let openResult = path.path.withCString {
            git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }
        guard openResult >= 0, let repository else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        return repository
    }

    private func check(_ result: Int32) throws(GitWorktreeForkError) {
        guard result >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: result))
        }
    }
}
