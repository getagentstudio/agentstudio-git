import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Owns the complete Worktree Fork transaction on the repository lane's serial queue:
/// planning → detached linked worktree → materialization → Git-state re-homing → indexes → validation → branch
/// attach → attach validation, with every failure or cancellation after the first mutation compensated through
/// the rollback journal before the lane is released. Only this writer turns validator evidence into a successful
/// result.
struct LibGit2WorktreeForkWriter: Sendable {
    private let runtime: LibGit2Runtime
    private let reader: LibGit2WorktreeReader
    private let hostFacts: WorktreeForkHostFactsProvider
    private let faults: WorktreeForkFaultInjector
    private let indexObserver: WorktreeForkIndexObserver
    private let largeFileStoreFill: LibGit2LargeFileStoreFill

    init(
        runtime: LibGit2Runtime = .shared,
        reader: LibGit2WorktreeReader = LibGit2WorktreeReader(),
        hostFacts: WorktreeForkHostFactsProvider = .live,
        faults: WorktreeForkFaultInjector = .production,
        indexObserver: WorktreeForkIndexObserver = .production,
        largeFileStoreFill: LibGit2LargeFileStoreFill = LibGit2LargeFileStoreFill()
    ) {
        self.runtime = runtime
        self.reader = reader
        self.hostFacts = hostFacts
        self.faults = faults
        self.indexObserver = indexObserver
        self.largeFileStoreFill = largeFileStoreFill
    }

    /// Read-only availability from host, volume, and File Provider facts; never the writer lane.
    func eligibility(
        sourceWorktreePath: URL,
        destinationPath: URL,
        materialization: GitWorktreeForkMaterialization
    ) -> GitWorktreeForkEligibility {
        WorktreeForkPlanner(runtime: runtime, hostFacts: hostFacts, cancellation: WorktreeForkCancellation())
            .eligibility(
                sourceWorktreePath: sourceWorktreePath,
                destinationPath: destinationPath,
                materialization: materialization
            )
    }

    func forkWorktree(
        _ request: GitForkWorktreeRequest,
        cancellation: WorktreeForkCancellation
    ) throws(GitWorktreeForkError) -> GitForkWorktreeResult {
        // Cancelled while queued behind another mutation: nothing has executed, nothing to compensate.
        try cancellation.throwIfCancelled()
        let planner = WorktreeForkPlanner(runtime: runtime, hostFacts: hostFacts, cancellation: cancellation)
        let preflight = try planner.preflight(request)
        try faults.reach(.afterPreflight)
        let prepared = try planner.plan(preflight)
        defer { close(prepared.sourceRootDescriptor) }
        let plan = prepared.plan

        var journal = WorktreeForkRollbackJournal(
            commonDirectory: plan.commonDirectory,
            destinationRoot: plan.destinationRoot,
            runtime: runtime
        )
        do throws(GitWorktreeForkError) {
            try faults.reach(.afterPlanning)
            if plan.materialization == .changesOnly {
                try faults.reach(.afterChangesOnlyCapture)
            }
            try cancellation.throwIfCancelled()
            return try execute(
                plan,
                sourceRootDescriptor: prepared.sourceRootDescriptor,
                journal: &journal,
                cancellation: cancellation
            )
        } catch {
            journal.recordForeignLock(in: error)
            let residue = journal.rollback(faults: faults)
            try? faults.reach(.afterRollback)
            guard residue.isEmpty else {
                throw .cleanupIncomplete(primary: error, residue: residue)
            }
            throw error
        }
    }

