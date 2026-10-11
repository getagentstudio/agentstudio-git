import AgentStudioGitContracts
import CLibGit2Local
import Foundation

public struct LibGit2AgentStudioGitLocalClient: AgentStudioGitLocalClient {
    private let identityResolver: GitRepositoryIdentityResolver
    private let writerRegistry: GitRepositoryWriterRegistry
    private let worktreeReader: LibGit2WorktreeReader
    private let worktreeWriter: LibGit2WorktreeWriter
    private let worktreeForkWriter: LibGit2WorktreeForkWriter
    private let branchDeletionWriter: LibGit2LocalBranchDeletionWriter
    private let blockingReadExecutor: LibGit2BlockingReadExecutor

    public init() {
        self.init(
            identityResolver: GitRepositoryIdentityResolver(),
            writerRegistry: .shared,
            worktreeReader: LibGit2WorktreeReader(),
            worktreeWriter: LibGit2WorktreeWriter(),
            worktreeForkWriter: LibGit2WorktreeForkWriter(),
            branchDeletionWriter: LibGit2LocalBranchDeletionWriter(),
            blockingReadExecutor: .shared
        )
    }

    init(
        identityResolver: GitRepositoryIdentityResolver = GitRepositoryIdentityResolver(),
        writerRegistry: GitRepositoryWriterRegistry = .shared,
        worktreeReader: LibGit2WorktreeReader = LibGit2WorktreeReader(),
        worktreeWriter: LibGit2WorktreeWriter = LibGit2WorktreeWriter(),
        worktreeForkWriter: LibGit2WorktreeForkWriter = LibGit2WorktreeForkWriter(),
        branchDeletionWriter: LibGit2LocalBranchDeletionWriter = LibGit2LocalBranchDeletionWriter(),
        blockingReadExecutor: LibGit2BlockingReadExecutor = .shared
    ) {
        self.identityResolver = identityResolver
        self.writerRegistry = writerRegistry
        self.worktreeReader = worktreeReader
        self.worktreeWriter = worktreeWriter
        self.worktreeForkWriter = worktreeForkWriter
        self.branchDeletionWriter = branchDeletionWriter
        self.blockingReadExecutor = blockingReadExecutor
    }

    public func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity {
        try await blockingReadExecutor.execute { () throws(GitDataPlaneError) -> GitRepositoryIdentity in
            try mapIdentityResolutionError(path: worktreePath) {
                try identityResolver.identity(for: worktreePath)
            }
        }
    }

