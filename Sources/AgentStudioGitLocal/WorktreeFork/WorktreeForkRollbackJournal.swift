import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// A side effect the fork transaction created (or attempted), recorded before the call that creates it.
enum WorktreeForkJournalEntry: Equatable, Sendable {
    /// `identity` is filled once `git_worktree_add` succeeded, which proves the transaction created the
    /// destination; nil means creation was attempted, and a present path may belong to someone else.
    case destinationRoot(path: URL, identity: WorktreeForkEntryIdentity?)
    /// Same ownership rule as the destination: confirmed only after `git_worktree_add` succeeded.
    case linkedWorktreeAdministration(name: String, path: URL, identity: WorktreeForkEntryIdentity?)
    case createdBranch(referenceName: String, targetOID: String)
    /// `identity` is filled once the transaction's own `mkdir` succeeded; nil means creation was attempted
    /// but not confirmed, so a present path may belong to someone else and is never deleted.
    case nestedAdministration(path: URL, reportLocation: String, identity: WorktreeForkEntryIdentity?)
}

/// Owns transaction-created artifact identity, compensation, and residue proof. It lives on the lane's
/// serial queue for one call; there is deliberately no persistence or crash recovery.
struct WorktreeForkRollbackJournal {
    private(set) var entries: [WorktreeForkJournalEntry] = []
    let commonDirectory: URL
    let destinationRoot: URL
    let runtime: LibGit2Runtime
    let lockTracker: WorktreeForkLockTracker

    init(
        commonDirectory: URL,
        destinationRoot: URL,
        runtime: LibGit2Runtime,
        lockTracker: WorktreeForkLockTracker = WorktreeForkLockTracker()
    ) {
        self.commonDirectory = commonDirectory
        self.destinationRoot = destinationRoot
        self.runtime = runtime
        self.lockTracker = lockTracker
    }

    mutating func record(_ entry: WorktreeForkJournalEntry) {
        entries.append(entry)
    }

    mutating func recordForeignLock(in error: GitWorktreeForkError) {
        switch error {
        case .gitFailure(.lockHeld(let fact)):
            lockTracker.recordForeignLock(fact)
        case .cleanupIncomplete(let primary, _):
            recordForeignLock(in: primary)
        default:
            break
        }
    }

    mutating func confirmDestinationIdentity(_ identity: WorktreeForkEntryIdentity) {
        entries = entries.map { entry in
            if case .destinationRoot(let path, nil) = entry {
                return .destinationRoot(path: path, identity: identity)
            }
            return entry
        }
    }

    mutating func confirmLinkedWorktreeAdministration(_ identity: WorktreeForkEntryIdentity) {
        entries = entries.map { entry in
            if case .linkedWorktreeAdministration(let name, let path, nil) = entry {
                return .linkedWorktreeAdministration(name: name, path: path, identity: identity)
            }
            return entry
        }
    }

    mutating func confirmNestedAdministration(at path: URL, identity: WorktreeForkEntryIdentity) {
        entries = entries.map { entry in
            if case .nestedAdministration(path, let location, nil) = entry {
                return .nestedAdministration(path: path, reportLocation: location, identity: identity)
            }
            return entry
        }
    }

    /// A branch the transaction deleted itself (the detached-mode carrier branch) needs no compensation.
    mutating func forgetBranch(referenceName: String) {
        entries.removeAll { entry in
            if case .createdBranch(let name, _) = entry {
                return name == referenceName
            }
            return false
        }
    }