    private func execute(
        _ plan: WorktreeForkPlan,
        sourceRootDescriptor: Int32,
        journal: inout WorktreeForkRollbackJournal,
        cancellation: WorktreeForkCancellation
    ) throws(GitWorktreeForkError) -> GitForkWorktreeResult {
        try createLinkedWorktree(plan, journal: &journal)
        try faults.reach(.afterWorktreeAdded)
        try cancellation.throwIfCancelled()

        let destinationRootDescriptor = try openDestinationRoot(plan, journal: journal)
        defer { close(destinationRootDescriptor) }
        if plan.materialization == .changesOnly {
            guard let changesOnly = plan.changesOnly else {
                throw .validationFailed(reason: .entryCountMismatch, relativePath: nil)
            }
            return try executeChangesOnly(
                plan,
                changesOnly: changesOnly,
                sourceRootDescriptor: sourceRootDescriptor,
                destinationRootDescriptor: destinationRootDescriptor,
                journal: &journal,
                cancellation: cancellation
            )
        }
        let materializer = APFSStrictCloneMaterializer(cancellation: cancellation, faults: faults)
        var observations = WorktreeForkMaterializationObservations()
        observations.createdDirectoryCount = try materializer.createDirectories(
            plan.filesystem, destinationRootDescriptor: destinationRootDescriptor)
        try faults.reach(.afterDirectoriesCreated)
        observations.merge(
            try materializer.materializeLeaves(
                plan.filesystem,
                sourceRootDescriptor: sourceRootDescriptor,
                destinationRootDescriptor: destinationRootDescriptor
            ))
        observations.preservedHardLinkCount = try materializer.linkHardLinkSecondaries(
            plan.filesystem,
            sourceRootDescriptor: sourceRootDescriptor,
            destinationRootDescriptor: destinationRootDescriptor
        )
        try faults.reach(.afterMaterialization)
        try cancellation.throwIfCancelled()

        let rehomeOutcome = try GitRepositoryStateRehomer(
            plan: plan, cancellation: cancellation, lockTracker: journal.lockTracker
        )
        .rehome(journal: &journal)
        try faults.reach(.afterGitStateRehomed)
        observations.normalizedEntries += try materializer.finalizeDirectories(
            plan.filesystem,
            sourceRootDescriptor: sourceRootDescriptor,
            destinationRootDescriptor: destinationRootDescriptor
        )
        try faults.reach(.afterDirectoryMetadataApplied)
        try cancellation.throwIfCancelled()

        let indexes = try buildCopyIndexes(
            plan, observations: observations, rehomeOutcome: rehomeOutcome, journal: journal,
            cancellation: cancellation)
        let indexEvidence = indexes.root
        // Nested index writes are the last administration writes; restrictive source metadata lands after them.
        observations.normalizedEntries += try rehomeOutcome.finalizeAdministrationDirectories()
        try faults.reach(.afterIndexesBuilt)
        try cancellation.throwIfCancelled()

        // The copy is proven while still detached at the captured HEAD; the attach is proven separately below.
        _ = try WorktreeForkValidator(reader: reader, cancellation: cancellation, faults: faults).validate(
            plan: plan,
            observations: observations,
            destinationRootDescriptor: destinationRootDescriptor,
            indexEvidence: indexEvidence,
            lockTracker: journal.lockTracker
        )
        try WorktreeForkTopologyValidator(plan: plan).validate(rehomeOutcome.nodes, evidenceByNode: indexes.nodes)
        try faults.reach(.afterValidation)
        try cancellation.throwIfCancelled()
        let submodulesNotAtStart =
            plan.resetsToStart
            ? try WorktreeForkResetCheckout(faults: faults).checkout(plan, lockTracker: journal.lockTracker) : []
        try cancellation.throwIfCancelled()
        let attached = try attachAndValidate(
            plan,
            indexEvidence: indexEvidence,
            destinationRootDescriptor: destinationRootDescriptor,
            journal: &journal,
            cancellation: cancellation
        )
        return GitForkWorktreeResult(
            worktree: attached.snapshot,
            materialization: .copyOnWrite(
                report(
                    plan, observations, submodulesNotAtStart: submodulesNotAtStart, largeFiles: attached.largeFiles))
        )
    }

