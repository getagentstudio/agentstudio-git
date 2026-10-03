import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// A plan plus the open source root descriptor it was classified through. The fork writer owns the
/// descriptor for the whole transaction and closes it on every exit path.
struct WorktreeForkPreparedSource: Sendable {
    let plan: WorktreeForkPlan
    let sourceRootDescriptor: Int32
}

/// Owns immutable source classification and every rejection that must happen before mutation: host and
/// volume eligibility, source/destination preconditions, captured `HEAD`, and branch-mode rules.
struct WorktreeForkPlanner: Sendable {
    let runtime: LibGit2Runtime
    let hostFacts: WorktreeForkHostFactsProvider
    let cancellation: WorktreeForkCancellation

    /// Every pre-mutation rejection that does not require walking the source tree.
    func preflight(_ request: GitForkWorktreeRequest) throws(GitWorktreeForkError) -> WorktreeForkPreflight {
        if request.materialization == .copyOnWrite,
            let hostRejection = WorktreeForkEligibility.hostRejection(
                operatingSystemMajorVersion: hostFacts.operatingSystemMajorVersion())
        {
            throw .rejected(reason: hostRejection)
        }
        let destination = try resolveDestination(request.destinationPath)
        let sourceRoot = try resolved(request.sourceWorktreePath, rejection: .sourceNotWorktreeRoot)
        if Self.overlaps(sourceRoot, destination.root) {
            throw .rejected(reason: .overlappingRoots)
        }
        let gitCapture = try captureGitState(sourceRoot: sourceRoot, destination: destination, mode: request.mode)
        let eligibilityFacts: WorktreeForkEligibilityFacts?
        if request.materialization == .copyOnWrite {
            let facts = WorktreeForkEligibilityFacts(
                operatingSystemMajorVersion: hostFacts.operatingSystemMajorVersion(),
                source: try hostFacts.volumeFacts(sourceRoot),
                destinationParent: try hostFacts.volumeFacts(destination.parent),
                mirroredAdministrativeStores: []
            )
            if let rejection = WorktreeForkEligibility.rejection(for: facts) {
                throw .rejected(reason: rejection)
            }
            eligibilityFacts = facts
        } else {
            eligibilityFacts = nil
        }
        return WorktreeForkPreflight(
            request: request,
            sourceRoot: sourceRoot,
            destination: destination,
            gitCapture: gitCapture,
            eligibilityFacts: eligibilityFacts
        )
    }

