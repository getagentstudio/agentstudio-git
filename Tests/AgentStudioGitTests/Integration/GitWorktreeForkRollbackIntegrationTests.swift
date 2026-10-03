import AgentStudioGit
import Darwin
import Dispatch
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree fork rollback integration", .serialized)
struct GitWorktreeForkRollbackIntegrationTests {
    private static let injected = GitWorktreeForkError.entryFailed(
        relativePath: "injected", reason: .entryCreationFailed, errorNumber: nil)

    @Test(
        "rollback reports every confirmed artifact retained around an acquired lock",
        arguments: [
            LockedRollbackArtifact.destinationRoot,
            .linkedWorktreeAdministration,
            .nestedAdministration,
        ]
    )
    func retainedArtifactUnderAcquiredLockIsReported(_ artifact: LockedRollbackArtifact) throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-locked-residue")
        defer { fixture.remove() }
        let destinationRoot = fixture.destination("locked-residue-destination")
        let commonDirectory = fixture.source.appending(path: ".git")
        let artifactPath: URL
        let lockPath: URL
        let lockFact: GitLockFact
        let lockLocation: String
        let residueKind: GitWorktreeForkResidueKind
        let residueLocation: String
        switch artifact {
        case .destinationRoot:
            artifactPath = destinationRoot
            lockPath = artifactPath.appending(path: ".git/index.lock")
            lockFact = GitLockFact(path: lockPath.standardizedFileURL, resource: .index(worktreePath: destinationRoot))
            lockLocation = ".git/index.lock"
            residueKind = .destinationContent
            residueLocation = "."
        case .linkedWorktreeAdministration:
            let name = "locked-residue-admin"
            artifactPath = commonDirectory.appending(path: "worktrees/\(name)")
            lockPath = artifactPath.appending(path: "index.lock")
            lockFact = GitLockFact(path: lockPath.standardizedFileURL, resource: .index(worktreePath: destinationRoot))
            lockLocation = "worktrees/\(name)/index.lock"
            residueKind = .linkedWorktreeAdministration
            residueLocation = "worktrees/\(name)"
        case .nestedAdministration:
            artifactPath = destinationRoot.appending(path: ".git/modules/nested")
            lockPath = artifactPath.appending(path: "index.lock")
            lockFact = GitLockFact(path: lockPath.standardizedFileURL, resource: .index(worktreePath: destinationRoot))
            lockLocation = ".git/modules/nested/index.lock"
            residueKind = .nestedAdministration
            residueLocation = "nested/.git/modules/nested"
        }
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockTracker = WorktreeForkLockTracker()
        lockTracker.beginAttempt(for: [lockFact])
        let lockContents = Data("positively acquired lock beneath retained artifact\n".utf8)
        try lockContents.write(to: lockPath)
        lockTracker.recordAcquisition(of: lockFact)
        let identity = WorktreeForkEntryIdentity(try #require(GitWorktreeForkFileProbe.info(artifactPath)))
        var journal = WorktreeForkRollbackJournal(
            commonDirectory: commonDirectory,
            destinationRoot: destinationRoot,
            runtime: LibGit2Runtime.shared,
            lockTracker: lockTracker
        )
        switch artifact {
        case .destinationRoot:
            journal.record(.destinationRoot(path: artifactPath, identity: identity))
        case .linkedWorktreeAdministration:
            journal.record(
                .linkedWorktreeAdministration(name: "locked-residue-admin", path: artifactPath, identity: identity))
        case .nestedAdministration:
            journal.record(
                .nestedAdministration(path: artifactPath, reportLocation: residueLocation, identity: identity))
        }

        // Act
        let residue = journal.rollback(faults: .production)

        // Assert
        #expect(
            residue == [
                GitWorktreeForkResidue(kind: .lockFile, location: lockLocation),
                GitWorktreeForkResidue(kind: residueKind, location: residueLocation),
            ]
        )
        #expect(GitWorktreeForkFileProbe.exists(artifactPath))
        #expect(GitWorktreeForkFileProbe.exists(lockPath))
        #expect(try Data(contentsOf: lockPath) == lockContents)
    }

    @Test(
        "a failure after each transaction phase removes the destination, administration, and created branch",
        arguments: [
            WorktreeForkFaultPoint.afterPreflight,
            .afterPlanning,
            .afterIdentityCreated,
            .afterWorktreeAdded,
            .afterDirectoriesCreated,
            .leafBatchStarted,
            .afterMaterialization,
            .afterGitStateRehomed,
            .afterDirectoryMetadataApplied,
            .afterIndexesBuilt,
            .afterValidation,
        ],
        [GitForkWorktreeMode.newBranch(name: "fork"), .detached]
    )
    func failureAfterEachPhaseRollsBack(point: WorktreeForkFaultPoint, mode: GitForkWorktreeMode) async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-rollback")
        defer { fixture.removeRestoringPermissions() }
        let branchesBefore = try fixture.branchNames()
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            if reached == point {
                throw Self.injected
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request(mode: mode))

        // Assert
        #expect(failure == Self.injected)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
    }

    @Test(
        "a late failure removes cloned build output that carries deny-delete access control entries",
        arguments: [
            WorktreeForkFaultPoint.afterMaterialization,
            .afterDirectoryMetadataApplied,
            .afterIndexesBuilt,
            .afterValidation,
        ]
    )
    func lateFailureRemovesAccessControlProtectedEntries(point: WorktreeForkFaultPoint) async throws {
        // Arrange: CoW clones carry file ACLs immediately and directory ACLs once directory metadata lands.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-acl-rollback")
        let protectedFile = fixture.source.appending(path: ".build/protected/payload.bin")
        let protectedDirectory = fixture.source.appending(path: ".build/protected")
        defer {
            for root in [fixture.source, fixture.destination()] {
                for relativePath in [".build/protected/payload.bin", ".build/protected"] {
                    Self.removeExtendedAccessControlList(root.appending(path: relativePath))
                }
            }
            fixture.remove()
        }
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        try fixture.write(".build/protected/payload.bin", "protected build output\n")
        try Self.setAccessControlText(Self.denyDeleteFileEntry, on: protectedFile)
        try Self.setAccessControlText(Self.denyDeleteDirectoryEntry, on: protectedDirectory)
        let branchesBefore = try fixture.branchNames()
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            if reached == point {
                throw Self.injected
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request())

        // Assert
        #expect(failure == Self.injected)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
        #expect(Self.accessControlText(protectedFile) == Self.denyDeleteFileEntry)
        #expect(Self.accessControlText(protectedDirectory) == Self.denyDeleteDirectoryEntry)
    }

    @Test("a cleanup failure returns cleanup-incomplete with ordered residue and never success")
    func cleanupFailureReturnsOrderedResidue() async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-residue")
        defer { fixture.removeRestoringPermissions() }
        let branchesBefore = try fixture.branchNames()
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            switch reached {
            case .afterMaterialization, .rollbackRemovingDestination:
                throw Self.injected
            default:
                return
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request())

        // Assert
        #expect(
            failure
                == .cleanupIncomplete(
                    primary: Self.injected,
                    residue: [GitWorktreeForkResidue(kind: .destinationContent, location: ".")]
                ))
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
        _ = chmod(fixture.destination().appending(path: "sealed").path, 0o755)
    }

    @Test(
        "a destination another process creates after planning is never deleted by rollback, empty or not",
        arguments: [true, false]
    )
    func foreignDestinationCreatedAfterPlanningSurvivesRollback(foreignDirectoryHasFile: Bool) async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-foreign-destination")
        defer { fixture.removeRestoringPermissions() }
        let destination = fixture.destination()
        let foreignFile = destination.appending(path: "owner.txt")
        let branchesBefore = try fixture.branchNames()
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            if reached == .afterPlanning {
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                if foreignDirectoryHasFile {
                    try? Data("another process\n".utf8).write(to: foreignFile)
                }
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request())

        // Assert
        guard case .cleanupIncomplete(let primary, let residue) = failure, case .gitFailure = primary else {
            Issue.record("expected a Git failure with residue, got \(String(describing: failure))")
            return
        }
        // The destination is foreign, and libgit2's empty administration skeleton from the failed add is
        // unconfirmed too: both are truthful residue, and neither is deleted.
        #expect(
            residue == [
                GitWorktreeForkResidue(kind: .destinationContent, location: "."),
                GitWorktreeForkResidue(kind: .linkedWorktreeAdministration, location: "worktrees/fork"),
            ])
        #expect(GitWorktreeForkFileProbe.exists(destination))
        if foreignDirectoryHasFile {
            #expect(try String(contentsOf: foreignFile, encoding: .utf8) == "another process\n")
        } else {
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("cancellation while leaves are in flight rolls back before the lane admits the next mutation")
    func cancellationWithLeavesInFlightRollsBackBeforeReleasingLane() async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-cancel")
        defer { fixture.removeRestoringPermissions() }
        let registry = GitRepositoryWriterRegistry()
        let (events, ledger) = AsyncStream.makeStream(of: CancellationEvent.self)
        var eventIterator = events.makeAsyncIterator()
        let releaseLeaf = DispatchSemaphore(value: 0)
        let firstLeaf = OSAllocatedUnfairLock(initialState: true)
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            switch reached {
            case .leafBatchStarted
            where firstLeaf.withLock({ isFirst in
                defer { isFirst = false }
                return isFirst
            }):
                ledger.yield(.leafInFlight)
                releaseLeaf.wait()
            case .afterRollback:
                ledger.yield(.rollbackFinished)
            default:
                return
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            writerRegistry: registry,
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )
        let lane = await registry.writer(for: try await client.repositoryIdentity(for: fixture.source))
        let request = fixture.request()

        // Act
        let fork = Task { () -> GitWorktreeForkError? in
            do throws(GitWorktreeForkError) {
                _ = try await client.forkWorktree(request)
                return nil
            } catch {
                return error
            }
        }
        #expect(await eventIterator.next() == .leafInFlight)
        let probe = Task {
            await lane.run(
                { _ = ledger.yield(.nextMutationRan) },
                onEnqueued: { ledger.yield(.nextMutationQueued) }
            )
        }
        #expect(await eventIterator.next() == .nextMutationQueued)
        fork.cancel()
        releaseLeaf.signal()
        let failure = await fork.value
        await probe.value
        ledger.finish()
        var remainingEvents: [CancellationEvent] = []
        while let event = await eventIterator.next() {
            remainingEvents.append(event)
        }

        // Assert
        #expect(failure == .cancelled)
        #expect(remainingEvents == [.rollbackFinished, .nextMutationRan])
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("cancellation while queued behind another mutation returns cancelled without mutating")
    func cancellationWhileQueuedReturnsCancelledWithoutMutating() async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-queued")
        defer { fixture.removeRestoringPermissions() }
        let registry = GitRepositoryWriterRegistry()
        let client = LibGit2AgentStudioGitLocalClient(writerRegistry: registry)
        let lane = await registry.writer(for: try await client.repositoryIdentity(for: fixture.source))
        let (events, ledger) = AsyncStream.makeStream(of: CancellationEvent.self)
        var eventIterator = events.makeAsyncIterator()
        let releaseBlocker = DispatchSemaphore(value: 0)
        let blocker = Task {
            await lane.run {
                ledger.yield(.leafInFlight)
                releaseBlocker.wait()
            }
        }
        #expect(await eventIterator.next() == .leafInFlight)
        let request = fixture.request()

        // Act
        let fork = Task { () -> GitWorktreeForkError? in
            do throws(GitWorktreeForkError) {
                _ = try await client.forkWorktree(request)
                return nil
            } catch {
                return error
            }
        }
        fork.cancel()
        releaseBlocker.signal()
        await blocker.value
        let failure = await fork.value

        // Assert
        #expect(failure == .cancelled)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    private static let everyoneQualifier = "group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12"
    private static let denyDeleteFileEntry = "!#acl 1\n\(everyoneQualifier):deny:delete\n"
    private static let denyDeleteDirectoryEntry =
        "!#acl 1\n\(everyoneQualifier):deny:write,delete,delete_child\n"

    private static func setAccessControlText(_ text: String, on url: URL) throws {
        let accessControlList = try #require(acl_from_text(text))
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        try #require(acl_set_link_np(url.path, ACL_TYPE_EXTENDED, accessControlList) == 0)
    }

    private static func accessControlText(_ url: URL) -> String? {
        guard let accessControlList = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        guard let text = acl_to_text(accessControlList, nil) else {
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private static func removeExtendedAccessControlList(_ url: URL) {
        guard let empty = acl_init(0) else {
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        _ = acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty)
    }

    /// A source with enough leaf batches for concurrent workers and a read-only directory, so rollback must
    /// undo reproduced restrictive modes.
    private static func preparedSource(prefix: String) throws -> GitWorktreeForkFixture {
        let fixture = try GitWorktreeForkFixture.make(prefix: prefix)
        for directoryIndex in 0..<6 {
            for fileIndex in 0..<(WorktreeForkSourceWalker.leafBatchSize + 1) {
                try fixture.write("bulk/\(directoryIndex)/file-\(fileIndex).txt", "\(directoryIndex)-\(fileIndex)\n")
            }
        }
        try fixture.write("sealed/inner.txt", "inside read-only directory\n")
        _ = chmod(fixture.source.appending(path: "sealed").path, 0o555)
        return fixture
    }

    private func forkFailure(
        _ client: LibGit2AgentStudioGitLocalClient,
        _ request: GitForkWorktreeRequest
    ) async -> GitWorktreeForkError? {
        do {
            _ = try await client.forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }
}

enum LockedRollbackArtifact: Sendable {
    case destinationRoot
    case linkedWorktreeAdministration
    case nestedAdministration
}

private enum CancellationEvent: Equatable, Sendable {
    case leafInFlight
    case nextMutationQueued
    case rollbackFinished
    case nextMutationRan
}

extension GitWorktreeForkFixture {
    /// Restores write access to fixture directories made read-only before the fixture root is removed.
    func removeRestoringPermissions() {
        _ = chmod(source.appending(path: "sealed").path, 0o755)
        repository.remove()
    }
}
