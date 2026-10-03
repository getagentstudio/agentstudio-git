import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// Re-homing rewrites cloned administrative files (a nested `.git/HEAD`, sparse state, configuration edited
/// through libgit2) on a fresh inode. The specification makes loss of ACL access semantics, extended
/// attributes, or file flags a failure, so each rewrite must carry the metadata of the file it stands for.
@Suite("Git worktree fork re-homed file metadata integration", .serialized)
struct GitWorktreeForkRehomedMetadataIntegrationTests {
    @Test(
        "a rewritten administrative file keeps the metadata of the file it stands for",
        arguments: RehomedAdministrativeFile.allCases, RehomedFileMetadata.allCases)
    func rewrittenAdministrativeFileKeepsMetadata(
        file: RehomedAdministrativeFile,
        metadata: RehomedFileMetadata
    ) async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-file-metadata")
        let sourceFile = file.sourceFile(in: fixture)
        var protectedDestinationFile: URL?
        defer {
            clearProtection(sourceFile)
            protectedDestinationFile.map(clearProtection)
            fixture.remove()
        }
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        switch file {
        case .nestedHead, .nestedConfiguration:
            try makeRepository(
                at: fixture.source.appending(path: file.worktreeRelativePath), file: "Package.swift",
                fixture: fixture)
        case .submoduleGitfile:
            let library = try makeRepository(
                at: fixture.repository.root.appending(path: "library"), file: "library.txt", fixture: fixture)
            try fixture.git.run("submodule", "add", "-q", library.path, file.worktreeRelativePath)
            try fixture.git.run("commit", "-qm", "submodule")
        case .flattenedLinkedHead:
            // The worktree's private HEAD carries the protection; the common repository's HEAD stays 0644.
            let upstream = try makeRepository(
                at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
            try fixture.git.run(
                [
                    "worktree", "add", "-q", "-b", "linked",
                    fixture.source.appending(path: file.worktreeRelativePath).path,
                ],
                currentDirectory: upstream)
        case .nestedAlternates, .mirrorAlternates:
            // A --shared clone borrows its objects; the mirror case borrows from a store that borrows again.
            var lender = try makeRepository(
                at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
            if file == .mirrorAlternates {
                let middle = fixture.repository.root.appending(path: "middle")
                try fixture.git.run(["clone", "-q", "--shared", lender.path, middle.path])
                lender = middle
            }
            try fixture.git.run([
                "clone", "-q", "--shared", lender.path,
                fixture.source.appending(path: file.worktreeRelativePath).path,
            ])
        }
        try metadata.apply(to: sourceFile)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        let destinationFile = try file.destinationFile(in: fixture)
        protectedDestinationFile = destinationFile

        // Assert
        let sourceWorktree = fixture.source.appending(path: file.worktreeRelativePath)
        let destinationWorktree = fixture.destination().appending(path: file.worktreeRelativePath)
        #expect(try fixture.blobID("HEAD", at: destinationWorktree) == fixture.blobID("HEAD", at: sourceWorktree))
        #expect(try fixture.statusLines(at: destinationWorktree).isEmpty)
        if file == .nestedAlternates || file == .mirrorAlternates {
            #expect(
                try fixture.git.succeeds("cat-file", "-e", "HEAD:up.txt", currentDirectory: destinationWorktree),
                "objects still resolve through the rewritten alternates")
        }
        #expect(metadata.isCarried(by: destinationFile), "\(metadata) on the rewritten \(file)")
        let sourceInfo = try #require(GitWorktreeForkFileProbe.info(sourceFile))
        let destinationInfo = try #require(GitWorktreeForkFileProbe.info(destinationFile))
        #expect(destinationInfo.st_mode & 0o7777 == sourceInfo.st_mode & 0o7777)
        #expect(
            destinationInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask
                == sourceInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask)
        #expect(probeAttribute(destinationFile) == probeAttribute(sourceFile))
        #expect(accessControlText(destinationFile) == accessControlText(sourceFile))
    }

    @Test(
        "rewritten sparse configuration keeps its source file's mode and extended attribute",
        arguments: SparseAdministrationLayout.allCases)
    func rewrittenSparseConfigurationKeepsMetadata(layout: SparseAdministrationLayout) async throws {
        // Arrange: config.worktree is rewritten by re-homing and then edited through libgit2's lock-file
        // rename; a flattened linked worktree's copy is removed and rebuilt from its private source file, and
        // the fork root's copy is new fork administration built from the source worktree's own files.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-sparse-metadata")
        defer { fixture.remove() }
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        let nestedPath = ".build/checkouts/dependency"
        let nested = fixture.source.appending(path: nestedPath)
        let sparseWorktree: URL
        let sourceAdministration: URL
        let destinationWorktree: URL
        let destinationAdministration: URL
        switch layout {
        case .embeddedRepository:
            try makeSparseTree(at: nested, fixture: fixture)
            (sparseWorktree, sourceAdministration) = (nested, nested.appending(path: ".git"))
            destinationWorktree = fixture.destination().appending(path: nestedPath)
            destinationAdministration = destinationWorktree.appending(path: ".git")
        case .linkedWorktree:
            let upstream = fixture.repository.root.appending(path: "upstream")
            try makeSparseTree(at: upstream, fixture: fixture)
            try fixture.git.run(["worktree", "add", "-q", nested.path], currentDirectory: upstream)
            (sparseWorktree, sourceAdministration) = (nested, upstream.appending(path: ".git/worktrees/dependency"))
            destinationWorktree = fixture.destination().appending(path: nestedPath)
            destinationAdministration = destinationWorktree.appending(path: ".git")
        case .forkRoot:
            try fixture.write("kept/one.txt", "kept\n")
            try fixture.write("dropped/two.txt", "dropped\n")
            try fixture.git.run("add", ".")
            try fixture.git.run("commit", "-qm", "sparse tree")
            (sparseWorktree, sourceAdministration) = (fixture.source, fixture.source.appending(path: ".git"))
            destinationWorktree = fixture.destination()
            destinationAdministration = fixture.linkedWorktreeAdministration()
        }
        try fixture.git.run(["sparse-checkout", "set", "--cone", "kept"], currentDirectory: sparseWorktree)
        let administrativeFiles = ["config.worktree", "info/sparse-checkout"]
        for file in administrativeFiles {
            let url = sourceAdministration.appending(path: file)
            try #require(setxattr(url.path, probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
            try #require(chmod(url.path, 0o444) == 0)
        }

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        #expect(try fixture.git.run(["sparse-checkout", "list"], currentDirectory: destinationWorktree) == "kept\n")
        for file in administrativeFiles {
            let destination = destinationAdministration.appending(path: file)
            let destinationInfo = try #require(GitWorktreeForkFileProbe.info(destination))
            #expect(destinationInfo.st_mode & 0o7777 == 0o444, "\(file) keeps its read-only mode")
            #expect(probeAttribute(destination) == Array("x".utf8), "\(file) keeps its extended attribute")
        }
    }

    @Test(
        "a rewrite input that shares its inode with another path fails typed before any change",
        arguments: HardLinkedRewriteInput.allCases)
    func hardLinkedRewriteInputFailsBeforeAnyChange(input: HardLinkedRewriteInput) async throws {
        // Arrange: a copied bare store's file needs relocation and shares one user-immutable inode with a second
        // in-tree path. Rewriting one name would split the hard-link group, and the other path may need
        // different text, so the fork refuses instead.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-linked-rewrite")
        let repositories = fixture.source.appending(path: ".build/repositories")
        let sourceFile = repositories.appending(path: input.storeRelativePath)
        let sourceAlias = fixture.source.appending(path: ".build/alias")
        defer {
            _ = lchflags(sourceFile.path, 0)
            fixture.remove()
        }
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
        let base = repositories.appending(path: "base.git")
        try fixture.git.run(["clone", "-q", "--bare", upstream.path, base.path])
        try fixture.git.run([
            "clone", "-q", "--bare", "--shared", base.path, repositories.appending(path: "shared.git").path,
        ])
        if input == .configuration {
            try fixture.git.run([
                "config", "--file", sourceFile.path, "core.hooksPath",
                fixture.source.appending(path: ".build/hooks").path,
            ])
        }
        try #require(link(sourceFile.path, sourceAlias.path) == 0)
        try #require(lchflags(sourceFile.path, UInt32(UF_IMMUTABLE)) == 0)
        let sourceBytes = try Data(contentsOf: sourceFile)
        let sourceInfoBefore = try #require(GitWorktreeForkFileProbe.info(sourceFile))
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(
            failure
                == .entryFailed(
                    relativePath: ".build/repositories/\(input.storeRelativePath)", reason: .metadataNotReproducible,
                    errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == branchesBefore)
        #expect(try Data(contentsOf: sourceFile) == sourceBytes)
        let sourceInfo = try #require(GitWorktreeForkFileProbe.info(sourceFile))
        let aliasInfo = try #require(GitWorktreeForkFileProbe.info(sourceAlias))
        #expect(sourceInfo.st_ino == sourceInfoBefore.st_ino && aliasInfo.st_ino == sourceInfo.st_ino)
        #expect(sourceInfo.st_nlink == 2)
        #expect(aliasInfo.st_flags & UInt32(UF_IMMUTABLE) != 0, "the shared inode keeps its protection")
    }

    private func makeSparseTree(at path: URL, fixture: GitWorktreeForkFixture) throws {
        try makeRepository(at: path, file: "kept/one.txt", fixture: fixture)
        try fixture.write("dropped/two.txt", "dropped\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "sparse tree"], currentDirectory: path)
    }

    @discardableResult
    private func makeRepository(at path: URL, file: String, fixture: GitWorktreeForkFixture) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write(file, "\(file)\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
        return path
    }

    /// Lifts flags, the extended ACL, and the read-only mode so fixture cleanup can delete the file.
    private func clearProtection(_ url: URL) {
        _ = lchflags(url.path, 0)
        if let empty = acl_init(0) {
            _ = acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        _ = chmod(url.path, 0o644)
    }
}

private let probeAttributeName = "com.example.forklab"

/// An administrative file re-homing rewrites, by its source-relative path.
enum RehomedAdministrativeFile: String, CaseIterable, Sendable, CustomStringConvertible {
    /// Rewritten on a fresh inode by re-homing.
    case nestedHead
    /// Edited through libgit2's lock-file rename (`core.bare`, `core.worktree`).
    case nestedConfiguration
    /// Never copied; written from scratch with the source gitfile as its metadata template.
    case submoduleGitfile
    /// A gitfile-reached linked worktree's private `HEAD`. Flattening clones the common repository, whose
    /// `HEAD` is a different source file, so the destination copy is not the template.
    case flattenedLinkedHead
    /// A `--shared` nested repository's `objects/info/alternates`: never copied, rewritten to name a mirror.
    case nestedAlternates
    /// A mirrored store's own `info/alternates`: cloned with the store, then rewritten to name a mirror.
    case mirrorAlternates

    var description: String {
        rawValue
    }

    var worktreeRelativePath: String {
        switch self {
        case .nestedHead, .nestedConfiguration:
            return ".build/checkouts/dependency"
        case .submoduleGitfile:
            return "deps/library"
        case .flattenedLinkedHead:
            return ".build/checkouts/linked"
        case .nestedAlternates, .mirrorAlternates:
            return ".build/checkouts/shared"
        }
    }

    func sourceFile(in fixture: GitWorktreeForkFixture) -> URL {
        switch self {
        case .mirrorAlternates:
            return fixture.repository.root.appending(path: "middle/.git/objects/info/alternates")
        case .flattenedLinkedHead:
            return fixture.repository.root.appending(path: "upstream/.git/worktrees/linked/HEAD")
        case .nestedHead, .nestedConfiguration, .submoduleGitfile, .nestedAlternates:
            return fixture.source.appending(path: worktreeRelativePath).appending(path: administrativePath)
        }
    }

    /// The destination file standing for `sourceFile(in:)`. A mirror's index is the planner's choice, so
    /// the mirror case finds the only mirror that borrows from another.
    func destinationFile(in fixture: GitWorktreeForkFixture) throws -> URL {
        switch self {
        case .mirrorAlternates:
            let mirrors = fixture.linkedWorktreeAdministration().appending(path: "agentstudio-object-mirrors")
            let borrowing = try FileManager.default.contentsOfDirectory(atPath: mirrors.path)
                .map { mirrors.appending(path: $0).appending(path: "info/alternates") }
                .filter(GitWorktreeForkFileProbe.exists)
            return try #require(borrowing.count == 1 ? borrowing.first : nil, "one borrowing mirror")
        case .nestedHead, .nestedConfiguration, .submoduleGitfile, .flattenedLinkedHead, .nestedAlternates:
            return fixture.destination().appending(path: worktreeRelativePath).appending(path: administrativePath)
        }
    }

    private var administrativePath: String {
        switch self {
        case .nestedHead, .flattenedLinkedHead:
            return ".git/HEAD"
        case .nestedConfiguration:
            return ".git/config"
        case .submoduleGitfile:
            return ".git"
        case .nestedAlternates, .mirrorAlternates:
            return ".git/objects/info/alternates"
        }
    }
}

/// A copied bare store file re-homing rewrites, by its path beneath `.build/repositories`.
enum HardLinkedRewriteInput: String, CaseIterable, Sendable, CustomStringConvertible {
    /// `config` naming an absolute in-tree path; edited through libgit2's lock-file rename.
    case configuration
    /// `objects/info/alternates` of a `--shared` clone of an in-tree store; rewritten by re-homing.
    case alternates

    var description: String {
        rawValue
    }

    var storeRelativePath: String {
        switch self {
        case .configuration:
            return "shared.git/config"
        case .alternates:
            return "shared.git/objects/info/alternates"
        }
    }
}

/// Where a sparse repository's administration lives in the source.
enum SparseAdministrationLayout: String, CaseIterable, Sendable, CustomStringConvertible {
    /// An embedded `.git` directory; the destination copy is cloned, then rewritten in place.
    case embeddedRepository
    /// A gitfile-reached linked worktree; its destination copy is flattened and rebuilt from the private
    /// source administration.
    case linkedWorktree
    /// The worktree being forked; the fork's own administration starts without these files.
    case forkRoot

    var description: String {
        rawValue
    }
}

/// One piece of metadata a cloned administrative file can carry into the fork.
enum RehomedFileMetadata: String, CaseIterable, Sendable, CustomStringConvertible {
    case extendedAttribute
    case userImmutableFlag
    case appendOnlyFlag
    case denyDeleteAccessControlEntry
    case denyWriteAccessControlEntry
    case everythingOnReadOnlyFile

    var description: String {
        rawValue
    }

    func apply(to url: URL) throws {
        if self == .extendedAttribute || self == .everythingOnReadOnlyFile {
            try #require(setxattr(url.path, probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
        }
        if let accessControlEntry {
            let accessControlList = try #require(acl_from_text(accessControlEntry))
            defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
            try #require(acl_set_link_np(url.path, ACL_TYPE_EXTENDED, accessControlList) == 0)
        }
        if self == .everythingOnReadOnlyFile {
            try #require(chmod(url.path, 0o444) == 0)
        }
        if let flag {
            try #require(lchflags(url.path, flag) == 0)
        }
    }

    func isCarried(by url: URL) -> Bool {
        guard let info = GitWorktreeForkFileProbe.info(url) else {
            return false
        }
        let attributeCarried = probeAttribute(url) == Array("x".utf8)
        let aclCarried = accessControlEntry.map { accessControlText(url) == $0 } ?? true
        let flagCarried = flag.map { info.st_flags & $0 == $0 } ?? true
        switch self {
        case .extendedAttribute:
            return attributeCarried
        case .userImmutableFlag, .appendOnlyFlag:
            return flagCarried
        case .denyDeleteAccessControlEntry, .denyWriteAccessControlEntry:
            return aclCarried
        case .everythingOnReadOnlyFile:
            return attributeCarried && aclCarried && flagCarried && info.st_mode & 0o7777 == 0o444
        }
    }

    private var flag: UInt32? {
        switch self {
        case .userImmutableFlag, .everythingOnReadOnlyFile:
            return UInt32(UF_IMMUTABLE)
        case .appendOnlyFlag:
            return UInt32(UF_APPEND)
        case .extendedAttribute, .denyDeleteAccessControlEntry, .denyWriteAccessControlEntry:
            return nil
        }
    }

    /// The entry in `acl_to_text` form, which is also what `accessControlText(_:)` reads back.
    private var accessControlEntry: String? {
        let everyone = "group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12"
        switch self {
        case .denyDeleteAccessControlEntry, .everythingOnReadOnlyFile:
            return "!#acl 1\n\(everyone):deny:delete\n"
        case .denyWriteAccessControlEntry:
            return "!#acl 1\n\(everyone):deny:write\n"
        case .extendedAttribute, .userImmutableFlag, .appendOnlyFlag:
            return nil
        }
    }
}

private func probeAttribute(_ url: URL) -> [UInt8]? {
    let size = getxattr(url.path, probeAttributeName, nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else {
        return nil
    }
    var value = [UInt8](repeating: 0, count: size)
    guard getxattr(url.path, probeAttributeName, &value, value.count, 0, XATTR_NOFOLLOW) == size else {
        return nil
    }
    return value
}

private func accessControlText(_ url: URL) -> String? {
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