    /// Classifies the source filesystem and Git topology into the immutable plan.
    func plan(_ preflight: WorktreeForkPreflight) throws(GitWorktreeForkError) -> WorktreeForkPreparedSource {
        try cancellation.throwIfCancelled()
        let request = preflight.request
        let sourceRoot = preflight.sourceRoot
        let destination = preflight.destination
        let gitCapture = preflight.gitCapture
        let sourceRootDescriptor: Int32
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: sourceRoot) {
        case .success(let descriptor):
            sourceRootDescriptor = descriptor
        case .failure(let failure):
            throw .entryFailed(relativePath: ".", reason: .unreadableEntry, errorNumber: failure.code)
        }
        do throws(GitWorktreeForkError) {
            let filesystem: WorktreeForkFilesystemPlan
            let changesOnly: WorktreeForkChangesOnlyPlan?
            let nestedGitEntryPaths: [String]
            let gitDirectoryCandidatePaths: [String]
            if request.materialization == .copyOnWrite {
                filesystem = try WorktreeForkSourceWalker(cancellation: cancellation)
                    .walk(sourceRootDescriptor: sourceRootDescriptor)
                nestedGitEntryPaths = filesystem.nestedGitEntryPaths
                gitDirectoryCandidatePaths = filesystem.gitDirectoryCandidatePaths
                changesOnly = nil
            } else {
                filesystem = .empty
                nestedGitEntryPaths = []
                gitDirectoryCandidatePaths = []
                changesOnly = try WorktreeForkChangesOnlyPlanner(cancellation: cancellation).plan(
                    sourceRootDescriptor: sourceRootDescriptor,
                    sourceRoot: sourceRoot,
                    capturedHead: gitCapture.capturedHead
                )
            }
            let gitTopology = try planGitTopology(
                sourceRoot: sourceRoot,
                commonDirectory: gitCapture.commonDirectory,
                capturedHead: gitCapture.capturedHead,
                nestedGitEntryPaths: nestedGitEntryPaths,
                gitDirectoryCandidatePaths: gitDirectoryCandidatePaths
            )
            if request.materialization == .changesOnly, gitTopology.rootSparse != nil {
                throw .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(reason: .sparseOrSkipWorktree))
            }
            if let eligibilityFacts = preflight.eligibilityFacts {
                try requireMirroredStoresEligible(gitTopology, eligibilityFacts: eligibilityFacts)
            }
            let plan = WorktreeForkPlan(
                sourceRoot: sourceRoot,
                destinationRoot: destination.root,
                destinationRequestPath: request.destinationPath,
                worktreeName: destination.worktreeName,
                commonDirectory: gitCapture.commonDirectory,
                sourceGitDirectory: gitCapture.sourceGitDirectory,
                homeDirectory: WorktreeForkSourcePathRelocation.canonicalized(
                    absolutePath: hostFacts.homeDirectory().path),
                capturedHead: gitCapture.capturedHead,
                branchIdentity: gitCapture.branchIdentity,
                materialization: request.materialization,
                filesystem: try filesystem.excludingSubtrees(
                    gitTopology.copiedGitDirectories.flatMap(\.retiredRegistrationSubtrees)),
                changesOnly: changesOnly,
                gitTopology: gitTopology
            )
            return WorktreeForkPreparedSource(plan: plan, sourceRootDescriptor: sourceRootDescriptor)
        } catch {
            close(sourceRootDescriptor)
            throw error
        }
    }

    private func planGitTopology(
        sourceRoot: URL,
        commonDirectory: URL,
        capturedHead: WorktreeForkCapturedHead,
        nestedGitEntryPaths: [String],
        gitDirectoryCandidatePaths: [String]
    ) throws(GitWorktreeForkError) -> WorktreeForkGitTopology {
        let repository = try WorktreeForkGitHandles.openWorktree(sourceRoot)
        defer { git_repository_free(repository) }
        guard let gitDirectoryPointer = git_repository_path(repository),
            case .success(let gitDirectory) = WorktreeForkDescriptors.realpathURL(
                URL(fileURLWithPath: String(cString: gitDirectoryPointer)))
        else {
            throw .rejected(reason: .sourceNotWorktreeRoot)
        }
        return try WorktreeForkGitTopologyPlanner(
            sourceRoot: sourceRoot, commonDirectory: commonDirectory, cancellation: cancellation
        )
        .plan(
            rootRepository: repository,
            rootGitDirectory: gitDirectory,
            rootCapturedHead: capturedHead,
            nestedGitEntryPaths: nestedGitEntryPaths,
            gitDirectoryCandidatePaths: gitDirectoryCandidatePaths
        )
    }

    /// Nested common directories and borrowed object stores are mirrored with strict CoW, so they must
    /// share the source volume just as the working files do.
    private func requireMirroredStoresEligible(
        _ topology: WorktreeForkGitTopology,
        eligibilityFacts: WorktreeForkEligibilityFacts
    ) throws(GitWorktreeForkError) {
        var stores: [WorktreeForkVolumeFacts] = []
        for store in topology.nodes.map(\.sourceCommonDirectory) + topology.mirroredObjectStores {
            stores.append(try hostFacts.volumeFacts(store))
        }
        let facts = WorktreeForkEligibilityFacts(
            operatingSystemMajorVersion: eligibilityFacts.operatingSystemMajorVersion,
            source: eligibilityFacts.source,
            destinationParent: eligibilityFacts.destinationParent,
            mirroredAdministrativeStores: stores
        )
        if let rejection = WorktreeForkEligibility.rejection(for: facts) {
            throw .rejected(reason: rejection)
        }
    }

    /// The read-only availability query: host, volume, and File Provider facts for the source root and
    /// destination parent. No repository is opened and no tree is walked.
    func eligibility(
        sourceWorktreePath: URL,
        destinationPath: URL,
        materialization: GitWorktreeForkMaterialization
    ) -> GitWorktreeForkEligibility {
        do throws(GitWorktreeForkError) {
            if materialization == .copyOnWrite,
                let hostRejection = WorktreeForkEligibility.hostRejection(
                    operatingSystemMajorVersion: hostFacts.operatingSystemMajorVersion())
            {
                return .unavailable(hostRejection)
            }
            let sourceRoot = try resolved(sourceWorktreePath, rejection: .sourceNotWorktreeRoot)
            let destination = try resolveDestinationParent(destinationPath)
            if materialization == .changesOnly, Self.overlaps(sourceRoot, destination.root) {
                return .unavailable(.overlappingRoots)
            }
            guard materialization == .copyOnWrite else {
                return .available
            }
            let facts = WorktreeForkEligibilityFacts(
                operatingSystemMajorVersion: hostFacts.operatingSystemMajorVersion(),
                source: try hostFacts.volumeFacts(sourceRoot),
                destinationParent: try hostFacts.volumeFacts(destination.parent),
                mirroredAdministrativeStores: []
            )
            return WorktreeForkEligibility.rejection(for: facts).map(GitWorktreeForkEligibility.unavailable)
                ?? .available
        } catch {
            if case .rejected(let reason) = error {
                return .unavailable(reason)
            }
            return .unavailable(.sourceNotWorktreeRoot)
        }
    }

    private func resolveDestination(_ path: URL) throws(GitWorktreeForkError) -> WorktreeForkDestination {
        let destination = try resolveDestinationParent(path)
        if case .success = WorktreeForkDescriptors.lstatPath(destination.root) {
            throw .rejected(reason: .destinationExists)
        }
        return destination
    }

    private func resolveDestinationParent(_ path: URL) throws(GitWorktreeForkError) -> WorktreeForkDestination {
        let name = path.standardizedFileURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else {
            throw .rejected(reason: .invalidDestinationPath)
        }
        let parent = try resolved(
            path.standardizedFileURL.deletingLastPathComponent(), rejection: .destinationParentMissing)
        let root = parent.appending(path: name, directoryHint: .isDirectory)
        return WorktreeForkDestination(parent: parent, root: root, worktreeName: name)
    }

    private func resolved(
        _ path: URL,
        rejection: GitWorktreeForkRejectionReason
    ) throws(GitWorktreeForkError) -> URL {
        switch WorktreeForkDescriptors.realpathURL(path) {
        case .success(let canonical):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw .rejected(reason: rejection)
            }
            return canonical
        case .failure:
            throw .rejected(reason: rejection)
        }
    }

    private func captureGitState(
        sourceRoot: URL,
        destination: WorktreeForkDestination,
        mode: GitForkWorktreeMode
    ) throws(GitWorktreeForkError) -> WorktreeForkGitCapture {
        do {
            try runtime.ensureInitialized()
        } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch {
            throw .gitFailure(.unsupported(message: String(describing: error)))
        }
        var repository: OpaquePointer?
        let openResult = sourceRoot.path.withCString {
            git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }
        guard openResult >= 0, let repository else {
            throw .rejected(reason: .sourceNotWorktreeRoot)
        }
        defer { git_repository_free(repository) }
        guard git_repository_is_bare(repository) == 0, let workdir = git_repository_workdir(repository),
            case .success(let canonicalWorkdir) = WorktreeForkDescriptors.realpathURL(
                URL(fileURLWithPath: String(cString: workdir))),
            canonicalWorkdir.path == sourceRoot.path
        else {
            throw .rejected(reason: .sourceNotWorktreeRoot)
        }
        guard let commonDirectoryPointer = git_repository_commondir(repository),
            case .success(let commonDirectory) = WorktreeForkDescriptors.realpathURL(
                URL(fileURLWithPath: String(cString: commonDirectoryPointer))),
            let gitDirectoryPointer = git_repository_path(repository),
            case .success(let sourceGitDirectory) = WorktreeForkDescriptors.realpathURL(
                URL(fileURLWithPath: String(cString: gitDirectoryPointer)))
        else {
            throw .rejected(reason: .sourceNotWorktreeRoot)
        }
        let capturedHead = try captureHead(repository)
        let administrationPath = commonDirectory.appending(path: "worktrees").appending(path: destination.worktreeName)
        if case .success = WorktreeForkDescriptors.lstatPath(administrationPath) {
            throw .rejected(reason: .linkedWorktreeNameInUse)
        }
        let branchIdentity = try validateBranchIdentity(mode, capturedHead: capturedHead, repository: repository)
        return WorktreeForkGitCapture(
            commonDirectory: commonDirectory,
            sourceGitDirectory: sourceGitDirectory,
            capturedHead: capturedHead,
            branchIdentity: branchIdentity
        )
    }

    private func captureHead(_ repository: OpaquePointer) throws(GitWorktreeForkError) -> WorktreeForkCapturedHead {
        var headOID = git_oid()
        guard git_reference_name_to_id(&headOID, repository, "HEAD") >= 0 else {
            throw .rejected(reason: .sourceHeadUnavailable)
        }
        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repository, &headOID) >= 0, let commit else {
            throw .rejected(reason: .sourceHeadUnavailable)
        }
        defer { git_commit_free(commit) }
        guard let treeOID = git_commit_tree_id(commit) else {
            throw .rejected(reason: .sourceHeadUnavailable)
        }
        return WorktreeForkCapturedHead(commitOID: oidString(&headOID), treeOID: oidString(treeOID))
    }

    private func validateBranchIdentity(
        _ mode: GitForkWorktreeMode,
        capturedHead: WorktreeForkCapturedHead,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> WorktreeForkBranchIdentity {
        switch mode {
        case .detached:
            return .detached
        case .newBranch(let name):
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
            return .newBranch(referenceName: "refs/heads/\(name)")
        case .existingBranch(let name):
            try requireValidBranchName(name)
            var reference: OpaquePointer?
            let lookupResult = name.withCString { git_branch_lookup(&reference, repository, $0, GIT_BRANCH_LOCAL) }
            guard lookupResult >= 0, let reference else {
                throw lookupResult == GIT_ENOTFOUND.rawValue
                    ? .rejected(reason: .branchNotFound) : .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
            }
            defer { git_reference_free(reference) }
            guard let target = git_reference_target(reference), oidString(target) == capturedHead.commitOID else {
                throw .rejected(reason: .branchNotAtCapturedHead)
            }
            guard git_branch_is_checked_out(reference) == 0 else {
                throw .rejected(reason: .branchCheckedOut)
            }
            return .existingBranch(referenceName: "refs/heads/\(name)")
        }
    }

    private func requireValidBranchName(_ name: String) throws(GitWorktreeForkError) {
        var isValid: Int32 = 0
        guard name.withCString({ git_branch_name_is_valid(&isValid, $0) }) >= 0, isValid == 1 else {
            throw .rejected(reason: .invalidBranchName)
        }
    }

    /// Both roots are realpath-canonical. Foundation standardization is deliberately avoided: it strips a
    /// leading `/private` only when the path exists, so an existing source and a new destination diverge.
    static func overlaps(_ first: URL, _ second: URL) -> Bool {
        let firstPath = first.path
        let secondPath = second.path
        return firstPath == secondPath || secondPath.hasPrefix(firstPath + "/") || firstPath.hasPrefix(secondPath + "/")
    }
}

struct WorktreeForkPreflight: Sendable {
    let request: GitForkWorktreeRequest
    let sourceRoot: URL
    let destination: WorktreeForkDestination
    let gitCapture: WorktreeForkGitCapture
    let eligibilityFacts: WorktreeForkEligibilityFacts?
}

struct WorktreeForkDestination: Sendable {
    let parent: URL
    let root: URL
    let worktreeName: String
}

struct WorktreeForkGitCapture: Sendable {
    let commonDirectory: URL
    let sourceGitDirectory: URL
    let capturedHead: WorktreeForkCapturedHead
    let branchIdentity: WorktreeForkBranchIdentity
}
