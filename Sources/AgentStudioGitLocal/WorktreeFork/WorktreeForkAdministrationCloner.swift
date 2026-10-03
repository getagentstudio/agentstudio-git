import AgentStudioGitContracts
import Darwin
import Foundation

/// Strict-CoW copy of the portable part of a Git administration tree (objects, refs, packed refs, shallow
/// data, configuration, hooks, info). Source indexes, locks, live process endpoints, and in-progress
/// operation state are never copied: the destination index is rebuilt from captured `HEAD`, and an active
/// merge, rebase, cherry-pick, revert, bisect, or sequencer run is not inherited.
struct WorktreeForkAdministrationCloner: Sendable {
    /// Excluded wherever they appear at the administration root.
    static let excludedTopLevelNames: Set<String> = [
        "index", "gitdir", "commondir", "worktrees", "modules",
        "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "MERGE_RR", "AUTO_MERGE", "CHERRY_PICK_HEAD", "REVERT_HEAD",
        "REBASE_HEAD", "rebase-merge", "rebase-apply", "sequencer",
        "BISECT_LOG", "BISECT_START", "BISECT_TERMS", "BISECT_EXPECTED_REV", "BISECT_ANCESTORS_OK",
        "BISECT_NAMES", "BISECT_RUN", "BISECT_HEAD",
    ]
    /// Rewritten to destination-owned mirrors after the copy.
    static let alternatesRelativePath = "objects/info/alternates"

    let reportPath: String
    /// Link text for every symlink planning classified, keyed by administration-relative path. A symlink
    /// that is not listed (appeared after planning, or inside a mirrored store) fails the transaction.
    var symlinkTargets: [String: String] = [:]

    static func isExcluded(_ relativePath: String) -> Bool {
        let name = WorktreeForkDescriptors.splitParent(relativePath).name
        if name.hasSuffix(".lock") || relativePath == alternatesRelativePath {
            return true
        }
        return !relativePath.contains("/") && excludedTopLevelNames.contains(relativePath)
    }

    /// Copies `source` into the not-yet-existing `destination`, creating missing parent directories.
    /// `created` receives the identity of the root the transaction itself created with an exclusive
    /// `mkdir`, so rollback can prove ownership before deleting anything. Directories stay owner-writable
    /// so re-homing and index writes can land; the returned tree reproduces their source metadata once
    /// the last write is done.
    func cloneTree(
        from source: URL,
        to destination: URL,
        created: (WorktreeForkEntryIdentity) -> Void = { _ in }
    ) throws(GitWorktreeForkError) -> WorktreeForkClonedAdministrationTree {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            try cloneTreeWithMaterializationDenied(from: source, to: destination, created: created)
        }
    }

    /// Clones the directory open at `sourceDirectory` into a new directory `name` created beneath the open
    /// `destinationParent`, never resolving a destination path, so a destination ancestor swapped after the
    /// parent was opened cannot redirect the copy. `source` and `destination` only label the returned tree,
    /// whose later metadata pass reopens them with no symlink allowed anywhere in the path.
    func cloneTree(
        fromDirectory sourceDirectory: Int32,
        intoNewDirectory name: String,
        beneath destinationParent: Int32,
        source: URL,
        destination: URL
    ) throws(GitWorktreeForkError) -> WorktreeForkClonedAdministrationTree {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            guard name.withCString({ mkdirat(destinationParent, $0, 0o755) }) == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
            }
            let destinationRoot = try descriptor(
                WorktreeForkDescriptors.openDirectory(beneath: destinationParent, relativePath: name))
            defer { close(destinationRoot) }
            var tree = WorktreeForkClonedAdministrationTree(
                source: source, destination: destination, reportPath: reportPath)
            try cloneDirectory(sourceDirectory, destinationRoot, relativePath: "", into: &tree)
            return tree
        }
    }

    private func cloneTreeWithMaterializationDenied(
        from source: URL,
        to destination: URL,
        created: (WorktreeForkEntryIdentity) -> Void
    ) throws(GitWorktreeForkError) -> WorktreeForkClonedAdministrationTree {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: nil)
        }
        let sourceRoot = try descriptor(WorktreeForkDescriptors.openRoot(atCanonicalPath: source))
        defer { close(sourceRoot) }
        guard destination.path.withCString({ mkdir($0, 0o755) }) == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        if case .success(let info) = WorktreeForkDescriptors.lstatPath(destination) {
            created(WorktreeForkEntryIdentity(info))
        }
        let destinationRoot = try descriptor(WorktreeForkDescriptors.openRoot(atCanonicalPath: destination))
        defer { close(destinationRoot) }
        var tree = WorktreeForkClonedAdministrationTree(
            source: source, destination: destination, reportPath: reportPath)
        try cloneDirectory(sourceRoot, destinationRoot, relativePath: "", into: &tree)
        return tree
    }

    private func cloneDirectory(
        _ source: Int32,
        _ destination: Int32,
        relativePath: String,
        into tree: inout WorktreeForkClonedAdministrationTree
    ) throws(GitWorktreeForkError) {
        switch WorktreeForkDescriptors.statDescriptor(source) {
        case .success(let info):
            tree.directories.append(.init(relativePath: relativePath, identity: WorktreeForkEntryIdentity(info)))
        case .failure(let failure):
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: failure.code)
        }
        let listingDescriptor = dup(source)
        guard listingDescriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: errno)
        }
        guard let stream = fdopendir(listingDescriptor) else {
            let failureCode = errno
            close(listingDescriptor)
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: failureCode)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let rawEntry = readdir(stream) {
            if let name = WorktreeForkDescriptors.entryName(rawEntry), name != ".", name != ".." {
                names.append(name)
            }
        }
        for name in names.sorted() {
            let childPath = WorktreeForkDescriptors.joined(relativePath, name)
            guard !Self.isExcluded(childPath),
                case .success(let info) = WorktreeForkDescriptors.statEntry(in: source, name: name)
            else {
                continue
            }
            try cloneEntry(name, info: info, source, destination, childPath: childPath, into: &tree)
        }
    }

    private func cloneEntry(
        _ name: String,
        info: Darwin.stat,
        _ source: Int32,
        _ destination: Int32,
        childPath: String,
        into tree: inout WorktreeForkClonedAdministrationTree
    ) throws(GitWorktreeForkError) {
        switch WorktreeForkEntryKind(mode: info.st_mode) {
        case .directory:
            guard name.withCString({ mkdirat(destination, $0, (info.st_mode & 0o7777) | S_IRWXU) }) == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
            }
            let sourceChild = try descriptor(
                WorktreeForkDescriptors.openDirectory(beneath: source, relativePath: name))
            defer { close(sourceChild) }
            let destinationChild = try descriptor(
                WorktreeForkDescriptors.openDirectory(beneath: destination, relativePath: name))
            defer { close(destinationChild) }
            try cloneDirectory(sourceChild, destinationChild, relativePath: childPath, into: &tree)
        case .regularFile:
            let file = name.withCString { openat(source, $0, WorktreeForkLeafWorker.leafOpenFlags) }
            guard file >= 0 else {
                throw .sourceChanged(relativePath: reportPath, reason: .entryMissing)
            }
            defer { close(file) }
            guard name.withCString({ fclonefileat(file, destination, $0, WorktreeForkLeafWorker.cloneFlags) }) == 0
            else {
                throw .entryFailed(relativePath: reportPath, reason: .strictCloneFailed, errorNumber: errno)
            }
        case .symbolicLink:
            guard let target = symlinkTargets[childPath] else {
                throw .sourceChanged(relativePath: reportPath, reason: .entryIdentityChanged)
            }
            let created = target.withCString { targetPointer in
                name.withCString { symlinkat(targetPointer, destination, $0) }
            }
            guard created == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
            }
        case .fifo, .unixSocket, .characterDevice, .blockDevice, .unknown:
            // Live process endpoints (for example the fsmonitor socket) are runtime state, not repository data.
            return
        }
    }

    private func descriptor(_ result: Result<Int32, WorktreeForkErrno>) throws(GitWorktreeForkError) -> Int32 {
        switch result {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }
}

