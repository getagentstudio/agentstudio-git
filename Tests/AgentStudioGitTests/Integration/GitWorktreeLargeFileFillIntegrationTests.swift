import AgentStudioGit
import CryptoKit
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree large-file fill integration", .serialized)
struct GitWorktreeLargeFileFillIntegrationTests {
    @Test("create fills a normal LFS pointer from the default local object store")
    func createFillsNormalLargeFileFromDefaultStore() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-normal")
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        try assertFixtureObjectIsValid(fixture)
        let destination = fixture.repository.linkedWorktreePath("lfs-normal")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-normal")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
        #expect(creation.largeFiles.materializedCount == 1)
        #expect(creation.largeFiles.missing.isEmpty)
        #expect(creation.largeFiles.scan == .complete)
        let indexEntry = try indexEntry(for: "asset.bin", worktree: destination)
        #expect(indexEntry.contains("100644"))
        #expect(indexEntry.contains(fixture.pointerBlobOID))
        #expect(try fileMode(destination.appending(path: "asset.bin")) & 0o111 == 0)
        let indexDebug = try GitProcess(repositoryPath: destination).run("ls-files", "--debug", "--", "asset.bin")
        #expect(indexDebug.contains("size: \(fixture.pointer.utf8.count)"))
        let status = try await LibGit2AgentStudioGitLocalClient()
            .statusFacts(for: destination, options: GitStatusOptions())
            .facts
        #expect(status.summary.changedFileCount == 0)
        #expect(status.entries.isEmpty)
    }

    @Test("status treats LFS pointers and matching content as clean but changed payload as modified")
    func statusSuppressesCleanLargeFilePointerAndMatchingPayload() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-status")
        defer { fixture.repository.remove() }
        let fileURL = fixture.repository.repositoryPath.appending(path: "asset.bin")
        let changedPayload = Data(repeating: 0x78, count: fixture.payload.count)
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        try fixture.payload.write(to: fileURL)
        let matchingContentStatus = try await client.statusFacts(
            for: fixture.repository.repositoryPath,
            options: GitStatusOptions()
        ).facts
        try changedPayload.write(to: fileURL)
        let changedContentStatus = try await client.statusFacts(
            for: fixture.repository.repositoryPath,
            options: GitStatusOptions()
        ).facts
        try Data(fixture.pointer.utf8).write(to: fileURL)
        let pointerStatus = try await client.statusFacts(
            for: fixture.repository.repositoryPath,
            options: GitStatusOptions()
        ).facts

        // Assert
        #expect(matchingContentStatus.summary.changedFileCount == 0)
        #expect(matchingContentStatus.entries.isEmpty)
        #expect(changedContentStatus.summary.changedFileCount == 1)
        #expect(changedContentStatus.entries.first?.worktreeState == .modified)
        #expect(pointerStatus.summary.changedFileCount == 0)
        #expect(pointerStatus.entries.isEmpty)
    }

    @Test("create preserves the executable index mode when filling an LFS pointer")
    func createFillsExecutableLargeFileWithIndexMode() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-executable", executable: true)
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        try assertFixtureObjectIsValid(fixture)
        let destination = fixture.repository.linkedWorktreePath("lfs-executable")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-executable")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
        #expect(creation.largeFiles.materializedCount == 1)
        #expect(creation.largeFiles.scan == .complete)
        let indexEntry = try indexEntry(for: "asset.bin", worktree: destination)
        #expect(indexEntry.contains("100755"))
        #expect(indexEntry.contains(fixture.pointerBlobOID))
        #expect(try fileMode(destination.appending(path: "asset.bin")) & 0o111 != 0)
    }

    @Test("a missing object keeps the pointer and reports objectAbsent")
    func missingObjectKeepsPointerAndReportsTypedMiss() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-absent")
        defer { fixture.repository.remove() }
        let destination = fixture.repository.linkedWorktreePath("lfs-absent")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-absent")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        #expect(
            creation.largeFiles.missing == [
                GitLargeFileFillMiss(path: "asset.bin", reason: .objectAbsent)
            ]
        )
        #expect(creation.largeFiles.materializedCount == 0)
        #expect(creation.largeFiles.scan == .complete)
    }

    @Test("a mismatched object leaves the pointer and removes its temporary file")
    func mismatchedObjectLeavesNoPartialFile() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-mismatch")
        defer { fixture.repository.remove() }
        let wrongPayload = Data(repeating: 0x78, count: fixture.payload.count)
        try fixture.writeObject(wrongPayload)
        let destination = fixture.repository.linkedWorktreePath("lfs-mismatch")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-mismatch")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        #expect(
            creation.largeFiles.missing == [
                GitLargeFileFillMiss(path: "asset.bin", reason: .objectMismatch)
            ]
        )
        #expect(creation.largeFiles.scan == .complete)
        let destinationNames = try FileManager.default.contentsOfDirectory(
            atPath: destination.path
        )
        #expect(!destinationNames.contains(where: { $0.hasPrefix(".agentstudio-lfs-fill-") }))
    }

    @Test("a clone EEXIST collision preserves the foreign temp and the pointer")
    func cloneCollisionPreservesForeignTemporaryAndPointer() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-temp-collision")
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        let destination = fixture.repository.linkedWorktreePath("lfs-temp-collision")
        let temporaryName = ".agentstudio-lfs-fill-collision"
        let foreignContents = Data("foreign temporary file\n".utf8)
        let setupError = OSAllocatedUnfairLock(initialState: Optional<Int32>.none)
        let faults = LibGit2LargeFileStoreFaultInjector(
            temporaryName: temporaryName,
            cloneError: EEXIST,
            beforeClone: { parentDescriptor, name in
                let descriptor = name.withCString {
                    openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                }
                guard descriptor >= 0 else {
                    setupError.withLock { $0 = errno }
                    return
                }
                defer { close(descriptor) }
                let writtenByteCount = foreignContents.withUnsafeBytes { bytes in
                    write(descriptor, bytes.baseAddress, bytes.count)
                }
                if writtenByteCount != foreignContents.count {
                    setupError.withLock { $0 = writtenByteCount < 0 ? errno : EIO }
                }
            }
        )
        let store = LibGit2LargeFileStore(faults: faults)
        let writer = LibGit2WorktreeWriter(largeFileStoreFill: LibGit2LargeFileStoreFill(store: store))
        let client = LibGit2AgentStudioGitLocalClient(worktreeWriter: writer)

        // Act
        let creation = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repository.repositoryPath,
                destinationPath: destination,
                mode: .newBranch(name: "lfs-temp-collision", startPoint: .named("HEAD"), upstream: nil)
            )
        )

        // Assert
        #expect(setupError.withLock { $0 } == nil)
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        #expect(
            creation.largeFiles.missing == [
                GitLargeFileFillMiss(path: "asset.bin", reason: .writeFailed(errno: EEXIST))
            ]
        )
        let foreignTemporary = destination.appending(path: temporaryName)
        #expect(FileManager.default.fileExists(atPath: foreignTemporary.path))
        #expect(try Data(contentsOf: foreignTemporary) == foreignContents)
        #expect(creation.largeFiles.residuePaths.isEmpty)
    }

    @Test("clone unsupported errors copy the verified object exclusively")
    func unsupportedCloneErrorsFallBackToExclusiveCopy() async throws {
        // Arrange / Act / Assert
        for (index, cloneError) in [ENOTSUP, EXDEV].enumerated() {
            let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-copy-fallback-\(index)")
            defer { fixture.repository.remove() }
            try fixture.writeObject(fixture.payload)
            let destination = fixture.repository.linkedWorktreePath("lfs-copy-fallback-\(index)")
            let store = LibGit2LargeFileStore(faults: LibGit2LargeFileStoreFaultInjector(cloneError: cloneError))
            let writer = LibGit2WorktreeWriter(largeFileStoreFill: LibGit2LargeFileStoreFill(store: store))
            let client = LibGit2AgentStudioGitLocalClient(worktreeWriter: writer)

            let creation = try await client.createWorktree(
                GitCreateWorktreeRequest(
                    repositoryPath: fixture.repository.repositoryPath,
                    destinationPath: destination,
                    mode: .newBranch(name: "lfs-copy-fallback-\(index)", startPoint: .named("HEAD"), upstream: nil)
                )
            )

            #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
            #expect(creation.largeFiles.materializedCount == 1)
            #expect(creation.largeFiles.missing.isEmpty)
            #expect(creation.largeFiles.residuePaths.isEmpty)
        }
    }

    @Test("failed cleanup of an owned temporary is reported as residue")
    func failedOwnedTemporaryCleanupAppearsInResiduePaths() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-temp-residue")
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        let destination = fixture.repository.linkedWorktreePath("lfs-temp-residue")
        let temporaryName = ".agentstudio-lfs-fill-owned"
        let permissionError = OSAllocatedUnfairLock(initialState: Optional<Int32>.none)
        let faults = LibGit2LargeFileStoreFaultInjector(
            temporaryName: temporaryName,
            cloneError: ENOTSUP,
            afterTemporaryAcquired: { parentDescriptor, _ in
                if fchmod(parentDescriptor, 0o555) != 0 {
                    permissionError.withLock { $0 = errno }
                }
            }
        )
        let store = LibGit2LargeFileStore(faults: faults)
        let writer = LibGit2WorktreeWriter(largeFileStoreFill: LibGit2LargeFileStoreFill(store: store))
        let client = LibGit2AgentStudioGitLocalClient(worktreeWriter: writer)

        // Act
        let creation = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repository.repositoryPath,
                destinationPath: destination,
                mode: .newBranch(name: "lfs-temp-residue", startPoint: .named("HEAD"), upstream: nil)
            )
        )
        let restorePermissionsResult = destination.path.withCString { chmod($0, 0o755) }

        // Assert
        #expect(permissionError.withLock { $0 } == nil)
        #expect(restorePermissionsResult == 0)
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        #expect(
            creation.largeFiles.missing == [
                GitLargeFileFillMiss(path: "asset.bin", reason: .writeFailed(errno: EACCES))
            ]
        )
        #expect(creation.largeFiles.residuePaths == [temporaryName])
        let residualTemporary = destination.appending(path: temporaryName)
        #expect(FileManager.default.fileExists(atPath: residualTemporary.path))
        #expect(try Data(contentsOf: residualTemporary) == fixture.payload)
        try FileManager.default.removeItem(at: residualTemporary)
    }

    @Test("create honors relative lfs.storage from the common Git directory")
    func createUsesConfiguredLocalStore() async throws {
        // Arrange
        let fixture = try Self.makeFixture(
            prefix: "agentstudio-git-lfs-configured-store",
            configuredStorage: "custom-lfs"
        )
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        try assertFixtureObjectIsValid(fixture)
        let destination = fixture.repository.linkedWorktreePath("lfs-configured")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-configured")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
        #expect(creation.largeFiles.materializedCount == 1)
        #expect(creation.largeFiles.missing.isEmpty)
        #expect(creation.largeFiles.scan == .complete)
    }

    @Test("create treats an empty lfs.storage value as the default local object store")
    func createUsesDefaultLocalStoreForEmptyConfiguredStorage() async throws {
        // Arrange
        let fixture = try Self.makeFixture(
            prefix: "agentstudio-git-lfs-empty-configured-store",
            configuredStorage: ""
        )
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        let destination = fixture.repository.linkedWorktreePath("lfs-empty-configured-store")

        // Act
        let creation = try await createWorktree(
            fixture,
            destination: destination,
            branch: "lfs-empty-configured-store"
        )

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
        #expect(creation.largeFiles.materializedCount == 1)
        #expect(creation.largeFiles.missing.isEmpty)
        #expect(creation.largeFiles.scan == .complete)
    }

    @Test("a newly filled LFS payload reads clean and removes without force")
    func filledLargeFileIsCleanForStatusAndRemoval() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-removal-clean")
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        let destination = fixture.repository.linkedWorktreePath("lfs-removal-clean")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-removal-clean")
        let indexDebug = try GitProcess(repositoryPath: destination).run("ls-files", "--debug", "--", "asset.bin")
        let status = try await client.statusFacts(for: destination, options: GitStatusOptions()).facts
        let removal = try await client.removeWorktree(
            GitRemoveWorktreeRequest(
                worktreeID: creation.worktree.id,
                canonicalPath: creation.worktree.canonicalPath,
                removeWorkingDirectory: true,
                forceDiscardChanges: false
            )
        )

        // Assert
        #expect(indexDebug.contains("size: \(fixture.pointer.utf8.count)"))
        #expect(status.summary.changedFileCount == 0)
        #expect(status.entries.isEmpty)
        #expect(removal.removedWorktreeID == creation.worktree.id)
        #expect(removal.effects.workingDirectory == .removed)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("non-forced removal refuses a same-size incorrect LFS payload")
    func nonForcedRemovalRefusesIncorrectLargeFilePayload() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-removal-wrong")
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        let destination = fixture.repository.linkedWorktreePath("lfs-removal-wrong")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-removal-wrong")
        try Data(repeating: 0x78, count: fixture.payload.count).write(to: destination.appending(path: "asset.bin"))
        var removalError: GitDataPlaneError?
        do {
            _ = try await client.removeWorktree(
                GitRemoveWorktreeRequest(
                    worktreeID: creation.worktree.id,
                    canonicalPath: creation.worktree.canonicalPath,
                    removeWorkingDirectory: true,
                    forceDiscardChanges: false
                )
            )
        } catch {
            removalError = error
        }

        // Assert
        #expect(removalError == .unsafeWorktreeRemoval(reason: .dirtyTrackedChanges))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("an early scan failure is reported without failing worktree creation")
    func earlyScanFailureKeepsWorktreeAndReportsIncompleteScan() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-scan-failure")
        defer { fixture.repository.remove() }
        let destination = fixture.repository.linkedWorktreePath("lfs-scan-failure")
        let faults = LibGit2LargeFileStoreFillFaultInjector(scanFailure: .readFailed(errno: EIO))
        let storeFill = LibGit2LargeFileStoreFill(faults: faults)
        let writer = LibGit2WorktreeWriter(largeFileStoreFill: storeFill)
        let client = LibGit2AgentStudioGitLocalClient(worktreeWriter: writer)

        // Act
        let creation = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repository.repositoryPath,
                destinationPath: destination,
                mode: .newBranch(name: "lfs-index-lock", startPoint: .named("HEAD"), upstream: nil)
            )
        )

        // Assert
        #expect(creation.largeFiles.materializedCount == 0)
        #expect(creation.largeFiles.missing.isEmpty)
        #expect(creation.largeFiles.scan == .incomplete(.readFailed(errno: EIO)))
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        #expect(try GitProcess(repositoryPath: destination).succeeds("rev-parse", "--verify", "HEAD"))
    }

    @Test("a staged edit made during fill survives without a fill index write")
    func stagedEditDuringFillSurvivesWithoutFillIndexWrite() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-stage-during-fill")
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        let destination = fixture.repository.linkedWorktreePath("lfs-stage-during-fill")
        let stagedFile = destination.appending(path: "staged.txt")
        let stagingError = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        let stagedBlobOID = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        let faults = LibGit2LargeFileStoreFillFaultInjector(beforeReturning: {
            do {
                try Data("staged during LFS fill\n".utf8).write(to: stagedFile)
                let git = GitProcess(repositoryPath: destination)
                try git.run("add", "staged.txt")
                let blobOID = try git.run("rev-parse", ":staged.txt")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stagedBlobOID.withLock { $0 = blobOID }
            } catch {
                stagingError.withLock { $0 = String(describing: error) }
            }
        })
        let writer = LibGit2WorktreeWriter(largeFileStoreFill: LibGit2LargeFileStoreFill(faults: faults))
        let client = LibGit2AgentStudioGitLocalClient(worktreeWriter: writer)

        // Act
        let creation = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repository.repositoryPath,
                destinationPath: destination,
                mode: .newBranch(name: "lfs-stage-during-fill", startPoint: .named("HEAD"), upstream: nil)
            )
        )

        // Assert
        let expectedBlobOID = try #require(stagedBlobOID.withLock { $0 })
        #expect(stagingError.withLock { $0 } == nil)
        #expect(creation.largeFiles.materializedCount == 1)
        #expect(creation.largeFiles.scan == .complete)
        #expect(
            try GitProcess(repositoryPath: destination).run("ls-files", "--stage", "--", "staged.txt")
                .contains(expectedBlobOID))
        #expect(try Data(contentsOf: stagedFile) == Data("staged during LFS fill\n".utf8))
    }

    private func createWorktree(
        _ fixture: LargeFileFixture,
        destination: URL,
        branch: String
    ) async throws -> GitWorktreeCreation {
        try await LibGit2AgentStudioGitLocalClient().createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repository.repositoryPath,
                destinationPath: destination,
                mode: .newBranch(name: branch, startPoint: .named("HEAD"), upstream: nil)
            )
        )
    }

    private func indexEntry(for path: String, worktree: URL) throws -> String {
        try GitProcess(repositoryPath: worktree).run("ls-files", "--stage", "--", path)
    }

    private func assertFixtureObjectIsValid(_ fixture: LargeFileFixture) throws {
        let storedContents = try Data(contentsOf: fixture.objectPath)
        let pointer = try #require(LargeFilePointer(data: Data(fixture.pointer.utf8)))
        let payloadSHA256 = SHA256.hash(data: fixture.payload).map { String(format: "%02x", $0) }.joined()

        #expect(storedContents == fixture.payload)
        #expect(pointer.payloadByteCount == fixture.payload.count)
        #expect(pointer.payloadSHA256 == fixture.objectID)
        #expect(payloadSHA256 == fixture.objectID)
    }

    private func fileMode(_ path: URL) throws -> mode_t {
        var info = Darwin.stat()
        let result = path.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return info.st_mode
    }

    private static func makeFixture(
        prefix: String,
        executable: Bool = false,
        configuredStorage: String? = nil
    ) throws -> LargeFileFixture {
        let repository = try GitFixtureRepository.makeRepository(prefix: prefix)
        let payload = Data("real large file payload for \(prefix)\n".utf8)
        let objectID = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(objectID)\nsize \(payload.count)\n"
        try repository.write(".gitattributes", contents: "*.bin filter=lfs diff=lfs merge=lfs -text\n")
        try repository.write("asset.bin", contents: pointer)
        if executable {
            let chmodResult = repository.repositoryPath.appending(path: "asset.bin").path.withCString {
                chmod($0, 0o755)
            }
            guard chmodResult == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        if let configuredStorage {
            try repository.git.run("config", "lfs.storage", configuredStorage)
        }
        try repository.git.run("add", ".gitattributes", "asset.bin")
        try repository.git.run("commit", "-m", "commit LFS pointer")
        let pointerBlobOID = try repository.git.run("hash-object", "asset.bin")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LargeFileFixture(
            repository: repository,
            payload: payload,
            pointer: pointer,
            objectID: objectID,
            pointerBlobOID: pointerBlobOID,
            objectStorageRoot: repository.repositoryPath.appending(
                path: configuredStorage.flatMap { $0.isEmpty ? nil : ".git/\($0)/objects" }
                    ?? ".git/lfs/objects"
            )
        )
    }
}

private struct LargeFileFixture {
    let repository: GitFixtureRepository
    let payload: Data
    let pointer: String
    let objectID: String
    let pointerBlobOID: String
    let objectStorageRoot: URL

    var objectPath: URL {
        objectStorageRoot
            .appending(path: String(objectID.prefix(2)))
            .appending(path: String(objectID.dropFirst(2).prefix(2)))
            .appending(path: objectID)
    }

    func writeObject(_ contents: Data) throws {
        let objectDirectory = objectPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        try contents.write(to: objectPath)
    }
}
