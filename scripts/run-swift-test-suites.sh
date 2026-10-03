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
  GitInvalidDecodeTests
  GitRedactionTests
  GitWorktreeForkContractTests
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
  SparseCheckoutMatcherTests
  WorktreeForkCleanEntryAdoptionTests
  WorktreeForkPrivateCounterpartTests
  GitProcessRunnerTests
  SystemGitRemoteClientTests
  GitRemoteOutputParserTests
  LibGit2PackagingScriptTests
  SourceStructureTests
  GitStatusIntegrationTests
  GitExactCleanBaselineIntegrationTests
  GitImplicitStatusDependencyTests
  GitStagedFetchIntegrationTests
  GitIgnoreIntegrationTests
  GitTrackedPathIntegrationTests
  GitWorktreeIntegrationTests
  GitWorktreeLargeFileFillIntegrationTests
  GitWorktreeRemovalIntegrationTests
  GitFetchIntegrationTests
  GitLockIntegrationTests
  GitLockAcquisitionRetirementIntegrationTests
  GitLockRemoteIntegrationTests
  GitWorktreeForkIntegrationTests
  GitWorktreeForkLockIntegrationTests
  GitWorktreeForkIndexLockIntegrationTests
  GitWorktreeForkPackedReferenceLockIntegrationTests
  GitWorktreeForkStorageIntegrationTests
  GitWorktreeForkRollbackIntegrationTests
  GitWorktreeForkTopologyIntegrationTests
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
