import AgentStudioGit
import AgentStudioGitContracts
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree fork lock integration", .serialized)
struct GitWorktreeForkLockIntegrationTests {
    @Test("an acquired lock remains residue when acquisition identity and later observation are inaccessible")
    func acquiredLockWithUnknownIdentityRemainsResidue() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-unknown-lock-identity")
        defer { fixture.remove() }
        let referenceName = "refs/heads/fork-unknown-identity"
        let lockFact = GitLockFact(
            path: fixture.source.appending(path: ".git/\(referenceName).lock").standardizedFileURL,
            resource: .reference(name: referenceName)
        )
        let observationCount = OSAllocatedUnfairLock(initialState: 0)
        let tracker = WorktreeForkLockTracker(pathObserver: { _ in
            observationCount.withLock { count in
                count += 1
                return count == 1 ? .absent : .inaccessible
            }
        })
        tracker.beginAttempt(for: [lockFact])
        try Self.writeLockFile(lockFact.path, contents: "native transaction lock\n")

        // Act
        tracker.recordAcquisition(of: lockFact)

        // Assert
        #expect(tracker.ownedResidue() == [lockFact])
    }

    @Test("a replacement inode is not reported as an acquired lock survivor")
    func replacedAcquiredLockIsNotResidue() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-replaced-lock-inode")
        defer { fixture.remove() }
        let referenceName = "refs/heads/fork-replaced-inode"
        let lockFact = GitLockFact(
            path: fixture.source.appending(path: ".git/\(referenceName).lock").standardizedFileURL,
            resource: .reference(name: referenceName)
        )
        let originalPath = lockFact.path.appendingPathExtension("acquired")
        let tracker = WorktreeForkLockTracker()
        tracker.beginAttempt(for: [lockFact])
        try Self.writeLockFile(lockFact.path, contents: "acquired inode\n")
        tracker.recordAcquisition(of: lockFact)
        let moveResult = lockFact.path.path.withCString { source in
            originalPath.path.withCString { destination in
                rename(source, destination)
            }
        }
        #expect(moveResult == 0)
        try Self.writeLockFile(lockFact.path, contents: "replacement inode\n")

        // Act / Assert
        #expect(tracker.ownedResidue().isEmpty)
        #expect(try Data(contentsOf: originalPath) == Data("acquired inode\n".utf8))
        #expect(try Data(contentsOf: lockFact.path) == Data("replacement inode\n".utf8))
    }

    @Test("a newly present candidate after a generic failure is not owned residue")
    func newlyPresentCandidateAfterGenericFailureIsForeign() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-failed-index-lock")
        defer { fixture.remove() }
        let lockFact = GitLockFact(
            path: fixture.source.appending(path: ".git/index.lock").standardizedFileURL,
            resource: .index(worktreePath: fixture.source)
        )
        let lockContents = "created by another writer after preflight\n"
        let tracker = WorktreeForkLockTracker()
        tracker.beginAttempt(for: [lockFact])
        try Self.writeLockFile(lockFact.path, contents: lockContents)

        // Act
        tracker.recordFailure(for: [lockFact])

        // Assert
        #expect(tracker.ownedResidue().isEmpty)
        #expect(tracker.activeLocks() == [lockFact])
        #expect(try Data(contentsOf: lockFact.path) == Data(lockContents.utf8))
    }

    @Test("a later attempt does not promote a lock observed as foreign earlier")
    func laterAttemptKeepsPreviouslyForeignLockUnowned() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-repeated-foreign-lock")
        defer { fixture.remove() }
        let lockFact = GitLockFact(
            path: fixture.source.appending(path: ".git/index.lock").standardizedFileURL,
            resource: .index(worktreePath: fixture.source)
        )
        let lockContents = "foreign lock persisted across attempts\n"
        let tracker = WorktreeForkLockTracker()
        tracker.beginAttempt(for: [lockFact])
        try Self.writeLockFile(lockFact.path, contents: lockContents)
        tracker.recordFailure(for: [lockFact])

        // Act
        tracker.beginAttempt(for: [lockFact])
        tracker.recordFailure(for: [lockFact])

        // Assert
        #expect(tracker.ownedResidue().isEmpty)
        #expect(tracker.activeLocks() == [lockFact])
        #expect(try Data(contentsOf: lockFact.path) == Data(lockContents.utf8))
    }

    @Test("a mixed candidate failure does not claim a lock for an untouched resource")
    func mixedCandidateFailureDoesNotClaimUntouchedLock() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-mixed-foreign-lock")
        defer { fixture.remove() }
        let indexLockFact = GitLockFact(
            path: fixture.source.appending(path: ".git/index.lock").standardizedFileURL,
            resource: .index(worktreePath: fixture.source)
        )
        let configurationLockFact = GitLockFact(
            path: fixture.source.appending(path: ".git/config.lock").standardizedFileURL,
            resource: .config
        )
        let lockContents = "unrelated configuration lock\n"
        let tracker = WorktreeForkLockTracker()
        tracker.beginAttempt(for: [indexLockFact, configurationLockFact])
        try Self.writeLockFile(configurationLockFact.path, contents: lockContents)

        // Act: the multi-resource call failed before reaching the configuration write.
        tracker.recordFailure(for: [indexLockFact, configurationLockFact])

        // Assert
        #expect(tracker.ownedResidue().isEmpty)
        #expect(tracker.activeLocks() == [configurationLockFact])
        #expect(try Data(contentsOf: configurationLockFact.path) == Data(lockContents.utf8))
    }

    @Test("a foreign requested-branch lock is reported exactly in both materialization modes")
    func requestedBranchLockIsReportedInBothModes() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-foreign-ref-lock")
        defer { fixture.remove() }
        let commonDirectory = fixture.source.appending(path: ".git")
        let branchesBefore = try fixture.branchNames()
        let modes: [(name: String, materialization: GitWorktreeForkMaterialization)] = [
            ("copy-on-write", .copyOnWrite),
            ("changes-only", .changesOnly),
        ]

        for mode in modes {
            let branchName = "fork-\(mode.name)"
            let referenceName = "refs/heads/\(branchName)"
            let lockPath = commonDirectory.appending(path: "\(referenceName).lock").standardizedFileURL
            try Self.writeLockFile(lockPath, contents: "foreign \(mode.name) ref lock\n")
            let lockContentsBefore = try Data(contentsOf: lockPath)
            let destination = fixture.destination(branchName)

            // Act
            let failure = await Self.forkFailure(
                fixture.request(
                    destination: destination,
                    mode: .newBranch(name: branchName, start: .sourceHead, upstream: nil),
                    materialization: mode.materialization))

            // Assert
            #expect(
                failure
                    == .gitFailure(
                        .lockHeld(
                            GitLockFact(path: lockPath, resource: .reference(name: referenceName))
                        )
                    ),
                "\(mode.name): \(String(describing: failure))"
            )
            #expect(try Data(contentsOf: lockPath) == lockContentsBefore)
            #expect(!GitWorktreeForkFileProbe.exists(destination))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(branchName)))
            #expect(try fixture.branchNames() == branchesBefore)
        }
    }

    @Test("a destination index lock planted at registration survives rollback as a foreign lock")
    func registrationIndexLockIsPreservedByRollback() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-foreign-index-lock")
        defer { fixture.remove() }
        let worktreeName = "fork-index-lock"
        let destination = fixture.destination(worktreeName)
        let administration = fixture.linkedWorktreeAdministration(worktreeName)
        let lockPath = administration.appending(path: "index.lock").standardizedFileURL
        let lockContents = Data("foreign registration index lock\n".utf8)
        let branchesBefore = try fixture.branchNames()
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterWorktreeAdded else {
                return
            }
            do {
                try lockContents.write(to: lockPath)
            } catch {
                throw .entryFailed(relativePath: "index.lock", reason: .entryCreationFailed, errorNumber: nil)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))
        let lockFact = GitLockFact(path: lockPath, resource: .index(worktreePath: destination))

        // Act
        let failure = await Self.forkFailure(
            client,
            fixture.request(
                destination: destination, mode: .newBranch(name: "fork-index", start: .sourceHead, upstream: nil)))

        // Assert
        if case .cleanupIncomplete(let primary, let residue) = failure {
            #expect(primary == .gitFailure(.lockHeld(lockFact)))
            #expect(
                residue
                    == [
                        GitWorktreeForkResidue(
                            kind: .linkedWorktreeAdministration, location: "worktrees/\(worktreeName)")
                    ])
        } else {
            Issue.record(
                "expected cleanupIncomplete after refusing to remove foreign lock, got \(String(describing: failure))")
        }
        #expect(GitWorktreeForkFileProbe.exists(lockPath))
        #expect(try Data(contentsOf: lockPath) == lockContents)
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(GitWorktreeForkFileProbe.exists(administration))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("EACCES from destination index writing is reported as permissionDenied")
    func destinationIndexPermissionFailureIsTyped() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-index-eacces")
        let worktreeName = "fork-index-eacces"
        let destination = fixture.destination(worktreeName)
        let administration = fixture.linkedWorktreeAdministration(worktreeName)
        let originalMode = OSAllocatedUnfairLock(initialState: mode_t(0))
        defer {
            let mode = originalMode.withLock { $0 }
            if mode != 0 {
                _ = administration.path.withCString { chmod($0, mode) }
            }
            fixture.remove()
        }
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterWorktreeAdded else {
                return
            }
            var info = Darwin.stat()
            let statResult = administration.path.withCString { lstat($0, &info) }
            guard statResult == 0 else {
                throw .entryFailed(
                    relativePath: "worktrees/\(worktreeName)", reason: .unreadableEntry, errorNumber: errno)
            }
            let observedMode = info.st_mode
            originalMode.withLock { $0 = observedMode }
            let chmodResult = administration.path.withCString { chmod($0, observedMode & ~mode_t(0o222)) }
            guard chmodResult == 0 else {
                throw .entryFailed(
                    relativePath: "worktrees/\(worktreeName)", reason: .unreadableEntry, errorNumber: errno)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await Self.forkFailure(
            client,
            fixture.request(
                destination: destination, mode: .newBranch(name: "fork-index-eacces", start: .sourceHead, upstream: nil)
            ))

        // Assert
        #expect(failure == .gitFailure(.permissionDenied(path: administration)))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(administration))
    }

    @Test("a successful fork releases its reference, admin, index, and config locks")
    func successfulForkLeavesNoTransactionLocks() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-lock-free-success")
        defer { fixture.remove() }
        let commonDirectory = fixture.source.appending(path: ".git")
        let client = LibGit2AgentStudioGitLocalClient()
        let cases: [(name: String, materialization: GitWorktreeForkMaterialization)] = [
            ("copy-on-write", .copyOnWrite),
            ("changes-only", .changesOnly),
        ]

        for forkCase in cases {
            let worktreeName = "fork-\(forkCase.name)"
            let branchName = worktreeName
            let destination = fixture.destination(worktreeName)

            // Act
            _ = try await client.forkWorktree(
                fixture.request(
                    destination: destination,
                    mode: .newBranch(name: branchName, start: .sourceHead, upstream: nil),
                    materialization: forkCase.materialization))

            // Assert
            let lockPaths = [
                commonDirectory.appending(path: "refs/heads/\(branchName).lock"),
                fixture.linkedWorktreeAdministration(worktreeName).appending(path: "HEAD.lock"),
                fixture.linkedWorktreeAdministration(worktreeName).appending(path: "index.lock"),
                fixture.linkedWorktreeAdministration(worktreeName).appending(path: "config.worktree.lock"),
            ]
            #expect(lockPaths.allSatisfy { !GitWorktreeForkFileProbe.exists($0) }, "\(forkCase.name)")
        }
    }

    @Test("a denied release of an acquired branch lock becomes lockFile residue on failure")
    func deniedOwnedBranchLockReleaseIsReported() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-denied-lock-release")
        let referenceDirectory = fixture.source.appending(path: ".git/refs/heads")
        var originalDirectoryStatus = stat()
        let statResult = referenceDirectory.path.withCString { stat($0, &originalDirectoryStatus) }
        guard statResult == 0 else {
            fixture.remove()
            Issue.record("could not stat the branch reference directory")
            return
        }
        let originalMode = originalDirectoryStatus.st_mode
        let readOnlyMode = originalMode & ~mode_t(0o222)
        defer {
            _ = referenceDirectory.path.withCString { chmod($0, originalMode) }
            fixture.remove()
        }
        let branchName = "fork-release-denied"
        let referenceName = "refs/heads/\(branchName)"
        let lockPath = referenceDirectory.appending(path: "\(branchName).lock").standardizedFileURL
        let destination = fixture.destination(branchName)
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterBranchReferenceLockAcquired(referenceName: referenceName) else {
                return
            }
            let chmodResult = referenceDirectory.path.withCString { chmod($0, readOnlyMode) }
            guard chmodResult == 0 else {
                throw .entryFailed(relativePath: "refs/heads", reason: .unreadableEntry, errorNumber: errno)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await Self.forkFailure(
            client,
            fixture.request(
                destination: destination, mode: .newBranch(name: branchName, start: .sourceHead, upstream: nil)))

        // Assert
        #expect(
            failure
                == .cleanupIncomplete(
                    primary: .gitFailure(.permissionDenied(path: referenceDirectory)),
                    residue: [GitWorktreeForkResidue(kind: .lockFile, location: "\(referenceName).lock")]
                )
        )
        #expect(GitWorktreeForkFileProbe.exists(lockPath))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(branchName)))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("an acquired branch lock stays in rollback residue when its parent becomes unsearchable")
    func unsearchableAcquiredBranchLockIsReportedByRollback() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-unsearchable-lock")
        let referenceDirectory = fixture.source.appending(path: ".git/refs/heads")
        var originalDirectoryStatus = stat()
        let statResult = referenceDirectory.path.withCString { stat($0, &originalDirectoryStatus) }
        guard statResult == 0 else {
            fixture.remove()
            Issue.record("could not stat the branch reference directory")
            return
        }
        let originalMode = originalDirectoryStatus.st_mode
        let unreadableMode = mode_t(0)
        defer {
            _ = referenceDirectory.path.withCString { chmod($0, originalMode) }
            fixture.remove()
        }
        let branchName = "fork-unsearchable-lock"
        let referenceName = "refs/heads/\(branchName)"
        let lockPath = referenceDirectory.appending(path: "\(branchName).lock").standardizedFileURL
        let destination = fixture.destination(branchName)
        let chmodResult = OSAllocatedUnfairLock(initialState: Int32(-1))
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterBranchReferenceLockAcquired(referenceName: referenceName) else {
                return
            }
            let result = referenceDirectory.path.withCString { chmod($0, unreadableMode) }
            chmodResult.withLock { $0 = result }
            guard result == 0 else {
                throw .entryFailed(relativePath: "refs/heads", reason: .unreadableEntry, errorNumber: errno)
            }
            throw .entryFailed(relativePath: referenceName, reason: .unreadableEntry, errorNumber: EACCES)
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await Self.forkFailure(
            client,
            fixture.request(
                destination: destination, mode: .newBranch(name: branchName, start: .sourceHead, upstream: nil)))
        _ = referenceDirectory.path.withCString { chmod($0, originalMode) }

        // Assert
        #expect(chmodResult.withLock { $0 } == 0)
        guard case .cleanupIncomplete(let primary, let residue) = failure else {
            Issue.record("expected unreadable acquired lock residue, got \(String(describing: failure))")
            return
        }
        #expect(primary == .entryFailed(relativePath: referenceName, reason: .unreadableEntry, errorNumber: EACCES))
        #expect(residue == [GitWorktreeForkResidue(kind: .lockFile, location: "\(referenceName).lock")])
        #expect(GitWorktreeForkFileProbe.exists(lockPath))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(branchName)))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("an inaccessible never-acquired foreign lock is protected without owned residue")
    func inaccessibleForeignBranchLockIsNotOwnedResidue() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-inaccessible-foreign-lock")
        let referenceDirectory = fixture.source.appending(path: ".git/refs/heads")
        var originalDirectoryStatus = stat()
        let statResult = referenceDirectory.path.withCString { stat($0, &originalDirectoryStatus) }
        guard statResult == 0 else {
            fixture.remove()
            Issue.record("could not stat the branch reference directory")
            return
        }
        let originalMode = originalDirectoryStatus.st_mode
        defer {
            _ = referenceDirectory.path.withCString { chmod($0, originalMode) }
            fixture.remove()
        }
        let branchName = "fork-inaccessible-foreign-lock"
        let lockPath = referenceDirectory.appending(path: "\(branchName).lock").standardizedFileURL
        let lockBytes = Data("foreign lock owned by another writer\n".utf8)
        try lockBytes.write(to: lockPath)
        let chmodResult = OSAllocatedUnfairLock(initialState: Int32(-1))
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterPreflight else {
                return
            }
            let result = referenceDirectory.path.withCString { chmod($0, mode_t(0)) }
            chmodResult.withLock { $0 = result }
            guard result == 0 else {
                throw .entryFailed(relativePath: "refs/heads", reason: .unreadableEntry, errorNumber: errno)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await Self.forkFailure(
            client,
            fixture.request(
                destination: fixture.destination(branchName),
                mode: .newBranch(name: branchName, start: .sourceHead, upstream: nil)))
        _ = referenceDirectory.path.withCString { chmod($0, originalMode) }

        // Assert
        #expect(chmodResult.withLock { $0 } == 0)
        guard case .gitFailure(.permissionDenied(path: let deniedPath)) = failure else {
            Issue.record("expected a permission failure without owned residue, got \(String(describing: failure))")
            return
        }
        #expect(deniedPath == referenceDirectory)
        #expect(try Data(contentsOf: lockPath) == lockBytes)
    }

    @Test("an acquired branch lock that remains at final validation is reported as owned residue")
    func acquiredBranchLockAtSuccessfulValidationIsReported() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-owned-lock-success-check")
        defer { fixture.remove() }
        let branchName = "fork-owned-lock-success"
        let referenceName = "refs/heads/\(branchName)"
        let commonDirectory = fixture.source.appending(path: ".git")
        let referencePath = commonDirectory.appending(path: referenceName).standardizedFileURL
        let lockPath = commonDirectory.appending(path: "\(referenceName).lock").standardizedFileURL
        let destination = fixture.destination(branchName)
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterBranchAttached else {
                return
            }
            // Preserve the inode libgit2 acquired and committed at the lock path to model a survivor at final validation.
            let linkResult = referencePath.path.withCString { referencePointer in
                lockPath.path.withCString { lockPointer in
                    link(referencePointer, lockPointer)
                }
            }
            guard linkResult == 0 else {
                throw .entryFailed(
                    relativePath: lockPath.lastPathComponent, reason: .entryCreationFailed, errorNumber: errno)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await Self.forkFailure(
            client,
            fixture.request(
                destination: destination, mode: .newBranch(name: branchName, start: .sourceHead, upstream: nil)))

        // Assert
        #expect(
            failure
                == .cleanupIncomplete(
                    primary: .validationFailed(
                        reason: .transactionArtifactRemains, relativePath: lockPath.lastPathComponent),
                    residue: [
                        GitWorktreeForkResidue(kind: .lockFile, location: "\(referenceName).lock"),
                        GitWorktreeForkResidue(kind: .createdBranch, location: referenceName),
                    ]
                )
        )
        #expect(GitWorktreeForkFileProbe.exists(lockPath))
        #expect(GitWorktreeForkFileProbe.exists(referencePath))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(branchName)))
        #expect(try fixture.branchNames() == ["refs/heads/fork-owned-lock-success", "refs/heads/main"])
    }

    @Test("a branch created after preflight is preserved instead of moved by the transaction")
    func branchCreatedAfterPreflightIsNotOverwritten() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-branch-created-race")
        defer { fixture.remove() }
        let branchName = "fork-created-after-preflight"
        let referenceName = "refs/heads/\(branchName)"
        let referencePath = fixture.source.appending(path: ".git/\(referenceName)")
        let destination = fixture.destination(branchName)
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterPreflight else {
                return
            }
            do {
                try fixture.git.run("branch", branchName, currentDirectory: fixture.source)
            } catch {
                throw .entryFailed(relativePath: branchName, reason: .entryCreationFailed, errorNumber: nil)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await Self.forkFailure(
            client,
            fixture.request(
                destination: destination, mode: .newBranch(name: branchName, start: .sourceHead, upstream: nil)))

        // Assert
        #expect(failure == .rejected(reason: .branchAlreadyExists))
        #expect(GitWorktreeForkFileProbe.exists(referencePath))
        #expect(
            try fixture.git.run("rev-parse", referenceName, currentDirectory: fixture.source)
                == fixture.git.run("rev-parse", "HEAD", currentDirectory: fixture.source))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(branchName)))
    }

    private static func writeLockFile(_ path: URL, contents: String) throws(GitWorktreeForkError) {
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: path)
        } catch {
            throw .entryFailed(relativePath: path.lastPathComponent, reason: .entryCreationFailed, errorNumber: nil)
        }
    }

    private static func forkFailure(
        _ request: GitForkWorktreeRequest,
        faults: WorktreeForkFaultInjector = .production
    ) async -> GitWorktreeForkError? {
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))
        do {
            _ = try await client.forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }

    private static func forkFailure(
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