    /// Compensates every entry in dependency order, then re-probes each one. Returns ordered residue;
    /// an empty result means every journaled artifact is verified absent. No cleanup error is discarded.
    func rollback(faults: WorktreeForkFaultInjector) -> [GitWorktreeForkResidue] {
        var residue = lockTracker.ownedResidue().map { fact in
            GitWorktreeForkResidue(kind: .lockFile, location: lockLocation(fact.path))
        }
        // Paths whose removal was refused in this rollback. A confirmed ancestor of any of them is kept and
        // reported too: removing it recursively would delete the refused path anyway.
        var refused = lockTracker.protectedPaths()
        func removeUnlessProtecting(_ path: URL, _ remove: () -> Bool) -> Bool {
            let protectsRefusedPath = refused.contains {
                relativeComponents(of: $0, beneath: path) != nil
            }
            guard !protectsRefusedPath, remove() else {
                refused.append(path)
                return false
            }
            return true
        }
        for entry in entries.reversed() {
            if case .nestedAdministration(let path, let location, let identity) = entry,
                !removeUnlessProtecting(path, { removeOwned(path, identity: identity) })
            {
                residue.append(GitWorktreeForkResidue(kind: .nestedAdministration, location: location))
            }
        }
        for entry in entries {
            if case .destinationRoot(let path, let identity) = entry,
                !removeUnlessProtecting(path, { removeDestination(path, identity: identity, faults: faults) })
            {
                residue.append(GitWorktreeForkResidue(kind: .destinationContent, location: "."))
            }
        }
        for entry in entries {
            if case .linkedWorktreeAdministration(let name, let path, let identity) = entry,
                !removeUnlessProtecting(path, { removeOwned(path, identity: identity) })
            {
                residue.append(
                    GitWorktreeForkResidue(kind: .linkedWorktreeAdministration, location: "worktrees/\(name)"))
            }
        }
        for entry in entries {
            if case .createdBranch(let referenceName, let targetOID) = entry,
                !deleteBranch(referenceName, targetOID: targetOID)
            {
                residue.append(GitWorktreeForkResidue(kind: .createdBranch, location: referenceName))
            }
        }
        let reportedLockLocations = Set(residue.filter { $0.kind == .lockFile }.map(\.location))
        for fact in lockTracker.ownedResidue() {
            let location = lockLocation(fact.path)
            if !reportedLockLocations.contains(location) {
                residue.append(GitWorktreeForkResidue(kind: .lockFile, location: location))
            }
        }
        return residue
    }

    private func lockLocation(_ path: URL) -> String {
        if let components = relativeComponents(of: path, beneath: commonDirectory) {
            return components
        }
        if let components = relativeComponents(of: path, beneath: destinationRoot) {
            return components
        }
        return path.lastPathComponent
    }

    private func relativeComponents(of path: URL, beneath root: URL) -> String? {
        WorktreeForkAdministrativeSymlinks.relativeComponents(
            of: path.resolvingSymlinksInPath().standardizedFileURL,
            beneath: root.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    private func removeDestination(
        _ path: URL,
        identity: WorktreeForkEntryIdentity?,
        faults: WorktreeForkFaultInjector
    ) -> Bool {
        if case .failure(let failure) = WorktreeForkDescriptors.lstatPath(path) {
            return failure.code == ENOENT
        }
        do throws(GitWorktreeForkError) {
            try faults.reach(.rollbackRemovingDestination)
        } catch {
            return false
        }
        return removeOwned(path, identity: identity)
    }

    /// Removes `path` only when the transaction confirmed creating it and it still has that identity. A
    /// present, unconfirmed path is never touched — emptiness does not establish ownership — and is reported
    /// as residue.
    private func removeOwned(_ path: URL, identity: WorktreeForkEntryIdentity?) -> Bool {
        let current: Darwin.stat
        switch WorktreeForkDescriptors.lstatPath(path) {
        case .success(let info):
            current = info
        case .failure(let failure):
            return failure.code == ENOENT
        }
        guard let identity, WorktreeForkEntryIdentity(current) == identity else {
            return false
        }
        return removeTree(path)
    }

    /// Removes a transaction-owned tree, first making every directory writable so restrictive modes, flags,
    /// and access control entries reproduced from the source cannot block compensation. Symlinks are never
    /// followed. System flags cannot be cleared unprivileged; a node they protect stays and is residue.
    private func removeTree(_ path: URL) -> Bool {
        if case .failure(let failure) = WorktreeForkDescriptors.lstatPath(path) {
            return failure.code == ENOENT
        }
        let fileManager = FileManager.default
        guard let emptyAccessControlList = acl_init(0) else {
            return false
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyAccessControlList)) }
        // Classify by lstat so no link is ever followed: clear user flags, then the extended ACL (an
        // immutable node refuses ACL changes), on every owned node (no-follow), and restore traversal
        // permissions only on real directories — inline, so the lazy enumerator can then descend into a
        // directory that was unreadable or denied listing.
        func releaseForRemoval(_ node: URL) {
            _ = node.path.withCString { lchflags($0, 0) }
            _ = node.path.withCString { acl_set_link_np($0, ACL_TYPE_EXTENDED, emptyAccessControlList) }
            if case .success(let info) = WorktreeForkDescriptors.lstatPath(node),
                WorktreeForkEntryKind(mode: info.st_mode) == .directory
            {
                _ = node.path.withCString { chmod($0, 0o700) }
            }
        }
        releaseForRemoval(path)
        if let enumerator = fileManager.enumerator(at: path, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator {
                releaseForRemoval(child)
            }
        }
        do {
            try fileManager.removeItem(at: path)
        } catch {
            return false
        }
        if case .failure(let failure) = WorktreeForkDescriptors.lstatPath(path) {
            return failure.code == ENOENT
        }
        return false
    }