    /// Rebuilds the root and every re-homed submodule index from its captured `HEAD`, adopting the clone's stats
    /// where the source index proves an entry clean.
    private func buildCopyIndexes(
        _ plan: WorktreeForkPlan,
        observations: WorktreeForkMaterializationObservations,
        rehomeOutcome: WorktreeForkRehomeOutcome,
        journal: WorktreeForkRollbackJournal,
        cancellation: WorktreeForkCancellation
    ) throws(GitWorktreeForkError) -> (
        root: WorktreeForkIndexRefreshEvidence, nodes: [String: WorktreeForkIndexRefreshEvidence]
    ) {
        let indexBuilder = WorktreeForkIndexBuilder(faults: faults)
        let plannedStats = Self.plannedRegularFileStats(plan.filesystem)
        // A clone whose bytes re-homing replaced no longer vouches for captured `HEAD`; it must be hashed.
        let verifiedClonePaths = observations.statMatchedClonePaths.subtracting(rehomeOutcome.rewrittenWorktreePaths)
        func adoption(_ sourceIndex: WorktreeForkSourceIndexSnapshot?, prefix: String) -> WorktreeForkAdoptionContext? {
            sourceIndex.map {
                WorktreeForkAdoptionContext(
                    sourceIndex: $0,
                    nodePrefix: prefix,
                    plannedStats: plannedStats,
                    verifiedClonePaths: verifiedClonePaths
                )
            }
        }
        let indexEvidence = try indexBuilder.buildIndex(
            worktreePath: plan.destinationRoot,
            capturedHead: plan.capturedHead,
            skipWorktreePaths: plan.rootSkipWorktreePaths,
            adoption: adoption(plan.gitTopology.rootSourceIndex, prefix: ""),
            lockWorktreePath: plan.destinationRequestPath,
            lockTracker: journal.lockTracker
        )
        indexObserver.observe("", indexEvidence)
        var nodeIndexEvidence: [String: WorktreeForkIndexRefreshEvidence] = [:]
        for rehomed in rehomeOutcome.nodes {
            try cancellation.throwIfCancelled()
            let evidence = try indexBuilder.buildIndex(
                worktreePath: rehomed.destinationWorktree,
                capturedHead: rehomed.node.capturedHead,
                skipWorktreePaths: rehomed.node.sparse?.skipWorktreePaths ?? [],
                adoption: adoption(rehomed.node.sourceIndex, prefix: rehomed.node.relativePath),
                lockTracker: journal.lockTracker
            )
            nodeIndexEvidence[rehomed.node.relativePath] = evidence
            indexObserver.observe(rehomed.node.relativePath, evidence)
        }
        return (indexEvidence, nodeIndexEvidence)
    }

    /// Steps 3 to 5 for every fork: attach the branch target under its ref lock, fill a reset's Git LFS pointers
    /// from the local store (the fill reads the start through the attached `HEAD`), then prove the result. After a
    /// reset the checkout refreshed every entry it wrote, so no entry may lack stats.
    private func attachAndValidate(
        _ plan: WorktreeForkPlan,
        indexEvidence: WorktreeForkIndexRefreshEvidence,
        destinationRootDescriptor: Int32,
        journal: inout WorktreeForkRollbackJournal,
        cancellation: WorktreeForkCancellation
    ) throws(GitWorktreeForkError) -> (snapshot: GitWorktreeSnapshot, largeFiles: GitLargeFileFill?) {
        try WorktreeForkBranchAttach(faults: faults).attach(plan, journal: &journal)
        try cancellation.throwIfCancelled()
        var largeFiles: GitLargeFileFill?
        if plan.resetsToStart {
            let repository = try WorktreeForkGitHandles.openWorktree(plan.destinationRoot)
            defer { git_repository_free(repository) }
            largeFiles = largeFileStoreFill.fill(
                repository: repository, worktreeRootDescriptor: destinationRootDescriptor)
        }
        let snapshot = try WorktreeForkValidator(reader: reader, cancellation: cancellation, faults: faults)
            .validateAttached(
                plan: plan,
                indexEvidence: plan.resetsToStart
                    ? WorktreeForkIndexRefreshEvidence(unrefreshedPaths: [], adoptedPaths: []) : indexEvidence,
                expectedSkipWorktree: plan.rootSkipWorktreePaths,
                lockTracker: journal.lockTracker
            )
        try faults.reach(.afterAttachValidation)
        try cancellation.throwIfCancelled()
        return (snapshot, largeFiles)
    }

