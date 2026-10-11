import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2StatusReader: Sendable {
    private let runtime: LibGit2Runtime
    private let branchReader: LibGit2BranchReader
    private let indexPathResolver: GitIndexPathResolver
    private let observationIdentityReader: LibGit2StatusObservationIdentityReader
    private let largeFilePointerCleanliness = LibGit2LargeFilePointerCleanliness()

    init(
        runtime: LibGit2Runtime = .shared,
        branchReader: LibGit2BranchReader = LibGit2BranchReader(),
        indexPathResolver: GitIndexPathResolver = GitIndexPathResolver(),
        observationIdentityReader: LibGit2StatusObservationIdentityReader = LibGit2StatusObservationIdentityReader()
    ) {
        self.runtime = runtime
        self.branchReader = branchReader
        self.indexPathResolver = indexPathResolver
        self.observationIdentityReader = observationIdentityReader
    }

    func statusFacts(
        for worktreePath: URL,
        options: GitStatusOptions,
        observationPlan: GitStatusObservationPlan?
    ) throws -> GitStatusFactsRead {
        try withRepository(at: worktreePath) { repository in
            try statusFacts(repository: repository, options: options, observationPlan: observationPlan)
        }
    }

    func exactLineCountDetail(for worktreePath: URL) throws -> GitStatusLineCountDetail {
        try withRepository(at: worktreePath) { repository in
            try exactLineCountDetail(repository: repository, excludeSubmodules: false)
        }
    }

    func completeStatus(for worktreePath: URL, options: GitStatusOptions) throws -> GitCompleteStatusSnapshot {
        try withRepository(at: worktreePath) { repository in
            GitCompleteStatusSnapshot(
                facts: try statusFactsSnapshot(repository: repository, options: options),
                lineCountDetail: try exactLineCountDetail(
                    repository: repository, excludeSubmodules: options.excludeSubmodules)
            )
        }
    }

    private func statusFacts(
        repository: OpaquePointer,
        options: GitStatusOptions,
        observationPlan: GitStatusObservationPlan?
    ) throws -> GitStatusFactsRead {
        let facts = try statusFactsSnapshot(repository: repository, options: options)
        guard let observationPlan else {
            return GitStatusFactsRead(facts: facts, exactCleanBaseline: nil)
        }
        let currentPlan = try observationIdentityReader.plan(repository: repository)
        let isLiteralFullScope = options.pathspecs == nil
        let exactCleanBaseline =
            observationPlan.support == .supported
                && currentPlan.support == .supported
                && currentPlan.identity == observationPlan.identity
                && isLiteralFullScope
                && options.includeUntracked
                && facts.entries.isEmpty
            ? GitExactCleanBaseline(observationIdentity: currentPlan.identity)
            : nil
        return GitStatusFactsRead(facts: facts, exactCleanBaseline: exactCleanBaseline)
    }

    private func statusFactsSnapshot(repository: OpaquePointer, options: GitStatusOptions) throws
        -> GitStatusFactsSnapshot
    {
        _ = try indexPathResolver.indexPath(repository: repository)
        let branchSummary = try branchReader.branchSummary(repository: repository)
        let statusEntries = try entries(repository: repository, options: options)
        let summary = GitStatusFactSummary(
            changedFileCount: statusEntries.filter { !$0.ignored }.count,
            stagedFileCount: statusEntries.filter { $0.indexState != nil }.count,
            unstagedFileCount: statusEntries.filter { $0.worktreeState != nil }.count,
            untrackedFileCount: statusEntries.filter(\.untracked).count,
            ignoredFileCount: statusEntries.filter(\.ignored).count,
            aheadCount: branchSummary.aheadCount,
            behindCount: branchSummary.behindCount,
            hasUpstream: branchSummary.hasUpstream
        )

        return GitStatusFactsSnapshot(
            repositoryRoot: try mainWorktreePath(repository: repository),
            worktreePath: try currentWorktreePath(repository: repository),
            generatedAtUnixMilliseconds: generatedAtUnixMilliseconds(),
            head: branchSummary.head,
            originResolution: branchReader.originResolution(repository: repository),
            summary: summary,
            entries: statusEntries
        )
    }

    private func exactLineCountDetail(repository: OpaquePointer, excludeSubmodules: Bool) throws
        -> GitStatusLineCountDetail
    {
        _ = try indexPathResolver.indexPath(repository: repository)
        let lineCounts = try shortstat(repository: repository, excludeSubmodules: excludeSubmodules)
        return GitStatusLineCountDetail(
            repositoryRoot: try mainWorktreePath(repository: repository),
            worktreePath: try currentWorktreePath(repository: repository),
            generatedAtUnixMilliseconds: generatedAtUnixMilliseconds(),
            linesAdded: lineCounts.insertions,
            linesDeleted: lineCounts.deletions
        )
    }

    private func generatedAtUnixMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func entries(repository: OpaquePointer, options: GitStatusOptions) throws -> [GitStatusEntry] {
        var statusOptions = git_status_options()
        let optionsResult = git_status_options_init(&statusOptions, UInt32(GIT_STATUS_OPTIONS_VERSION))
        guard optionsResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: optionsResult)
        }
        statusOptions.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        statusOptions.flags =
            GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            | GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue
            | GIT_STATUS_OPT_NO_REFRESH.rawValue
            | GIT_STATUS_OPT_INCLUDE_UNREADABLE.rawValue
        if options.includeUntracked {
            statusOptions.flags |= GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            statusOptions.flags |= GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        }
        if options.includeIgnored {
            statusOptions.flags |= GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue
            statusOptions.flags |= GIT_STATUS_OPT_RECURSE_IGNORED_DIRS.rawValue
        }
        if options.excludeSubmodules {
            statusOptions.flags |= GIT_STATUS_OPT_EXCLUDE_SUBMODULES.rawValue
        }

        // Pathspec matching stays enabled (GIT_STATUS_OPT_DISABLE_PATHSPEC_MATCH is never set),
        // so a non-nil pathspec limits the walk to matching repo-relative paths.
        return try withPathspec(options.pathspecs) { pathspec in
            if let pathspec {
                statusOptions.pathspec = pathspec
            }

            var statusList: OpaquePointer?
            let statusResult = git_status_list_new(&statusList, repository, &statusOptions)
            guard statusResult >= 0, let statusList else {
                throw LibGit2ErrorCapture.failure(code: statusResult)
            }
            defer { git_status_list_free(statusList) }

            return try (0..<git_status_list_entrycount(statusList)).compactMap { index in
                guard let entryPointer = git_status_byindex(statusList, index) else {
                    return nil
                }
                return try statusEntry(entryPointer.pointee, repository: repository)
            }
            .sorted { $0.path < $1.path }
        }
    }

    /// Runs `body` with an optional `git_strarray` whose backing C strings outlive the call.
    ///
    /// A `nil` or empty `pathspecs` yields `nil`, leaving `git_status_options.pathspec` at its
    /// zero value so libgit2 applies no path restriction. When paths are present, each is
    /// `strdup`'d into a C string kept alive for the whole `body` scope, so the array remains
    /// valid across the `git_status_list_new` call that copies it.
    private func withPathspec<ReturnValue>(
        _ pathspecs: [String]?,
        _ body: (git_strarray?) throws -> ReturnValue
    ) rethrows -> ReturnValue {
        guard let pathspecs, !pathspecs.isEmpty else {
            return try body(nil)
        }
        var cStrings: [UnsafeMutablePointer<CChar>?] = pathspecs.map { strdup($0) }
        defer {
            for cString in cStrings {
                free(cString)
            }
        }
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            let pathspec = git_strarray(strings: buffer.baseAddress, count: pathspecs.count)
            return try body(pathspec)
        }
    }

    private func statusEntry(_ entry: git_status_entry, repository: OpaquePointer) throws -> GitStatusEntry? {
        let flags = entry.status
        let indexState = indexState(flags)
        let ignored = statusContains(flags, GIT_STATUS_IGNORED)
        let untracked = statusContains(flags, GIT_STATUS_WT_NEW)
        let path = try entryPath(entry)
        let worktreeState = try worktreeState(
            flags,
            indexToWorkdir: entry.index_to_workdir,
            repository: repository,
            path: path.currentPath
        )
        guard indexState != nil || worktreeState != nil || ignored || untracked else {
            return nil
        }
        return GitStatusEntry(
            path: path.currentPath,
            previousPath: path.previousPath,
            indexState: indexState,
            worktreeState: worktreeState,
            ignored: ignored,
            untracked: untracked
        )
    }

    private func indexState(_ flags: git_status_t) -> GitStatusState? {
        if statusContains(flags, GIT_STATUS_CONFLICTED) { return .unmerged }
        if statusContains(flags, GIT_STATUS_INDEX_RENAMED) { return .renamed }
        if statusContains(flags, GIT_STATUS_INDEX_NEW) { return .added }
        if statusContains(flags, GIT_STATUS_INDEX_MODIFIED) { return .modified }
        if statusContains(flags, GIT_STATUS_INDEX_DELETED) { return .deleted }
        if statusContains(flags, GIT_STATUS_INDEX_TYPECHANGE) { return .typeChanged }
        return nil
    }

    private func worktreeState(
        _ flags: git_status_t,
        indexToWorkdir: UnsafePointer<git_diff_delta>?,
        repository: OpaquePointer,
        path: String
    ) throws -> GitStatusState? {
        let state: GitStatusState?
        if statusContains(flags, GIT_STATUS_CONFLICTED) {
            state = .unmerged
        } else if statusContains(flags, GIT_STATUS_WT_RENAMED) {
            state = .renamed
        } else if statusContains(flags, GIT_STATUS_WT_MODIFIED) {
            state = .modified
        } else if statusContains(flags, GIT_STATUS_WT_DELETED) {
            state = .deleted
        } else if statusContains(flags, GIT_STATUS_WT_TYPECHANGE) || statusContains(flags, GIT_STATUS_WT_UNREADABLE) {
            state = .typeChanged
        } else {
            state = nil
        }

        guard state == .modified, let indexToWorkdir,
            try largeFilePointerCleanliness.isCleanSmudgedFile(
                delta: indexToWorkdir.pointee,
                repository: repository,
                worktreePath: path
            )
        else {
            return state
        }
        return nil
    }

    private func entryPath(_ entry: git_status_entry) throws -> (currentPath: String, previousPath: String?) {
        if let delta = entry.head_to_index {
            let newPath = gitDiffPath(delta.pointee.new_file.path)
            let oldPath = gitDiffPath(delta.pointee.old_file.path)
            if statusContains(entry.status, GIT_STATUS_INDEX_RENAMED) {
                return try (requiredPath(newPath ?? oldPath), oldPath)
            }
            if let newPath {
                return (newPath, nil)
            }
            if let oldPath {
                return (oldPath, nil)
            }
        }

        if let delta = entry.index_to_workdir {
            let newPath = gitDiffPath(delta.pointee.new_file.path)
            let oldPath = gitDiffPath(delta.pointee.old_file.path)
            if statusContains(entry.status, GIT_STATUS_WT_RENAMED) {
                return try (requiredPath(newPath ?? oldPath), oldPath)
            }
            if let newPath {
                return (newPath, nil)
            }
            if let oldPath {
                return (oldPath, nil)
            }
        }

        throw LibGit2ErrorCapture.fallbackFailure(
            code: -1,
            message: "libgit2 returned a status entry without a path"
        )
    }

    private func shortstat(repository: OpaquePointer, excludeSubmodules: Bool) throws -> (
        insertions: Int, deletions: Int
    ) {
        var diffOptions = git_diff_options()
        let optionsResult = git_diff_options_init(&diffOptions, UInt32(GIT_DIFF_OPTIONS_VERSION))
        guard optionsResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: optionsResult)
        }
        if excludeSubmodules {
            diffOptions.ignore_submodules = GIT_SUBMODULE_IGNORE_ALL
            // The tree-to-index half must also omit staged gitlink changes.
            diffOptions.flags |= GIT_DIFF_IGNORE_SUBMODULES.rawValue
        }

        var headTreeObject: OpaquePointer?
        let treeResult = "HEAD^{tree}".withCString { specPointer in
            git_revparse_single(&headTreeObject, repository, specPointer)
        }
        if treeResult != GIT_EUNBORNBRANCH.rawValue, treeResult != GIT_ENOTFOUND.rawValue {
            guard treeResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: treeResult)
            }
        }
        defer {
            if let headTreeObject {
                git_object_free(headTreeObject)
            }
        }

        var diff: OpaquePointer?
        let diffResult = git_diff_tree_to_workdir_with_index(&diff, repository, headTreeObject, &diffOptions)
        guard diffResult >= 0, let diff else {
            throw LibGit2ErrorCapture.failure(code: diffResult)
        }
        defer { git_diff_free(diff) }

        var stats: OpaquePointer?
        let statsResult = git_diff_get_stats(&stats, diff)
        guard statsResult >= 0, let stats else {
            throw LibGit2ErrorCapture.failure(code: statsResult)
        }
        defer { git_diff_stats_free(stats) }

        return (
            insertions: Int(git_diff_stats_insertions(stats)),
            deletions: Int(git_diff_stats_deletions(stats))
        )
    }

    private func currentWorktreePath(repository: OpaquePointer) throws -> URL {
        let workDirectory = try requiredGitURL(git_repository_workdir(repository), label: "work directory")
        return canonicalWorktreeURL(for: workDirectory)
    }

    private func requiredPath(_ path: String?) throws -> String {
        guard let path else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 returned a status rename without a path"
            )
        }
        return path
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()

        var repository: OpaquePointer?
        let openResult = path.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }

        return try body(repository)
    }
}

private func gitDiffPath(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

private func statusContains(_ flags: git_status_t, _ mask: git_status_t) -> Bool {
    flags.rawValue & mask.rawValue != 0
}
