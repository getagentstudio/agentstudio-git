import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// Containment of private-administration counterpart cloning. A configuration value is canonicalized before
/// re-homing, so a symlink can only reach the clone if it is swapped in afterwards; these tests hand the clone
/// such a path directly.
@Suite("Worktree fork private counterparts")
struct WorktreeForkPrivateCounterpartTests {
    @Test(
        "a symlinked intermediate directory on either side fails typed and writes nothing outside",
        arguments: [CounterpartSymlinkSide.source, .destination])
    func symlinkedIntermediateDirectoryFailsTyped(side: CounterpartSymlinkSide) throws {
        // Arrange
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceAdministration = root.appending(path: "source-admin")
        let destinationAdministration = root.appending(path: "destination-admin")
        let outside = root.appending(path: "outside")
        for directory in [sourceAdministration, destinationAdministration, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("outside\n".utf8).write(to: outside.appending(path: "allowed_signers"))
        switch side {
        case .source:
            try FileManager.default.createSymbolicLink(
                at: sourceAdministration.appending(path: "keys"), withDestinationURL: outside)
        case .destination:
            try FileManager.default.createDirectory(
                at: sourceAdministration.appending(path: "keys"), withIntermediateDirectories: true)
            try Data("private\n".utf8).write(to: sourceAdministration.appending(path: "keys/allowed_signers"))
            try FileManager.default.createSymbolicLink(
                at: destinationAdministration.appending(path: "keys"), withDestinationURL: outside)
        }
        let match = WorktreeForkSourcePathRelocation.AdministrationMatch(
            sourceAdministration: sourceAdministration, destinationAdministration: destinationAdministration,
            remainder: "keys/allowed_signers")

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try WorktreeForkPrivateAdministrationCounterparts.realize(match) { $0 }
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        switch side {
        case .source:
            #expect(failure == .sourceChanged(relativePath: "keys", reason: .containmentEscape))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destinationAdministration.path).isEmpty)
        case .destination:
            #expect(
                failure == .entryFailed(relativePath: "keys", reason: .unresolvableGitAdministration, errorNumber: nil))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destinationAdministration.path) == ["keys"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["allowed_signers"])
        #expect(try String(contentsOf: outside.appending(path: "allowed_signers"), encoding: .utf8) == "outside\n")
    }

    @Test(
        "a destination ancestor swapped for a symlink after its descriptor was opened never redirects the clone",
        arguments: AncestorSwap.allCases)
    func destinationAncestorSwappedAfterOpenNeverRedirectsTheClone(swap: AncestorSwap) throws {
        // Arrange: the seam swaps the destination parent of the entry for a symlink to an outside directory
        // after the parent's descriptor is open; every write must still land in the original directory.
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceAdministration = root.appending(path: "source-admin")
        let destinationAdministration = root.appending(path: "destination-admin")
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(
            at: sourceAdministration.appending(path: "keys"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationAdministration, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private\n".utf8).write(to: sourceAdministration.appending(path: "keys/allowed_signers"))
        try Data("outside\n".utf8).write(to: outside.appending(path: "allowed_signers"))
        let swappedAncestor: URL
        let swapPoint: String
        switch swap {
        case .replacedFileParent:
            try FileManager.default.createDirectory(
                at: destinationAdministration.appending(path: "keys"), withIntermediateDirectories: true)
            try Data("common\n".utf8).write(to: destinationAdministration.appending(path: "keys/allowed_signers"))
            swappedAncestor = destinationAdministration.appending(path: "keys")
            swapPoint = "keys/allowed_signers"
        case .missingDirectoryParent:
            swappedAncestor = destinationAdministration
            swapPoint = "keys"
        }
        let moved = swappedAncestor.appendingPathExtension("moved")
        let match = WorktreeForkSourcePathRelocation.AdministrationMatch(
            sourceAdministration: sourceAdministration, destinationAdministration: destinationAdministration,
            remainder: "keys/allowed_signers")

        let swapAncestor: (String) -> Void = { entryPath in
            guard entryPath == swapPoint else {
                return
            }
            try? FileManager.default.moveItem(at: swappedAncestor, to: moved)
            try? FileManager.default.createSymbolicLink(at: swappedAncestor, withDestinationURL: outside)
        }

        // Act
        let realization = try WorktreeForkPrivateAdministrationCounterparts.realize(
            match, reportPath: { $0 },
            atCheckpoint: { checkpoint in
                if case .parentsOpened(let entryPath) = checkpoint {
                    swapAncestor(entryPath)
                }
            })

        // Assert
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["allowed_signers"])
        #expect(try String(contentsOf: outside.appending(path: "allowed_signers"), encoding: .utf8) == "outside\n")
        switch (swap, realization) {
        case (.replacedFileParent, .clonedFile):
            #expect(try String(contentsOf: moved.appending(path: "allowed_signers"), encoding: .utf8) == "private\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["allowed_signers"])
        case (.missingDirectoryParent, .clonedDirectory):
            #expect(
                try String(contentsOf: moved.appending(path: "keys/allowed_signers"), encoding: .utf8) == "private\n")
        default:
            Issue.record("unexpected realization for \(swap)")
        }
    }