    private func executeChangesOnly(
        _ plan: WorktreeForkPlan,
        changesOnly: WorktreeForkChangesOnlyPlan,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32,
        journal: inout WorktreeForkRollbackJournal,
        cancellation: WorktreeForkCancellation
    ) throws(GitWorktreeForkError) -> GitForkWorktreeResult {
        let repository = try WorktreeForkGitHandles.openWorktree(plan.destinationRoot)
        defer { git_repository_free(repository) }
        try WorktreeForkGitHandles.checkoutCapturedHead(
            plan.capturedHead.commitOID,
            repository: repository,
            worktreePath: plan.destinationRequestPath,
            lockTracker: journal.lockTracker
        )
        try faults.reach(.afterHeadCheckedOut)
        try cancellation.throwIfCancelled()

        let largeFiles = try WorktreeForkChangesOnlyMaterializer(
            cancellation: cancellation,
            faults: faults,
            largeFileStoreFill: largeFileStoreFill
        ).apply(
            changesOnly,
            repository: repository,
            sourceRootDescriptor: sourceRootDescriptor,
            destinationRootDescriptor: destinationRootDescriptor
        )
        try faults.reach(.afterChangesOnlyOverlay)
        try faults.reach(.afterMaterialization)
        try cancellation.throwIfCancelled()

        let rehomedNodes = try GitRepositoryStateRehomer(
            plan: plan, cancellation: cancellation, lockTracker: journal.lockTracker
        )
        .rehome(journal: &journal).nodes
        try faults.reach(.afterGitStateRehomed)
        try cancellation.throwIfCancelled()

        let indexEvidence = try WorktreeForkIndexBuilder(faults: faults).buildIndex(
            worktreePath: plan.destinationRoot,
            capturedHead: plan.capturedHead,
            skipWorktreePaths: [],
            adoption: nil,
            lockWorktreePath: plan.destinationRequestPath,
            lockTracker: journal.lockTracker
        )
        indexObserver.observe("", indexEvidence)
        try faults.reach(.afterIndexesBuilt)
        try cancellation.throwIfCancelled()

        _ = try WorktreeForkValidator(reader: reader, cancellation: cancellation, faults: faults)
            .validateChangesOnly(
                plan: plan,
                changesOnly: changesOnly,
                sourceRootDescriptor: sourceRootDescriptor,
                destinationRootDescriptor: destinationRootDescriptor,
                indexEvidence: indexEvidence,
                lockTracker: journal.lockTracker
            )
        try WorktreeForkTopologyValidator(plan: plan).validate(rehomedNodes, evidenceByNode: [:])
        try faults.reach(.afterValidation)
        try cancellation.throwIfCancelled()
        let attached = try attachAndValidate(
            plan,
            indexEvidence: indexEvidence,
            destinationRootDescriptor: destinationRootDescriptor,
            journal: &journal,
            cancellation: cancellation
        )
        return GitForkWorktreeResult(
            worktree: attached.snapshot,
            materialization: .changesOnly(
                GitChangesOnlyMaterializationReport(
                    trackedChanges: changesOnly.trackedChangeCount,
                    untrackedFiles: changesOnly.untrackedFileCount,
                    largeFiles: largeFiles
                )
            )
        )
    }

