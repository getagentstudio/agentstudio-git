import AgentStudioGit
import AgentStudioGitContracts
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree fork packed reference lock integration", .serialized)
struct GitWorktreeForkPackedReferenceLockIntegrationTests {
    @Test("carrier deletion reports the packed-refs lock after an external pack")
    func carrierDeletionReportsPackedReferencesLock() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-carrier-packed-lock")
        defer { fixture.remove() }
        let lockPath = fixture.source.appending(path: ".git/packed-refs.lock").standardizedFileURL
        let lockFact = GitLockFact(path: lockPath, resource: .packedRefs)
        let lockContents = Data("foreign packed-refs lock for carrier deletion\n".utf8)
        let carrierReference = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        let checkpointReached = OSAllocatedUnfairLock(initialState: false)
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard case .beforeCarrierBranchDeletion(let referenceName) = point else {
                return
            }
            do {
                try fixture.git.run("pack-refs", "--all", "--prune", currentDirectory: fixture.source)
                try lockContents.write(to: lockPath)
            } catch {
                throw .entryFailed(relativePath: "packed-refs.lock", reason: .entryCreationFailed, errorNumber: nil)
            }
            carrierReference.withLock { $0 = referenceName }
            checkpointReached.withLock { $0 = true }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(
                    destination: fixture.destination("carrier-packed-lock"), mode: .detached(start: .sourceHead))
            )
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(checkpointReached.withLock { $0 })
        guard case .cleanupIncomplete(let primary, _) = failure else {
            Issue.record("expected cleanup to retain the packed carrier branch, got \(String(describing: failure))")
            return
        }
        #expect(primary == .gitFailure(.lockHeld(lockFact)))
        let branchReference = try #require(carrierReference.withLock { $0 })
        #expect(try fixture.git.succeeds("show-ref", "--verify", branchReference))
        #expect(try Data(contentsOf: lockPath) == lockContents)
    }

    @Test("rollback tracks a packed-refs lock while deleting a packed branch")
    func rollbackTracksPackedReferencesLock() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-rollback-packed-lock")
        defer { fixture.remove() }
        let branchName = "rollback-packed-branch"
        let referenceName = "refs/heads/\(branchName)"
        try fixture.git.run("branch", branchName, currentDirectory: fixture.source)
        let targetOID = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("pack-refs", "--all", "--prune", currentDirectory: fixture.source)
        let lockPath = fixture.source.appending(path: ".git/packed-refs.lock").standardizedFileURL
        let lockFact = GitLockFact(path: lockPath, resource: .packedRefs)
        let lockContents = Data("foreign packed-refs lock for rollback\n".utf8)
        try lockContents.write(to: lockPath)
        let lockTracker = WorktreeForkLockTracker()
        var journal = WorktreeForkRollbackJournal(
            commonDirectory: fixture.source.appending(path: ".git"),
            destinationRoot: fixture.destination("rollback-unused"),
            runtime: LibGit2Runtime.shared,
            lockTracker: lockTracker
        )
        journal.record(.createdBranch(referenceName: referenceName, targetOID: targetOID))

        // Act
        let residue = journal.rollback(faults: .production)

        // Assert
        #expect(residue == [GitWorktreeForkResidue(kind: .createdBranch, location: referenceName)])
        #expect(lockTracker.activeLocks() == [lockFact])
        #expect(lockTracker.ownedResidue().isEmpty)
        #expect(try fixture.git.succeeds("show-ref", "--verify", referenceName))
        #expect(try Data(contentsOf: lockPath) == lockContents)
    }
}