    @Test(
        "an unreadable destination target fails typed before any permission changes, even when it is a source alias",
        arguments: UnreadableTarget.allCases)
    func unreadableTargetFailsBeforeAnyPermissionChange(target: UnreadableTarget) throws {
        // Arrange: the private source differs from the destination's existing file, so the target is replaced.
        let root = try temporaryRoot()
        let sourceWorktreeFile = root.appending(path: "source-worktree/secret.txt")
        let destinationAdministration = root.appending(path: "destination-admin")
        let destinationTarget = destinationAdministration.appending(path: "keys/allowed_signers")
        defer {
            _ = chmod(sourceWorktreeFile.path, 0o644)
            _ = chmod(destinationTarget.path, 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        let sourceAdministration = root.appending(path: "source-admin")
        for directory in [
            sourceAdministration.appending(path: "keys"), destinationAdministration.appending(path: "keys"),
            sourceWorktreeFile.deletingLastPathComponent(),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("private\n".utf8).write(to: sourceAdministration.appending(path: "keys/allowed_signers"))
        try Data("common\n".utf8).write(to: destinationTarget)
        try Data("source worktree\n".utf8).write(to: sourceWorktreeFile)
        try #require(chmod(sourceWorktreeFile.path, 0o000) == 0)
        if target == .modeZero {
            try #require(chmod(destinationTarget.path, 0o000) == 0)
        }
        let sourceBefore = try #require(GitWorktreeForkFileProbe.info(sourceWorktreeFile))
        let match = WorktreeForkSourcePathRelocation.AdministrationMatch(
            sourceAdministration: sourceAdministration, destinationAdministration: destinationAdministration,
            remainder: "keys/allowed_signers")
        typealias Checkpoint = WorktreeForkPrivateAdministrationCounterparts.RealizationCheckpoint
        let replaceWithSourceAlias: (Checkpoint) -> Void = { checkpoint in
            guard target == .hardLinkToSourceSwappedAfterStat,
                checkpoint == .targetExamined(entryPath: "keys/allowed_signers")
            else {
                return
            }
            _ = unlink(destinationTarget.path)
            _ = link(sourceWorktreeFile.path, destinationTarget.path)
        }

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try WorktreeForkPrivateAdministrationCounterparts.realize(
                match, reportPath: { $0 }, atCheckpoint: replaceWithSourceAlias)
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(
            failure == .entryFailed(relativePath: "keys/allowed_signers", reason: .unreadableEntry, errorNumber: EACCES)
        )
        let sourceAfter = try #require(GitWorktreeForkFileProbe.info(sourceWorktreeFile))
        #expect(sourceAfter.st_mode & 0o7777 == 0o000, "the source file's mode never changes")
        #expect(sourceAfter.st_mode == sourceBefore.st_mode && sourceAfter.st_flags == sourceBefore.st_flags)
        #expect(acl_get_link_np(sourceWorktreeFile.path, ACL_TYPE_EXTENDED) == nil)
        let destinationInfo = try #require(GitWorktreeForkFileProbe.info(destinationTarget))
        #expect(destinationInfo.st_mode & 0o7777 == 0o000, "the target's mode is never changed either")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destinationAdministration.appending(path: "keys").path)
                == ["allowed_signers"])
    }

    @Test("a metadata-preserving rewrite of a file its owner cannot read fails typed without changing its mode")
    func rewriteOfUnreadableFileFailsWithoutChangingItsMode() throws {
        // Arrange
        let root = try temporaryRoot()
        let target = root.appending(path: "HEAD")
        defer {
            _ = chmod(target.path, 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("ref: refs/heads/main\n".utf8).write(to: target)
        try #require(chmod(target.path, 0o000) == 0)
        var swapped = false

        // Act
        let failure: GitWorktreeForkError?
        do {
            try WorktreeForkMetadataPreservingRewrite.rewrite(target, metadataFrom: .editedFile, reportPath: "HEAD") {
                () throws(GitWorktreeForkError) in
                swapped = true
            }
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(failure == .entryFailed(relativePath: "HEAD", reason: .unreadableEntry, errorNumber: EACCES))
        #expect(!swapped)
        #expect(try #require(GitWorktreeForkFileProbe.info(target)).st_mode & 0o7777 == 0o000)
    }

    @Test("an equivalence read under an ambient materializing policy denies materialization and restores it")
    func equivalenceReadRestoresAmbientMaterializingPolicy() async throws {
        // Arrange
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first", "second"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
            try Data("same payload\n".utf8).write(to: root.appending(path: "\(name)/extra.conf"))
        }
        let first = WorktreeForkFileEquivalence.ContainedFile(
            root: root.appending(path: "first"), remainder: "extra.conf")
        let second = WorktreeForkFileEquivalence.ContainedFile(
            root: root.appending(path: "second"), remainder: "extra.conf")
        let (observations, continuation) = AsyncStream.makeStream(of: EquivalencePolicyObservation.self)

        // Act: an embedding thread that materializes dataless files by default compares two files.
        let worker = Thread {
            let ambient = setiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
            let before = WorktreeForkDatalessPolicy.currentThreadPolicy()
            let equivalent = try? WorktreeForkFileEquivalence.isEquivalent(first, second, reportPath: "extra.conf")
            continuation.yield(
                EquivalencePolicyObservation(
                    ambientEstablished: ambient == 0, before: before, equivalent: equivalent,
                    after: WorktreeForkDatalessPolicy.currentThreadPolicy()))
            continuation.finish()
        }
        worker.start()
        var iterator = observations.makeAsyncIterator()
        let observation = try #require(await iterator.next())

        // Assert
        #expect(observation.ambientEstablished)
        #expect(observation.before == IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        #expect(observation.equivalent == true)
        #expect(observation.after == IOPOL_MATERIALIZE_DATALESS_FILES_ON)
    }

    @Test("a configuration read under an ambient materializing policy keeps every entry and restores the policy")
    func configurationReadRestoresAmbientMaterializingPolicy() async throws {
        // Arrange
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try LibGit2Runtime.shared.ensureInitialized()
        let configuration = root.appending(path: "extra.conf")
        try Data("[agentstudio]\n\tprobe = one\n\tprobe = two\n\tprobe = one\n".utf8).write(to: configuration)
        let (observations, continuation) = AsyncStream.makeStream(of: ConfigurationReadObservation.self)

        // Act: an embedding thread that materializes dataless files by default reads the file through libgit2.
        let worker = Thread {
            let ambient = setiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
            let before = WorktreeForkDatalessPolicy.currentThreadPolicy()
            let values = try? WorktreeForkConfigurationFile.orderedEntries(in: configuration, reportPath: "extra.conf")
                .map(\.value)
            continuation.yield(
                ConfigurationReadObservation(
                    ambientEstablished: ambient == 0, before: before, values: values,
                    after: WorktreeForkDatalessPolicy.currentThreadPolicy()))
            continuation.finish()
        }
        worker.start()
        var iterator = observations.makeAsyncIterator()
        let observation = try #require(await iterator.next())

        // Assert
        #expect(observation.ambientEstablished)
        #expect(observation.before == IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        #expect(observation.values == ["one", "two", "one"])
        #expect(observation.after == IOPOL_MATERIALIZE_DATALESS_FILES_ON)
    }

    /// A canonical temporary directory: the clone opens its roots with no symlink anywhere in the path.
    private func temporaryRoot() throws -> URL {
        let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved))
            .appending(path: "agentstudio-git-counterpart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

enum CounterpartSymlinkSide: String, CaseIterable, Sendable {
    case source
    case destination
}

/// Which destination ancestor the seam swaps for a symlink after its descriptor was opened.
enum AncestorSwap: String, CaseIterable, Sendable {
    /// The directory holding an existing target that is replaced.
    case replacedFileParent
    /// The directory a missing directory is created in.
    case missingDirectoryParent
}

private struct EquivalencePolicyObservation: Sendable {
    let ambientEstablished: Bool
    let before: Int32
    let equivalent: Bool?
    let after: Int32
}

private struct ConfigurationReadObservation: Sendable {
    let ambientEstablished: Bool
    let before: Int32
    let values: [String]?
    let after: Int32
}

/// Why a destination target cannot be opened for reading when its replacement starts.
enum UnreadableTarget: String, CaseIterable, Sendable {
    /// The cloned target itself is mode 000.
    case modeZero
    /// After its one-link stat, the target name is replaced by a hard link to a mode-000 source file.
    case hardLinkToSourceSwappedAfterStat
}