/// The directories one administration clone created, parent before child, with the source identity each was
/// cloned from. Applied last, child before parent, so restrictive modes, flags, and timestamps reproduced from
/// the source never block a later write into the administration.
struct WorktreeForkClonedAdministrationTree: Sendable {
    struct Directory: Sendable {
        let relativePath: String
        let identity: WorktreeForkEntryIdentity
    }

    let source: URL
    let destination: URL
    let reportPath: String
    var directories: [Directory] = []

    func finalizeDirectories() throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        let sourceRoot = try openRoot(source)
        defer { close(sourceRoot) }
        let destinationRoot = try openRoot(destination)
        defer { close(destinationRoot) }
        var normalized: [GitWorktreeMaterializationNormalizedEntry] = []
        for directory in directories.reversed() {
            let directoryReportPath =
                directory.relativePath.isEmpty
                ? reportPath : WorktreeForkDescriptors.joined(reportPath, directory.relativePath)
            let sourceDescriptor = try openDirectory(sourceRoot, directory.relativePath, directoryReportPath)
            defer { close(sourceDescriptor) }
            let destinationDescriptor = try openDirectory(destinationRoot, directory.relativePath, directoryReportPath)
            defer { close(destinationDescriptor) }
            let sourceInfo: Darwin.stat
            switch WorktreeForkDescriptors.statDescriptor(sourceDescriptor) {
            case .success(let info) where WorktreeForkEntryIdentity(info) == directory.identity:
                sourceInfo = info
            case .success:
                throw .sourceChanged(relativePath: directoryReportPath, reason: .entryIdentityChanged)
            case .failure(let failure):
                throw .entryFailed(
                    relativePath: directoryReportPath, reason: .unreadableEntry, errorNumber: failure.code)
            }
            normalized += try WorktreeForkEntryMetadata.copyInodeMetadata(
                sourceDescriptor: sourceDescriptor,
                destinationDescriptor: destinationDescriptor,
                sourceInfo: sourceInfo,
                relativePath: directoryReportPath
            )
        }
        return normalized
    }

    private func openRoot(_ url: URL) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: url) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }

    private func openDirectory(
        _ root: Int32,
        _ relativePath: String,
        _ directoryReportPath: String
    ) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openDirectory(beneath: root, relativePath: relativePath) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw .entryFailed(
                relativePath: directoryReportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }
}
