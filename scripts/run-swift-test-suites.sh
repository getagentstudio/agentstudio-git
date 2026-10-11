#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_test_arguments=()
if [ "$#" -gt 0 ]; then
  swift_test_arguments=("$@")
fi

suites=(
  GitWireEnumSnapshotTests
  GitBranchIntegrationContractTests
  GitBranchDeletionContractTests
  GitLockContractTests
  GitWorktreeRemovalContractTests
  GitPublicContractTests
  GitStatusOptionsContractTests
  GitInvalidDecodeTests
  GitRedactionTests
  GitWorktreeForkContractTests
  GitWorktreeCopyRulesContractTests
  GitCreationReadContractTests
  GitPathPatternTests
  GitPathPatternReviewTests
  GitPathPatternNativeParityTests
  SparseCheckoutMatcherNativeParityTests
  SparseCheckoutReapplyNativeParityTests
  GitWildmatchDifferentialTests
  GitLargeFileFillContractTests
  LibGit2BlockingReadExecutorTests
  LibGit2RuntimeTests
  LibGit2RepositorySessionTests
  LibGit2ErrorCaptureTests
  GitLockDiagnosticTests
  GitLockResidueObserverTests
  GitRepositoryIdentityTests
  GitRepositoryWriterRegistryTests
  GitRepositoryWriterLaneTests
  WorktreeForkPolicyTests
  WorktreeForkCopyFilterOperationTests
  SparseCheckoutMatcherTests
  WorktreeForkCleanEntryAdoptionTests
  WorktreeForkPrivateCounterpartTests
  GitProcessRunnerTests
  SystemGitRemoteClientTests
  GitRemoteOutputParserTests
  LibGit2PackagingScriptTests
  SourceStructureTests
  GitStatusIntegrationTests
  GitStatusSubmoduleIntegrationTests
  GitObservationSweepIntegrationTests
  GitExactCleanBaselineIntegrationTests
  GitImplicitStatusDependencyTests
  GitStagedFetchIntegrationTests
  GitIgnoreIntegrationTests
  GitTrackedPathIntegrationTests
  GitWorktreeIntegrationTests
  GitWorktreeCreateBranchIntegrationTests
  GitWorktreeCreateUndoIntegrationTests
  GitWorktreeLargeFileFillIntegrationTests
  GitWorktreeRemovalIntegrationTests
  GitFetchIntegrationTests
  GitRemoteBranchProbeIntegrationTests
  GitCreationReadIntegrationTests
  GitLockIntegrationTests
  GitLockAcquisitionRetirementIntegrationTests
  GitLockRemoteIntegrationTests
  GitWorktreeForkIntegrationTests
  GitWorktreeForkCopyRulesIntegrationTests
  GitWorktreeForkCopyRulesReviewIntegrationTests
  GitWorktreeForkLockIntegrationTests
  GitWorktreeForkIndexLockIntegrationTests
  GitWorktreeForkPackedReferenceLockIntegrationTests
  GitWorktreeForkStorageIntegrationTests
  GitWorktreeForkRollbackIntegrationTests
  GitWorktreeForkAttachIntegrationTests
  GitWorktreeForkResetIntegrationTests
  GitWorktreeForkTopologyIntegrationTests
  GitWorktreeForkSparseMatcherFallbackTests
  GitWorktreeForkEligibilityIntegrationTests
  GitWorktreeForkChangesOnlyIntegrationTests
  GitWorktreeForkCancellationIntegrationTests
  GitWorktreeForkTrackedStateIntegrationTests
  GitWorktreeForkChangesOnlyFilterIntegrationTests
  GitWorktreeForkCleanAdoptionIntegrationTests
  GitWorktreeForkMetadataFlagsIntegrationTests
  GitWorktreeForkRehomedMetadataIntegrationTests
  GitWorktreeForkNestedConfigurationIntegrationTests
  GitWorktreeForkNestedIncludeIntegrationTests
  GitWorktreeForkIncludeOrderIntegrationTests
  GitWorktreeForkExternalIncludeIntegrationTests
  GitWorktreeForkNestedRepositoryIntegrationTests
  GitWorktreeForkEmbeddedRepositoryIntegrationTests
  GitWorktreeForkPrivateAdminIntegrationTests
  GitCommitRangeCountIntegrationTests
  GitBranchIntegrationIntegrationTests
  GitBranchIntegrationHistoryIntegrationTests
  GitBranchIntegrationBatchIntegrationTests
  GitBranchIntegrationDeltaTests
  GitBranchIntegrationSquashEdgeIntegrationTests
  GitBranchIntegrationRealSquashIntegrationTests
  GitBranchIntegrationEntryDeltaIntegrationTests
  GitBranchIntegrationPathDeltaIntegrationTests
  GitBranchIntegrationReadOnlyIntegrationTests
  GitBranchDeletionIntegrationTests
  GitBranchDeletionRaceIntegrationTests
  GitDiffImpactSummaryIntegrationTests
  GitReviewDataIntegrationTests
  GitLargeFilePointerReviewIntegrationTests
  AgentStudioCompatibilityGateTests
)

for suite in "${suites[@]}"; do
  echo "--- swift test filter: ${suite} ---"
  if [ "${#swift_test_arguments[@]}" -gt 0 ]; then
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" "${swift_test_arguments[@]}" "$suite"
  else
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" "$suite"
  fi
done