    private func deleteBranch(_ referenceName: String, targetOID: String) -> Bool {
        guard (try? runtime.ensureInitialized()) != nil else {
            return false
        }
        var repository: OpaquePointer?
        let openResult = commonDirectory.path.withCString { git_repository_open_bare(&repository, $0) }
        guard openResult >= 0, let repository else {
            return false
        }
        defer { git_repository_free(repository) }

        let referenceLockFact: GitLockFact
        let configurationLockFact: GitLockFact
        let packedReferencesLockFact: GitLockFact
        do {
            referenceLockFact = try LibGit2LockPathResolver.fact(
                for: .reference(name: referenceName), repository: repository)
            configurationLockFact = try LibGit2LockPathResolver.fact(for: .config, repository: repository)
            packedReferencesLockFact = try LibGit2LockPathResolver.fact(for: .packedRefs, repository: repository)
        } catch {
            return false
        }
        let lockFacts = [configurationLockFact, referenceLockFact, packedReferencesLockFact]

        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        if lookupResult == GIT_ENOTFOUND.rawValue {
            return true
        }
        guard lookupResult >= 0, let reference else {
            return false
        }
        defer { git_reference_free(reference) }
        guard let target = git_reference_target(reference), oidString(target) == targetOID else {
            return false
        }
        lockTracker.beginAttempt(for: lockFacts)
        errno = 0
        let deleteResult = git_branch_delete(reference)
        let deleteErrorNumber = errno
        guard deleteResult >= 0 else {
            lockTracker.recordFailure(for: lockFacts)
            let deletionFailure = LibGit2ErrorCapture.failure(
                code: deleteResult,
                lockFacts: lockFacts,
                systemErrorCode: deleteErrorNumber
            )
            if case .lockHeld(let fact) = deletionFailure {
                lockTracker.recordForeignLock(fact)
            }
            return false
        }
        var probe: OpaquePointer?
        let probeResult = referenceName.withCString { git_reference_lookup(&probe, repository, $0) }
        if let probe {
            git_reference_free(probe)
        }
        return probeResult == GIT_ENOTFOUND.rawValue
    }
}

enum WorktreeForkObjectID {
    static func parse(_ hex: String) -> git_oid? {
        var oid = git_oid()
        let result = hex.withCString { git_oid_fromstr(&oid, $0) }
        return result == 0 ? oid : nil
    }
}
