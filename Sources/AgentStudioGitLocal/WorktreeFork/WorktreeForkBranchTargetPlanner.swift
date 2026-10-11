import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// A fork's validated branch target and the commit it ends at.
struct WorktreeForkBranchTarget: Equatable, Sendable {
    let identity: WorktreeForkBranchIdentity
    let start: WorktreeForkCapturedHead
}

/// Applies every branch rule that can be decided before mutation: the name, existence, the expected tip,
/// fast-forward ancestry, upstream names, and branch use. The attach repeats the tip and branch-use checks under
/// the branch's ref lock; these early checks only keep a doomed fork from copying anything.
struct WorktreeForkBranchTargetPlanner {
    let sourceRoot: URL
    let capturedHead: WorktreeForkCapturedHead

    func plan(
        _ mode: GitForkWorktreeMode,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> WorktreeForkBranchTarget {
        switch mode {
        case .detached(let start):
            return WorktreeForkBranchTarget(identity: .detached, start: try resolve(start, repository: repository))
        case .newBranch(let name, let start, let upstream):
            try requireValidBranchName(name)
            var existing: OpaquePointer?
            let lookupResult = name.withCString { git_branch_lookup(&existing, repository, $0, GIT_BRANCH_LOCAL) }
            if let existing {
                git_reference_free(existing)
            }
            guard lookupResult == GIT_ENOTFOUND.rawValue else {
                throw lookupResult >= 0
                    ? .rejected(reason: .branchAlreadyExists)
                    : .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
            }
            if let upstream {
                try requireValidUpstream(upstream)
            }
            let resolvedStart = try resolve(start, repository: repository)
            try requireBranchFree(name)
            return WorktreeForkBranchTarget(
                identity: .newBranch(referenceName: "refs/heads/\(name)", upstream: upstream),
                start: resolvedStart
            )
        case .existingBranch(let name, let expectedTip, let fastForwardTo):
            try requireValidBranchName(name)
            var reference: OpaquePointer?
            let lookupResult = name.withCString { git_branch_lookup(&reference, repository, $0, GIT_BRANCH_LOCAL) }
            guard lookupResult >= 0, let reference else {
                throw lookupResult == GIT_ENOTFOUND.rawValue
                    ? .rejected(reason: .branchNotFound) : .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
            }
            defer { git_reference_free(reference) }
            var expectedTipOID = try pinnedCommit(expectedTip, label: "expectedTip", repository: repository)
            guard git_reference_type(reference) == GIT_REFERENCE_DIRECT, let tip = git_reference_target(reference),
                git_oid_cmp(tip, &expectedTipOID) == 0
            else {
                throw .rejected(reason: .branchMoved)
            }
            if let fastForwardTo {
                var fastForwardOID = try pinnedCommit(fastForwardTo, label: "fastForwardTo", repository: repository)
                let descendantResult = git_graph_descendant_of(repository, &fastForwardOID, &expectedTipOID)
                guard descendantResult >= 0 else {
                    throw .gitFailure(LibGit2ErrorCapture.failure(code: descendantResult))
                }
                guard descendantResult == 1 else {
                    throw .rejected(reason: .fastForwardNotDescendant)
                }
            }
            try requireBranchFree(name)
            return WorktreeForkBranchTarget(
                identity: .existingBranch(
                    referenceName: "refs/heads/\(name)", expectedTip: expectedTip, fastForwardTo: fastForwardTo),
                start: try resolve(.commit(fastForwardTo ?? expectedTip), repository: repository)
            )
        }
    }

    private func resolve(
        _ start: GitForkStart,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> WorktreeForkCapturedHead {
        guard case .commit(let commitText) = start else {
            return capturedHead
        }
        var oid = try pinnedCommit(commitText, label: "start", repository: repository)
        var commit: OpaquePointer?
        let lookupResult = git_commit_lookup(&commit, repository, &oid)
        guard lookupResult >= 0, let commit else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_commit_free(commit) }
        guard let treeOID = git_commit_tree_id(commit) else {
            throw .gitFailure(.requiredObjectNotFound(oid: commitText))
        }
        return WorktreeForkCapturedHead(commitOID: oidString(&oid), treeOID: oidString(treeOID))
    }

    private func pinnedCommit(
        _ text: String,
        label: String,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> git_oid {
        do throws(GitDataPlaneError) {
            return try LibGit2PinnedCommit.requireCommit(text, label: label, repository: repository)
        } catch {
            throw .gitFailure(error)
        }
    }

    private func requireBranchFree(_ name: String) throws(GitWorktreeForkError) {
        let use: GitBranchUse
        do {
            use = try LibGit2BranchUseReader().branchUse(
                GitBranchUseRequest(repositoryPath: sourceRoot, branchName: name))
        } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch {
            throw .gitFailure(.unsupported(message: String(describing: error)))
        }
        if case .inUse(let worktreePath) = use {
            throw .branchCheckedOut(worktreePath: worktreePath)
        }
    }

    private func requireValidBranchName(_ name: String) throws(GitWorktreeForkError) {
        var isValid: Int32 = 0
        guard !name.utf8.contains(0), name.withCString({ git_branch_name_is_valid(&isValid, $0) }) >= 0, isValid == 1
        else {
            throw .rejected(reason: .invalidBranchName)
        }
    }

    private func requireValidUpstream(_ upstream: GitBranchUpstream) throws(GitWorktreeForkError) {
        guard LibGit2BranchUpstreamWriter.isValid(upstream) else {
            throw .rejected(reason: .invalidUpstream)
        }
    }
}
