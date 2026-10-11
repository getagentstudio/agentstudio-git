import Foundation

public protocol AgentStudioGitLocalClient: Sendable {
    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity
    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot]
    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeCreation
    /// Forks an existing worktree's current filesystem into a new linked worktree with APFS copy-on-write
    /// storage. Normal `createWorktree` is unaffected by whether this capability is available.
    func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError) -> GitForkWorktreeResult
    /// Read-only availability check for disabling fork up front; it never mutates or walks the source.
    func forkWorktreeEligibility(
        sourceWorktreePath: URL,
        destinationPath: URL,
        materialization: GitWorktreeForkMaterialization
    ) async -> GitWorktreeForkEligibility
    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func statusObservationPlan(for worktreePath: URL) async throws(GitDataPlaneError) -> GitStatusObservationPlan
    func statusFacts(
        for worktreePath: URL,
        options: GitStatusOptions,
        observationPlan: GitStatusObservationPlan?
    ) async throws(GitDataPlaneError)
        -> GitStatusFactsRead
    /// Requires the caller to choose whether submodules contribute to line counts.
    func exactLineCountDetail(for worktreePath: URL, excludeSubmodules: Bool) async throws(GitDataPlaneError)
        -> GitStatusLineCountDetail
    func completeStatus(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitCompleteStatusSnapshot
    func trackedPaths(for worktreePath: URL, options: GitTrackedPathsOptions) async throws(GitDataPlaneError)
        -> GitTrackedPathsSnapshot
    func isPathIgnored(repositoryAt worktreePath: URL, relativePath: String) async throws(GitDataPlaneError) -> Bool
    func ignoredPaths(repositoryAt worktreePath: URL, relativePaths: [String]) async throws(GitDataPlaneError)
        -> [GitIgnoreCheck]
    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot]
    /// Configured remote names, so a `<remote>/<branch>` start can be split at a real remote.
    func remoteNames(for repositoryPath: URL) async throws(GitDataPlaneError) -> [String]
    /// The worktree holding a local branch, by `HEAD`, rebase, or bisect, as `git worktree add` refuses it.
    /// Administration that cannot be read fails the call; it never reads as `free`.
    func branchUse(_ request: GitBranchUseRequest) async throws(GitDataPlaneError) -> GitBranchUse
    /// Commits only one of two commits has; `countCommitRange` cannot tell behind from diverged.
    func aheadBehind(_ request: GitAheadBehindRequest) async throws(GitDataPlaneError) -> GitAheadBehind
    func assessBranchIntegration(_ request: GitBranchIntegrationRequest) async throws(GitDataPlaneError)
        -> GitBranchIntegrationReport
    func deleteLocalBranch(_ request: GitDeleteLocalBranchRequest)
        async throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>)
        -> GitDeleteLocalBranchResult
    func resolveReviewDefaultTarget(for repositoryPath: URL) async throws(GitDataPlaneError)
        -> GitReviewComparisonBranchTarget?
    func captureReviewComparisonTargets(_ request: GitReviewComparisonTargetCaptureRequest)
        async throws(GitDataPlaneError)
        -> GitReviewComparisonTargetCapture
    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError) -> GitResolvedRevision
    func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot
    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot
    func countCommitRange(_ request: GitCommitRangeCountRequest) async throws(GitDataPlaneError)
        -> GitCommitRangeCount
    func summarizeDiffImpact(_ request: GitDiffImpactSummaryRequest) async throws(GitDataPlaneError)
        -> GitDiffImpactSummary
    func contributionDiff(_ request: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffResult
    func directReviewComparison(_ request: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
        -> GitDirectReviewComparisonResult
    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload
}

extension AgentStudioGitLocalClient {
    public func statusFacts(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitStatusFactsRead
    {
        try await statusFacts(for: worktreePath, options: options, observationPlan: nil)
    }

    /// Conformers written before Worktree Fork keep compiling and report the capability as unavailable.
    public func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError)
        -> GitForkWorktreeResult
    {
        throw .rejected(reason: .clientCapabilityUnavailable)
    }

    public func forkWorktreeEligibility(
        sourceWorktreePath: URL,
        destinationPath: URL,
        materialization: GitWorktreeForkMaterialization
    ) async
        -> GitWorktreeForkEligibility
    {
        .unavailable(.clientCapabilityUnavailable)
    }
}

public protocol AgentStudioGitRemoteClient: Sendable {
    func clone(_ request: GitCloneRequest) async throws(GitDataPlaneError) -> GitCloneResult
    func fetch(_ request: GitFetchRequest)
        async throws(GitLockedOperationFailure<GitDataPlaneError>) -> GitFetchResult
    func captureRemoteTrackingSnapshot(_ request: GitRemoteTrackingSnapshotRequest)
        async throws(GitDataPlaneError) -> GitRemoteTrackingSnapshot
    func stageFetch(_ request: GitStagedFetchRequest) async throws(GitDataPlaneError) -> GitStagedFetchResult
    func promoteStagedFetch(_ request: GitPromoteStagedFetchRequest)
        async throws(GitDataPlaneError) -> GitPromoteStagedFetchResult
    func cleanupStagedFetch(_ request: GitCleanupStagedFetchRequest)
        async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult
    func cleanupAbandonedStagedFetches(_ request: GitCleanupAbandonedStagedFetchesRequest)
        async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult
    func push(_ request: GitPushRequest) async throws(GitDataPlaneError) -> GitPushResult
    func remoteReferences(_ request: GitRemoteReferencesRequest) async throws(GitDataPlaneError)
        -> [GitRemoteReference]
    /// Asks one configured remote for one branch without fetching. Only an answer is `present` or `absent`;
    /// an unreachable remote or any other failure is thrown.
    func probeRemoteBranch(_ request: GitRemoteBranchProbeRequest) async throws(GitDataPlaneError)
        -> GitRemoteBranchPresence
}

public struct AgentStudioGitSDK<LocalClient: AgentStudioGitLocalClient, RemoteClient: AgentStudioGitRemoteClient>:
    Sendable
{
    public let local: LocalClient
    public let remote: RemoteClient

    public init(local: LocalClient, remote: RemoteClient) {
        self.local = local
        self.remote = remote
    }
}