    public func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        try await executeBlockingRead {
            try worktreeReader.worktrees(for: repositoryPath)
        }
    }

    public func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    {
        try await executeBlockingRead {
            try worktreeReader.validateWorktree(request)
        }
    }

    public func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeCreation
    {
        let writer = try await writer(for: request.repositoryPath)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.createWorktree(request)
            }
        }
    }

    /// Submits the whole fork transaction to the source repository's lane. Task cancellation is forwarded
    /// into the transaction, which rolls back before the lane releases custody and the call resumes.
    public func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError)
        -> GitForkWorktreeResult
    {
        let identity: GitRepositoryIdentity
        do {
            identity = try await repositoryIdentity(for: request.sourceWorktreePath)
        } catch .repositoryNotFound {
            throw .rejected(reason: .sourceNotWorktreeRoot)
        } catch {
            throw .gitFailure(error)
        }
        let lane = await writerRegistry.writer(for: identity)
        let cancellation = WorktreeForkCancellation()
        let forkWriter = worktreeForkWriter
        let outcome = await withTaskCancellationHandler {
            await lane.run { () -> Result<GitForkWorktreeResult, GitWorktreeForkError> in
                do throws(GitWorktreeForkError) {
                    return .success(try forkWriter.forkWorktree(request, cancellation: cancellation))
                } catch {
                    return .failure(error)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try outcome.get()
    }

    /// Runs on the blocking read executor, not the writer lane, so availability never waits behind mutations.
    public func forkWorktreeEligibility(
        sourceWorktreePath: URL,
        destinationPath: URL,
        materialization: GitWorktreeForkMaterialization
    ) async
        -> GitWorktreeForkEligibility
    {
        let forkWriter = worktreeForkWriter
        return await blockingReadExecutor.execute {
            forkWriter.eligibility(
                sourceWorktreePath: sourceWorktreePath,
                destinationPath: destinationPath,
                materialization: materialization
            )
        }
    }

    public func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    {
        let writer = try await writer(for: request.repositoryPath)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.pruneStaleWorktree(request)
            }
        }
    }

    public func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    {
        let writer = try await writer(for: request)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.removeWorktree(request)
            }
        }
    }

    public func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        let writer = try await writer(for: request.worktreeID)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.lockWorktree(request)
            }
        }
    }

    public func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        let writer = try await writer(for: request.worktreeID)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.unlockWorktree(request)
            }
        }
    }

    public func statusObservationPlan(for worktreePath: URL) async throws(GitDataPlaneError)
        -> GitStatusObservationPlan
    {
        try await executeBlockingRead {
            try LibGit2StatusObservationIdentityReader().plan(for: worktreePath)
        }
    }

    public func statusFacts(
        for worktreePath: URL,
        options: GitStatusOptions,
        observationPlan: GitStatusObservationPlan?
    ) async throws(GitDataPlaneError) -> GitStatusFactsRead {
        try await executeBlockingRead {
            try LibGit2StatusReader().statusFacts(
                for: worktreePath,
                options: options,
                observationPlan: observationPlan
            )
        }
    }

    public func exactLineCountDetail(for worktreePath: URL, excludeSubmodules: Bool) async throws(GitDataPlaneError)
        -> GitStatusLineCountDetail
    {
        try await executeBlockingRead {
            try LibGit2StatusReader().exactLineCountDetail(for: worktreePath, excludeSubmodules: excludeSubmodules)
        }
    }

    public func completeStatus(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitCompleteStatusSnapshot
    {
        try await executeBlockingRead {
            try LibGit2StatusReader().completeStatus(for: worktreePath, options: options)
        }
    }

    public func trackedPaths(for worktreePath: URL, options: GitTrackedPathsOptions) async throws(GitDataPlaneError)
        -> GitTrackedPathsSnapshot
    {
        try await executeBlockingRead {
            try LibGit2TrackedPathReader().trackedPaths(for: worktreePath, options: options)
        }
    }

    public func isPathIgnored(repositoryAt worktreePath: URL, relativePath: String) async throws(GitDataPlaneError)
        -> Bool
    {
        try await executeBlockingRead {
            try LibGit2IgnoreReader().isPathIgnored(repositoryAt: worktreePath, relativePath: relativePath)
        }
    }

    public func ignoredPaths(repositoryAt worktreePath: URL, relativePaths: [String]) async throws(GitDataPlaneError)
        -> [GitIgnoreCheck]
    {
        try await executeBlockingRead {
            try LibGit2IgnoreReader().ignoredPaths(repositoryAt: worktreePath, relativePaths: relativePaths)
        }
    }

    public func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        try await executeBlockingRead {
            try LibGit2BranchReader().branches(for: repositoryPath)
        }
    }

    public func remoteNames(for repositoryPath: URL) async throws(GitDataPlaneError) -> [String] {
        try await executeBlockingRead {
            try LibGit2RemoteNameReader().remoteNames(for: repositoryPath)
        }
    }

    public func branchUse(_ request: GitBranchUseRequest) async throws(GitDataPlaneError) -> GitBranchUse {
        try await executeBlockingRead {
            try LibGit2BranchUseReader().branchUse(request)
        }
    }

    public func aheadBehind(_ request: GitAheadBehindRequest) async throws(GitDataPlaneError) -> GitAheadBehind {
        try await executeBlockingRead {
            try LibGit2AheadBehindReader().aheadBehind(request)
        }
    }

    public func assessBranchIntegration(_ request: GitBranchIntegrationRequest) async throws(GitDataPlaneError)
        -> GitBranchIntegrationReport
    {
        try await executeBlockingRead {
            try LibGit2BranchIntegrationReader().assess(request)
        }
    }

    public func deleteLocalBranch(_ request: GitDeleteLocalBranchRequest)
        async throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>)
        -> GitDeleteLocalBranchResult
    {
        let lane: GitRepositoryWriterLane
        do throws(GitDataPlaneError) {
            lane = try await writer(for: request.repositoryPath)
        } catch {
            throw GitLockedOperationFailure(reason: .gitFailure(error), lockResidue: [])
        }
        let branchDeletionWriter = self.branchDeletionWriter
        return try await lane.run {
            () throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>)
                -> GitDeleteLocalBranchResult in
            try branchDeletionWriter.deleteLocalBranch(request)
        }
    }

    public func resolveReviewDefaultTarget(for repositoryPath: URL) async throws(GitDataPlaneError)
        -> GitReviewComparisonBranchTarget?
    {
        try await executeBlockingRead {
            try LibGit2ReviewComparisonTargetReader().resolveDefaultTarget(for: repositoryPath)
        }
    }

    public func captureReviewComparisonTargets(
        _ request: GitReviewComparisonTargetCaptureRequest
    ) async throws(GitDataPlaneError) -> GitReviewComparisonTargetCapture {
        try await executeBlockingRead {
            try LibGit2ReviewComparisonTargetReader().capture(request)
        }
    }

    public func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError)
        -> GitResolvedRevision
    {
        try await executeBlockingRead {
            try LibGit2RevisionResolver().resolve(request)
        }
    }

    public func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
        try await executeBlockingRead {
            try LibGit2TreeReader().readTree(request)
        }
    }

    public func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        try await executeBlockingRead {
            try LibGit2DiffReader().diff(request)
        }
    }

    public func countCommitRange(_ request: GitCommitRangeCountRequest) async throws(GitDataPlaneError)
        -> GitCommitRangeCount
    {
        try await executeBlockingRead {
            try LibGit2CommitRangeCounter().count(request)
        }
    }

    public func summarizeDiffImpact(_ request: GitDiffImpactSummaryRequest) async throws(GitDataPlaneError)
        -> GitDiffImpactSummary
    {
        try await executeBlockingRead {
            try LibGit2DiffImpactSummarizer().summarize(request)
        }
    }

    public func contributionDiff(_ request: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffResult
    {
        try await executeBlockingRead {
            try LibGit2ContributionDiffReader().contributionDiff(request)
        }
    }

    public func directReviewComparison(_ request: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
        -> GitDirectReviewComparisonResult
    {
        try await executeBlockingRead {
            try LibGit2DirectReviewComparisonReader().compare(request)
        }
    }

    public func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        try await executeBlockingRead {
            try LibGit2ContentReader().content(request)
        }
    }

    private func writer(for repositoryPath: URL) async throws(GitDataPlaneError) -> GitRepositoryWriterLane {
        let identity = try await repositoryIdentity(for: repositoryPath)
        return await writerRegistry.writer(for: identity)
    }

    private func writer(for request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitRepositoryWriterLane
    {
        if let worktreeID = request.worktreeID {
            return try await writer(for: worktreeID)
        }
        guard let canonicalPath = request.canonicalPath else {
            throw .unsupported(message: "removeWorktree requires a worktree id or canonical path")
        }
        return try await writer(for: canonicalPath)
    }

    private func writer(for worktreeID: GitWorktreeID) async throws(GitDataPlaneError) -> GitRepositoryWriterLane {
        guard let parsedID = LibGit2WorktreeIDParser.parse(worktreeID) else {
            throw .worktreeNotFound(id: worktreeID)
        }
        let identity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "common:\(parsedID.commonDirectory.path)"),
            canonicalCommonDirectory: parsedID.commonDirectory,
            mainWorktreePath: parsedID.mainWorktreePath
        )
        return await writerRegistry.writer(for: identity)
    }

    private func mapSyncGitDataPlaneError<ReturnValue>(
        _ operation: () throws -> ReturnValue
    ) throws(GitDataPlaneError) -> ReturnValue {
        do {
            return try operation()
        } catch let error as GitDataPlaneError {
            throw error
        } catch {
            throw .unsupported(message: String(describing: error))
        }
    }

    private func executeBlockingRead<ReturnValue: Sendable>(
        _ operation: @escaping @Sendable () throws -> ReturnValue
    ) async throws(GitDataPlaneError) -> ReturnValue {
        try await blockingReadExecutor.execute { () throws(GitDataPlaneError) -> ReturnValue in
            try mapSyncGitDataPlaneError(operation)
        }
    }

    private func mapAsyncGitDataPlaneError<ReturnValue>(
        _ operation: () async throws -> ReturnValue
    ) async throws(GitDataPlaneError) -> ReturnValue {
        do {
            return try await operation()
        } catch let error as GitDataPlaneError {
            throw error
        } catch {
            throw .unsupported(message: String(describing: error))
        }
    }

    private func mapIdentityResolutionError<ReturnValue>(
        path: URL,
        _ operation: () throws -> ReturnValue
    ) throws(GitDataPlaneError) -> ReturnValue {
        do {
            return try operation()
        } catch GitRepositoryIdentityResolverError.missingGitDirectory {
            throw .repositoryNotFound(path: path)
        } catch GitRepositoryIdentityResolverError.invalidGitFile(let gitFilePath) {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: GIT_EINVALID.rawValue,
                message: "invalid .git file: \(gitFilePath.path)"
            )
        } catch {
            throw .unsupported(message: String(describing: error))
        }
    }
}
