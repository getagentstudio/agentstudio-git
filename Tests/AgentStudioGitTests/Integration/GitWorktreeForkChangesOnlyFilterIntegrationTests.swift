import AgentStudioGit
import CryptoKit
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree changes-only fork filter integration", .serialized)
struct GitWorktreeForkChangesOnlyFilterIntegrationTests {
    @Test("a smudged LFS path that is otherwise unchanged is restored from verified source bytes")
    func smudgedLargeFileIsVerifiedAndCopied() async throws {
        // Arrange
        let (fixture, payload) = try Self.makeSmudgedLargeFileFixture(prefix: "agentstudio-git-fork-lfs-smudged")
        defer { fixture.remove() }
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                destination: destination, mode: .newBranch(name: "fork-lfs-smudged", start: .sourceHead, upstream: nil),
                materialization: .changesOnly)
        )

        // Assert
        guard case .changesOnly(let report) = result.materialization else {
            Issue.record("expected changes-only materialization")
            return
        }
        #expect(report.trackedChanges == 0)
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == payload)
        #expect(try Data(contentsOf: fixture.source.appending(path: "asset.bin")) == payload)
        #expect(report.largeFiles.missing.isEmpty)
        #expect(report.largeFiles.materializedCount == 0)
    }

    @Test("a pointer-only source falls back to the local LFS object store")
    func pointerOnlySourceUsesLocalLargeFileStoreFallback() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-lfs-store-fallback")
        defer { fixture.remove() }
        let payload = Data("local fork LFS payload\n".utf8)
        let objectID = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(objectID)\nsize \(payload.count)\n"
        try fixture.write(".gitattributes", "asset.bin filter=lfs\n")
        try fixture.write("asset.bin", pointer)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "large file pointer with local object")
        let objectPath = fixture.source.appending(
            path: ".git/lfs/objects/\(objectID.prefix(2))/\(objectID.dropFirst(2).prefix(2))/\(objectID)"
        )
        try FileManager.default.createDirectory(
            at: objectPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: objectPath)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                destination: destination,
                mode: .newBranch(name: "fork-lfs-store-fallback", start: .sourceHead, upstream: nil),
                materialization: .changesOnly
            )
        )
        let stagedBlobOID = try fixture.git.run("rev-parse", ":asset.bin", currentDirectory: destination)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headBlobOID = try fixture.git.run("rev-parse", "HEAD:asset.bin", currentDirectory: destination)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Assert
        guard case .changesOnly(let report) = result.materialization else {
            Issue.record("expected changes-only materialization")
            return
        }
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == payload)
        #expect(try Data(contentsOf: fixture.source.appending(path: "asset.bin")) == Data(pointer.utf8))
        #expect(report.largeFiles.materializedCount == 1)
        #expect(report.largeFiles.missing.isEmpty)
        #expect(report.largeFiles.scan == .complete)
        #expect(try fixture.indexStat(at: destination)["asset.bin"]?.size == Int64(pointer.utf8.count))
        #expect(stagedBlobOID == headBlobOID)
        let status = try await LibGit2AgentStudioGitLocalClient()
            .statusFacts(for: destination, options: GitStatusOptions())
            .facts
        #expect(status.summary.changedFileCount == 0)
        #expect(status.entries.isEmpty)
    }

    @Test("a carried pointer mode change stays a pointer when the store has its object")
    func carriedPointerModeChangeIsExcludedFromStoreFallback() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-lfs-carried-pointer-mode")
        defer { fixture.remove() }
        let payload = Data("carried pointer mode fallback payload\n".utf8)
        let objectID = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(objectID)\nsize \(payload.count)\n"
        try fixture.write(".gitattributes", "asset.bin filter=lfs\n")
        try fixture.write("asset.bin", pointer)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "large file pointer with carried mode")
        let objectPath = fixture.source.appending(
            path: ".git/lfs/objects/\(objectID.prefix(2))/\(objectID.dropFirst(2).prefix(2))/\(objectID)"
        )
        try FileManager.default.createDirectory(
            at: objectPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: objectPath)
        let sourceAsset = fixture.source.appending(path: "asset.bin")
        #expect(sourceAsset.path.withCString { chmod($0, 0o755) } == 0)
        let destination = fixture.destination()
        let destinationRootIdentity = OSAllocatedUnfairLock(initialState: Optional<WorktreeForkEntryIdentity>.none)
        let fill = LibGit2LargeFileStoreFill(
            faults: LibGit2LargeFileStoreFillFaultInjector(beforeScanning: { descriptor in
                var info = Darwin.stat()
                guard fstat(descriptor, &info) == 0 else {
                    return
                }
                let observedIdentity = WorktreeForkEntryIdentity(info)
                destinationRootIdentity.withLock { $0 = observedIdentity }
            })
        )
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(largeFileStoreFill: fill)
        )

        // Act
        let result = try await client.forkWorktree(
            fixture.request(
                destination: destination,
                mode: .newBranch(name: "fork-lfs-carried-pointer-mode", start: .sourceHead, upstream: nil),
                materialization: .changesOnly
            )
        )

        // Assert
        guard case .changesOnly(let report) = result.materialization else {
            Issue.record("expected changes-only materialization")
            return
        }
        let destinationAsset = destination.appending(path: "asset.bin")
        let destinationRootInfo = try #require(GitWorktreeForkFileProbe.info(destination))
        let destinationInfo = try #require(GitWorktreeForkFileProbe.info(destinationAsset))
        #expect(destinationRootIdentity.withLock { $0 } == WorktreeForkEntryIdentity(destinationRootInfo))
        #expect(try Data(contentsOf: destinationAsset) == Data(pointer.utf8))
        #expect(destinationInfo.st_mode & S_IXUSR != 0)
        #expect(report.trackedChanges == 1)
        #expect(report.largeFiles.materializedCount == 0)
        #expect(report.largeFiles.missing.isEmpty)
    }

    @Test("an executable-bit-only change on a smudged LFS path is counted and restored")
    func executableModeOnlyLFSChangeIsCountedAndPreserved() async throws {
        // Arrange
        let (fixture, payload) = try Self.makeSmudgedLargeFileFixture(prefix: "agentstudio-git-fork-lfs-mode")
        defer { fixture.remove() }
        let sourceAsset = fixture.source.appending(path: "asset.bin")
        #expect(sourceAsset.path.withCString { chmod($0, 0o755) } == 0)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                destination: destination, mode: .newBranch(name: "fork-lfs-mode", start: .sourceHead, upstream: nil),
                materialization: .changesOnly)
        )

        // Assert
        guard case .changesOnly(let report) = result.materialization else {
            Issue.record("expected changes-only materialization")
            return
        }
        let sourceInfo = try #require(GitWorktreeForkFileProbe.info(sourceAsset))
        let destinationInfo = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: "asset.bin")))
        #expect(report.trackedChanges == 1)
        #expect(sourceInfo.st_mode & S_IXUSR != 0)
        #expect(destinationInfo.st_mode & S_IXUSR != 0)
        #expect(sourceInfo.st_ino != destinationInfo.st_ino)
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == payload)
    }

    @Test("LFS restoration validation rejects a source mode changed after overlay")
    func lfsRestorationSourceModeTamperingFailsValidation() async throws {
        // Arrange
        let (fixture, _) = try Self.makeSmudgedLargeFileFixture(prefix: "agentstudio-git-fork-lfs-source-mode-tamper")
        defer { fixture.remove() }
        let sourceAsset = fixture.source.appending(path: "asset.bin")
        #expect(sourceAsset.path.withCString { chmod($0, 0o755) } == 0)
        let destination = fixture.destination()
        let chmodResult = OSAllocatedUnfairLock(initialState: Int32(-1))
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterChangesOnlyOverlay else {
                return
            }
            let result = sourceAsset.path.withCString { chmod($0, 0o644) }
            chmodResult.withLock { $0 = result }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            writerRegistry: GitRepositoryWriterRegistry(),
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(
                    destination: destination,
                    mode: .newBranch(name: "fork-lfs-source-mode-tamper", start: .sourceHead, upstream: nil),
                    materialization: .changesOnly
                )
            )
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(chmodResult.withLock { $0 } == 0)
        #expect(failure == .sourceChanged(relativePath: "asset.bin", reason: .contentChanged))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-lfs-source-mode-tamper")))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("LFS restoration validation rejects a destination mode changed after overlay")
    func lfsRestorationModeTamperingFailsValidation() async throws {
        // Arrange
        let (fixture, _) = try Self.makeSmudgedLargeFileFixture(prefix: "agentstudio-git-fork-lfs-mode-tamper")
        defer { fixture.remove() }
        let sourceAsset = fixture.source.appending(path: "asset.bin")
        #expect(sourceAsset.path.withCString { chmod($0, 0o755) } == 0)
        let destination = fixture.destination()
        let destinationAsset = destination.appending(path: "asset.bin")
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            if point == .afterChangesOnlyOverlay {
                _ = destinationAsset.path.withCString { chmod($0, 0o644) }
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            writerRegistry: GitRepositoryWriterRegistry(),
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(
                    destination: destination,
                    mode: .newBranch(name: "fork-lfs-mode-tamper", start: .sourceHead, upstream: nil),
                    materialization: .changesOnly
                )
            )
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(failure == .validationFailed(reason: .entryKindMismatch, relativePath: "asset.bin"))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-lfs-mode-tamper")))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("LFS restoration validation rejects a destination linked to the source inode")
    func lfsRestorationSourceInodeReuseFailsValidation() async throws {
        // Arrange
        let (fixture, _) = try Self.makeSmudgedLargeFileFixture(prefix: "agentstudio-git-fork-lfs-inode-tamper")
        defer { fixture.remove() }
        let sourceAsset = fixture.source.appending(path: "asset.bin")
        #expect(sourceAsset.path.withCString { chmod($0, 0o755) } == 0)
        let destination = fixture.destination()
        let destinationAsset = destination.appending(path: "asset.bin")
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterChangesOnlyOverlay else {
                return
            }
            try? FileManager.default.removeItem(at: destinationAsset)
            _ = sourceAsset.path.withCString { sourcePath in
                destinationAsset.path.withCString { destinationPath in
                    link(sourcePath, destinationPath)
                }
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            writerRegistry: GitRepositoryWriterRegistry(),
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(
                    destination: destination,
                    mode: .newBranch(name: "fork-lfs-inode-tamper", start: .sourceHead, upstream: nil),
                    materialization: .changesOnly
                )
            )
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(failure == .validationFailed(reason: .entryKindMismatch, relativePath: "asset.bin"))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-lfs-inode-tamper")))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("a source that only has LFS pointer text keeps the checked-out pointer")
    func pointerOnlyLargeFileStaysPointer() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-lfs-pointer")
        defer { fixture.remove() }
        let pointer =
            "version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "a", count: 64))\nsize 81\n"
        try fixture.write(".gitattributes", "asset.bin filter=lfs\n")
        try fixture.write("asset.bin", pointer)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "large file pointer only")
        let destination = fixture.destination()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: fixture.source,
            destinationPath: destination,
            mode: .newBranch(name: "fork-lfs-pointer", start: .sourceHead, upstream: nil),
            materialization: .changesOnly,
            copyRules: GitWorktreeCopyRules(ignoredPaths: .copyAll)
        )

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)

        // Assert
        #expect(try String(contentsOf: destination.appending(path: "asset.bin"), encoding: .utf8) == pointer)
        guard case .changesOnly(let report) = result.materialization else {
            Issue.record("expected changes-only materialization")
            return
        }
        #expect(report.largeFiles.materializedCount == 0)
        #expect(
            report.largeFiles.missing == [
                GitLargeFileFillMiss(path: "asset.bin", reason: .objectAbsent)
            ]
        )
        #expect(report.largeFiles.scan == .complete)
    }

    @Test("a custom filter is refused before branch, administration, or destination mutation")
    func customFilterRefusesBeforeMutation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-custom-filter")
        defer { fixture.remove() }
        try fixture.write(".gitattributes", "asset.bin filter=custom\n")
        try fixture.write("asset.bin", "custom content\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "custom filter path")
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: fixture.source,
            destinationPath: destination,
            mode: .newBranch(name: "fork-custom-filter", start: .sourceHead, upstream: nil),
            materialization: .changesOnly,
            copyRules: GitWorktreeCopyRules(ignoredPaths: .copyAll)
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        #expect(
            failure
                == .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(reason: .customFilter, relativePath: "asset.bin")))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    @Test("edited attributes refuse before custom filter evaluation")
    func editedAttributesRefuseBeforeFilterEvaluation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-edited-attributes")
        defer { fixture.remove() }
        let headAttributes = "asset.bin -filter\n"
        try fixture.write(".gitattributes", headAttributes)
        try fixture.write("asset.bin", "tracked payload\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "attribute baseline")
        try fixture.write(".gitattributes", "asset.bin filter=custom\n")
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: "fork-edited-attributes", start: .sourceHead, upstream: nil),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        guard case .workingStateUnsupported(let refusal) = failure else {
            Issue.record("expected an attributes preflight refusal, got \(String(describing: failure))")
            return
        }
        #expect(refusal.reason.rawValue == "attributesChanged")
        #expect(refusal.relativePath == ".gitattributes")
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-edited-attributes")))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    @Test("staged-only attribute changes refuse before filter evaluation")
    func stagedOnlyAttributesRefuseBeforeFilterEvaluation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-staged-attributes")
        defer { fixture.remove() }
        let headAttributes = "asset.bin -filter\n"
        try fixture.write(".gitattributes", headAttributes)
        try fixture.write("asset.bin", "tracked payload\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "attribute baseline")
        try fixture.write(".gitattributes", "asset.bin filter=custom\n")
        try fixture.git.run("add", ".gitattributes")
        try fixture.write(".gitattributes", headAttributes)
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: "fork-staged-attributes", start: .sourceHead, upstream: nil),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        guard case .workingStateUnsupported(let refusal) = failure else {
            Issue.record("expected an attributes preflight refusal, got \(String(describing: failure))")
            return
        }
        #expect(refusal.reason.rawValue == "attributesChanged")
        #expect(refusal.relativePath == ".gitattributes")
        #expect(try Data(contentsOf: fixture.source.appending(path: ".gitattributes")) == Data(headAttributes.utf8))
        #expect(!(try fixture.git.succeeds("diff", "--cached", "--quiet", "--", ".gitattributes")))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-staged-attributes")))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    @Test("an ignored nested attributes override is refused before filter evaluation")
    func ignoredNestedAttributesOverrideRefusesBeforeFilterEvaluation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-ignored-nested-attributes")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "nested/.gitattributes\n")
        try fixture.write(".gitattributes", "*.bin filter=custom\n")
        try fixture.write("nested/asset.bin", "custom content\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "nested attribute baseline")
        try fixture.write("nested/.gitattributes", "asset.bin -filter\n")
        #expect(try fixture.git.succeeds("check-ignore", "--quiet", "--", "nested/.gitattributes"))
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: "fork-ignored-nested-attributes", start: .sourceHead, upstream: nil),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        #expect(
            failure
                == .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(
                        reason: .attributesChanged,
                        relativePath: "nested/.gitattributes"
                    )
                )
        )
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(
            !GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-ignored-nested-attributes")))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    @Test("an ignored root attributes override is refused before filter evaluation")
    func ignoredRootAttributesOverrideRefusesBeforeFilterEvaluation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-ignored-root-attributes")
        defer { fixture.remove() }
        try fixture.write(".gitignore", ".gitattributes\n")
        try fixture.write("asset.bin", "tracked content\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "root attribute baseline")
        try fixture.write(".gitattributes", "asset.bin filter=custom\n")
        #expect(try fixture.git.succeeds("check-ignore", "--quiet", "--", ".gitattributes"))
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: "fork-ignored-root-attributes", start: .sourceHead, upstream: nil),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        #expect(
            failure
                == .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(reason: .attributesChanged, relativePath: ".gitattributes"))
        )
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-ignored-root-attributes")))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    @Test("unchanged nested HEAD attributes still restore verified LFS content")
    func unchangedNestedHeadAttributesAllowVerifiedLargeFileRestoration() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-nested-lfs-attributes")
        defer { fixture.remove() }
        let payload = Data("nested verified large file payload\n".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(hash)\nsize \(payload.count)\n"
        try fixture.write("nested/.gitattributes", "asset.bin filter=lfs\n")
        try fixture.write("nested/asset.bin", pointer)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "nested LFS pointer")
        try payload.write(to: fixture.source.appending(path: "nested/asset.bin"))
        let destination = fixture.destination()
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: "fork-nested-lfs-attributes", start: .sourceHead, upstream: nil),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        #expect(failure == nil)
        #expect(try Data(contentsOf: destination.appending(path: "nested/asset.bin")) == payload)
        #expect(try Data(contentsOf: fixture.source.appending(path: "nested/asset.bin")) == payload)
    }

    private func forkFailure(_ request: GitForkWorktreeRequest) async -> GitWorktreeForkError? {
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }

    private static func makeSmudgedLargeFileFixture(prefix: String) throws
        -> (fixture: GitWorktreeForkFixture, payload: Data)
    {
        let fixture = try GitWorktreeForkFixture.make(prefix: prefix)
        let payload = Data("verified large file payload\n".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(hash)\nsize \(payload.count)\n"
        try fixture.write(".gitattributes", "asset.bin filter=lfs\n")
        try fixture.write("asset.bin", pointer)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "large file pointer")
        try payload.write(to: fixture.source.appending(path: "asset.bin"))
        return (fixture, payload)
    }
}