    /// Registers the linked worktree detached at the captured `HEAD` with an empty checkout, for every branch
    /// target: the branch itself is attached only after the copy is validated. `git_worktree_add` needs a branch,
    /// so a transaction-owned carrier branch registers the worktree and is deleted once `HEAD` is detached.
    private func createLinkedWorktree(
        _ plan: WorktreeForkPlan,
        journal: inout WorktreeForkRollbackJournal
    ) throws(GitWorktreeForkError) {
        let repository = try WorktreeForkGitHandles.openWorktree(plan.sourceRoot)
        defer { git_repository_free(repository) }

        // A flat name keeps the carrier's lock directly in refs/heads, which already exists, so a lock or
        // permission failure names a real directory and no carrier namespace directory is left behind.
        let carrierShortName = "agentstudio-fork-carrier-\(UUID().uuidString.lowercased())"
        let carrierReferenceName = "refs/heads/\(carrierShortName)"
        try WorktreeForkGitHandles.createBranch(
            referenceName: carrierReferenceName,
            commitOID: plan.capturedHead.commitOID,
            repository: repository,
            faults: faults,
            lockTracker: journal.lockTracker,
            onCreated: {
                journal.record(
                    .createdBranch(referenceName: carrierReferenceName, targetOID: plan.capturedHead.commitOID))
            }
        )
        try faults.reach(.afterIdentityCreated)

        // Journal before the call: libgit2 can create administration and then fail on the working tree.
        journal.record(
            .linkedWorktreeAdministration(
                name: plan.worktreeName,
                path: plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName),
                identity: nil
            ))
        journal.record(.destinationRoot(path: plan.destinationRoot, identity: nil))
        try WorktreeForkGitHandles.addWorktree(
            name: plan.worktreeName,
            destination: plan.destinationRoot,
            branchReferenceName: carrierReferenceName,
            repository: repository,
            lockTracker: journal.lockTracker
        )
        // Only a successful add proves both exclusive mkdirs were the transaction's own.
        if case .success(let info) = WorktreeForkDescriptors.lstatPath(plan.destinationRoot) {
            journal.confirmDestinationIdentity(WorktreeForkEntryIdentity(info))
        }
        let administration = plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
        if case .success(let info) = WorktreeForkDescriptors.lstatPath(administration) {
            journal.confirmLinkedWorktreeAdministration(WorktreeForkEntryIdentity(info))
        }
        try WorktreeForkGitHandles.detachHead(
            worktreePath: plan.destinationRoot,
            commitOID: plan.capturedHead.commitOID,
            lockTracker: journal.lockTracker
        )
        try faults.reach(.beforeCarrierBranchDeletion(referenceName: carrierReferenceName))
        try WorktreeForkGitHandles.deleteBranch(
            referenceName: carrierReferenceName, repository: repository, lockTracker: journal.lockTracker)
        journal.forgetBranch(referenceName: carrierReferenceName)
    }

    private func openDestinationRoot(
        _ plan: WorktreeForkPlan,
        journal: WorktreeForkRollbackJournal
    ) throws(GitWorktreeForkError) -> Int32 {
        let descriptor: Int32
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: plan.destinationRoot) {
        case .success(let opened):
            descriptor = opened
        case .failure(let failure):
            throw .entryFailed(relativePath: ".", reason: .entryCreationFailed, errorNumber: failure.code)
        }
        let expectedIdentity = journal.entries.lazy.compactMap { entry -> WorktreeForkEntryIdentity? in
            if case .destinationRoot(_, let identity) = entry {
                return identity
            }
            return nil
        }.first
        guard case .success(let info) = WorktreeForkDescriptors.statDescriptor(descriptor),
            WorktreeForkEntryIdentity(info) == expectedIdentity
        else {
            close(descriptor)
            throw .entryFailed(relativePath: ".", reason: .entryCreationFailed, errorNumber: nil)
        }
        return descriptor
    }

    private static func plannedRegularFileStats(
        _ filesystem: WorktreeForkFilesystemPlan
    ) -> [String: WorktreeForkObservedStat] {
        var stats: [String: WorktreeForkObservedStat] = [:]
        for leaf in filesystem.leafBatches.flatMap(\.leaves) where leaf.kind == .regularFile {
            stats[leaf.relativePath] = leaf.plannedStat
        }
        return stats
    }

    private func report(
        _ plan: WorktreeForkPlan,
        _ observations: WorktreeForkMaterializationObservations,
        submodulesNotAtStart: [String],
        largeFiles: GitLargeFileFill?
    ) -> GitWorktreeMaterializationReport {
        GitWorktreeMaterializationReport(
            clonedRegularFileCount: observations.clonedRegularFileCount,
            createdDirectoryCount: observations.createdDirectoryCount,
            recreatedSymbolicLinkCount: observations.recreatedSymbolicLinkCount,
            preservedHardLinkCount: observations.preservedHardLinkCount,
            preservedGitRepositoryCount: plan.gitTopology.nodes.count,
            recreatedFIFOCount: observations.recreatedFIFOCount,
            logicalRegularFileBytes: observations.logicalRegularFileBytes,
            skippedEntries: plan.filesystem.skippedEntries,
            normalizedEntries: observations.normalizedEntries.sorted {
                ($0.relativePath, $0.attribute.rawValue) < ($1.relativePath, $1.attribute.rawValue)
            },
            ignoredIncludedPatterns: plan.ignoredIncludedPatterns,
            ignoredExcludedCount: plan.ignoredExcludedCount,
            nestedWorktreesSkipped: plan.nestedWorktreesSkipped,
            sourceState: plan.resetsToStart ? .reset : .asIs,
            submodulesNotAtStart: submodulesNotAtStart,
            largeFiles: largeFiles
        )
    }
}
