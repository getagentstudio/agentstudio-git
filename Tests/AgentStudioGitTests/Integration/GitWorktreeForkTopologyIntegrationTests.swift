import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree fork topology integration", .serialized)
struct GitWorktreeForkTopologyIntegrationTests {
    @Test("initialized, recursive, and uninitialized submodules keep their state under destination administration")
    func submodulesKeepStateUnderDestinationAdministration() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-submodules")
        defer { fixture.remove() }
        let root = fixture.repository.root
        let inner = try makeRepository(at: root.appending(path: "inner"), file: "inner.txt", fixture: fixture)
        let library = try makeRepository(at: root.appending(path: "library"), file: "library.txt", fixture: fixture)
        try fixture.git.run(["submodule", "add", "-q", inner.path, "nested/inner"], currentDirectory: library)
        try fixture.git.run(["commit", "-qm", "inner"], currentDirectory: library)
        let other = try makeRepository(at: root.appending(path: "other"), file: "other.txt", fixture: fixture)
        try fixture.git.run("submodule", "add", "-q", library.path, "deps/library")
        try fixture.git.run("submodule", "add", "-q", other.path, "deps/other")
        try fixture.git.run("commit", "-qm", "submodules")
        try fixture.git.run("submodule", "deinit", "-q", "deps/other")
        try fixture.git.run("submodule", "update", "-q", "--init", "--recursive", "deps/library")
        let sourceLibrary = fixture.source.appending(path: "deps/library")
        try fixture.write("library.txt", "edited in source submodule\n", in: sourceLibrary)
        try fixture.write("staged.txt", "staged in source submodule\n", in: sourceLibrary)
        try fixture.git.run(["add", "staged.txt"], currentDirectory: sourceLibrary)
        try fixture.write("ignored-by-nothing.txt", "untracked\n", in: sourceLibrary)
        let sourceSuperStatus = try fixture.statusLines(at: fixture.source)
        let sourceLibraryStatus = try fixture.statusLines(at: sourceLibrary)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAdministration = try canonical(fixture.linkedWorktreeAdministration())
        let destinationLibrary = destination.appending(path: "deps/library")
        #expect(
            try fixture.statusLines(at: destinationLibrary) == [
                " M library.txt", "?? ignored-by-nothing.txt", "?? staged.txt",
            ])
        #expect(try fixture.statusLines(at: destination) == sourceSuperStatus)
        #expect(try fixture.statusLines(at: sourceLibrary) == sourceLibraryStatus)
        #expect(
            try absoluteGitDirectory(destinationLibrary, fixture)
                == destinationAdministration.appending(path: "modules/deps/library").path)
        #expect(
            try absoluteGitDirectory(destinationLibrary.appending(path: "nested/inner"), fixture)
                == destinationAdministration.appending(path: "modules/deps/library/modules/nested/inner").path)
        #expect(try fixture.statusLines(at: destinationLibrary.appending(path: "nested/inner")).isEmpty)
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "deps/other/.git")))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.appending(path: "deps/other").path).isEmpty)
        #expect(
            try fixture.git.run(["config", "--get", "core.worktree"], currentDirectory: destinationLibrary)
                .contains("fork/deps/library"))
        guard case .copyOnWrite(let materializationReport) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(materializationReport.preservedGitRepositoryCount == 2)
    }

    @Test("nested repositories, linked worktrees, and alternates are re-homed without source administration")
    func nestedRepositoriesAreRehomedWithoutSourceAdministration() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-nested")
        defer { fixture.remove() }
        let root = fixture.repository.root
        try fixture.write(".gitignore", "vendor/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore vendor")
        let tool = fixture.source.appending(path: "vendor/tool")
        _ = try makeRepository(at: tool, file: "a.txt", fixture: fixture)
        try fixture.write("a.txt", "dirty nested edit\n", in: tool)
        #expect(link(tool.appending(path: "a.txt").path, tool.appending(path: "b.txt").path) == 0)
        try fixture.write("MERGE_HEAD", "0000000000000000000000000000000000000000\n", in: tool.appending(path: ".git"))
        try fixture.write("index.lock", "", in: tool.appending(path: ".git"))
        try fixture.write("rebase-merge/head-name", "refs/heads/main\n", in: tool.appending(path: ".git"))
        let outside = try makeRepository(at: root.appending(path: "outside"), file: "outside.txt", fixture: fixture)
        try fixture.git.run(
            ["worktree", "add", "-q", "-b", "nested-linked", fixture.source.appending(path: "vendor/linked").path],
            currentDirectory: outside)
        try fixture.git.run([
            "clone", "-q", "--shared", outside.path, fixture.source.appending(path: "vendor/alt").path,
        ])
        let toolStatus = try fixture.statusLines(at: tool)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationOwnedPrefixes = [
            try canonical(destination).path + "/", try canonical(fixture.linkedWorktreeAdministration()).path + "/",
        ]
        let destinationTool = destination.appending(path: "vendor/tool")
        #expect(try fixture.statusLines(at: destinationTool) == toolStatus)
        for residue in ["MERGE_HEAD", "index.lock", "rebase-merge"] {
            #expect(!GitWorktreeForkFileProbe.exists(destinationTool.appending(path: ".git/\(residue)")), "\(residue)")
        }
        let linkedA = try #require(GitWorktreeForkFileProbe.info(destinationTool.appending(path: "a.txt")))
        let linkedB = try #require(GitWorktreeForkFileProbe.info(destinationTool.appending(path: "b.txt")))
        #expect(linkedA.st_ino == linkedB.st_ino)
        for nested in ["vendor/tool", "vendor/linked", "vendor/alt"] {
            let nestedDestination = destination.appending(path: nested)
            #expect(
                try fixture.blobID("HEAD", at: nestedDestination)
                    == fixture.blobID("HEAD", at: fixture.source.appending(path: nested)))
            let administrativePaths =
                [
                    try absoluteGitDirectory(nestedDestination, fixture),
                    try fixture.git.run(
                        ["rev-parse", "--path-format=absolute", "--git-common-dir"], currentDirectory: nestedDestination
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                ] + alternates(of: nestedDestination)
            for path in administrativePaths {
                let resolved = try canonical(URL(fileURLWithPath: path)).path + "/"
                #expect(destinationOwnedPrefixes.contains { resolved.hasPrefix($0) }, "\(nested) → \(path)")
            }
        }
        #expect(
            try fixture.git.succeeds(
                "cat-file", "-e", "HEAD:outside.txt", currentDirectory: destination.appending(path: "vendor/alt")))
        #expect(!alternates(of: destination.appending(path: "vendor/alt")).isEmpty)
        guard case .copyOnWrite(let materializationReport) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(materializationReport.preservedGitRepositoryCount == 3)
    }

    @Test("SwiftPM-style read-only nested repositories are re-homed and keep their file modes")
    func readOnlyNestedRepositoriesAreRehomed() async throws {
        // Arrange: SwiftPM makes every file in a checkout read-only, including .git/HEAD; a --shared
        // clone also carries a read-only objects/info/alternates. The fork rewrites both while re-homing.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-readonly-nested")
        defer {
            restoreOwnerWrite(under: fixture.repository.root)
            fixture.remove()
        }
        let root = fixture.repository.root
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        let checkout = fixture.source.appending(path: ".build/checkouts/swift-syntax")
        _ = try makeRepository(at: checkout, file: "Package.swift", fixture: fixture)
        let upstream = try makeRepository(at: root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
        let sharedCheckout = fixture.source.appending(path: ".build/checkouts/shared")
        try fixture.git.run(["clone", "-q", "--shared", upstream.path, sharedCheckout.path])
        for nested in [checkout, sharedCheckout] {
            try makeFilesReadOnly(under: nested.appending(path: ".git"))
        }
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        for nested in [".build/checkouts/swift-syntax", ".build/checkouts/shared"] {
            let nestedDestination = destination.appending(path: nested)
            #expect(
                try fixture.blobID("HEAD", at: nestedDestination)
                    == fixture.blobID("HEAD", at: fixture.source.appending(path: nested)), "\(nested)")
            let head = try #require(GitWorktreeForkFileProbe.info(nestedDestination.appending(path: ".git/HEAD")))
            #expect(head.st_mode & 0o222 == 0, "\(nested) HEAD keeps its read-only mode")
        }
        #expect(
            try fixture.git.succeeds(
                "cat-file", "-e", "HEAD:up.txt",
                currentDirectory: destination.appending(path: ".build/checkouts/shared")))
        guard case .copyOnWrite(let materializationReport) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(materializationReport.preservedGitRepositoryCount == 2)
    }

    @Test(
        "cone, non-cone, and sparse-index sources keep sparse behavior without mass deletions",
        arguments: [SparseScenario.cone, .nonCone, .sparseIndex]
    )
    func sparseSourcesKeepSparseBehavior(scenario: SparseScenario) async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-sparse")
        defer { fixture.remove() }
        for path in ["kept/one.txt", "kept/deep/two.txt", "dropped/three.txt", "other/four.txt"] {
            try fixture.write(path, "\(path)\n")
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "tree")
        switch scenario {
        case .cone:
            try fixture.git.run("sparse-checkout", "set", "--cone", "kept")
        case .nonCone:
            try fixture.git.run("sparse-checkout", "set", "--no-cone", "/*", "!/dropped/", "!/other/")
        case .sparseIndex:
            try fixture.git.run("sparse-checkout", "init", "--cone", "--sparse-index")
            try fixture.git.run("sparse-checkout", "set", "kept")
            // The source index really is sparse: libgit2 1.9 cannot open it, so patterns must be the authority.
            #expect(try fixture.git.run("ls-files", "--sparse").contains("dropped/\n"))
        }
        try fixture.write("kept/one.txt", "dirty inside the cone\n")
        let sourceList = try fixture.git.run("sparse-checkout", "list")
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        #expect(try fixture.statusLines(at: destination) == [" M kept/one.txt"])
        #expect(try fixture.git.run(["sparse-checkout", "list"], currentDirectory: destination) == sourceList)
        let skipWorktree = try fixture.git.run(
            ["ls-files", "-t", "--", "dropped", "other"], currentDirectory: destination)
        #expect(skipWorktree.split(separator: "\n").allSatisfy { $0.hasPrefix("S ") })
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "dropped/three.txt")))
        #expect(
            try fixture.git.run(["ls-files", "-t", "--", "kept/one.txt"], currentDirectory: destination).hasPrefix("H ")
        )
    }

    @Test("a failure after re-homing removes submodule administration with the rest of the fork")
    func failureAfterRehomingRemovesSubmoduleAdministration() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-topology-rollback")
        defer { fixture.remove() }
        let library = try makeRepository(
            at: fixture.repository.root.appending(path: "library"), file: "library.txt", fixture: fixture)
        try fixture.git.run("submodule", "add", "-q", library.path, "deps/library")
        try fixture.git.run("commit", "-qm", "submodule")
        let injected = GitWorktreeForkError.entryFailed(
            relativePath: "injected", reason: .entryCreationFailed, errorNumber: nil)
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            if reached == .afterIndexesBuilt {
                throw injected
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(failure == injected)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
        #expect(try fixture.statusLines(at: fixture.source.appending(path: "deps/library")).isEmpty)
    }

    @Test("administrative symlinks are re-homed: internal ones stay internal, external object stores are mirrored")
    func administrativeSymlinksAreRehomed() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-admin-symlinks")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "vendor/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore vendor")
        let tool = fixture.source.appending(path: "vendor/tool")
        _ = try makeRepository(at: tool, file: "tool.txt", fixture: fixture)
        let externalObjects = fixture.repository.root.appending(path: "external-objects")
        try FileManager.default.moveItem(at: tool.appending(path: ".git/objects"), to: externalObjects)
        try FileManager.default.createSymbolicLink(
            at: tool.appending(path: ".git/objects"), withDestinationURL: externalObjects)
        try FileManager.default.createSymbolicLink(
            atPath: tool.appending(path: ".git/description-link").path, withDestinationPath: "description")
        let sourceHead = try fixture.blobID("HEAD", at: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        let destinationOwned = [
            try canonical(destination).path + "/", try canonical(fixture.linkedWorktreeAdministration()).path + "/",
        ]
        for link in [".git/objects", ".git/description-link"] {
            let resolved = try canonical(destinationTool.appending(path: link)).path + "/"
            #expect(destinationOwned.contains { resolved.hasPrefix($0) }, "\(link) → \(resolved)")
        }
        #expect(
            try canonical(destinationTool.appending(path: ".git/description-link")).path
                == canonical(destinationTool.appending(path: ".git/description")).path)
        #expect(try fixture.blobID("HEAD", at: destinationTool) == sourceHead)
        #expect(try fixture.git.succeeds("cat-file", "-e", "HEAD:tool.txt", currentDirectory: destinationTool))
        #expect(try fixture.statusLines(at: destinationTool).isEmpty)
    }

    @Test("a mirrored alternate store keeps its internal relative symlinks inside the destination mirror")
    func mirroredAlternateStoreKeepsInternalSymlinks() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-store-symlink")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "vendor/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore vendor")
        let outside = try makeRepository(
            at: fixture.repository.root.appending(path: "outside"), file: "outside.txt", fixture: fixture)
        try fixture.git.run([
            "clone", "-q", "--shared", outside.path, fixture.source.appending(path: "vendor/alt").path,
        ])
        try FileManager.default.createSymbolicLink(
            atPath: outside.appending(path: ".git/objects/info/packs-link").path, withDestinationPath: "../pack")
        try FileManager.default.createSymbolicLink(
            atPath: outside.appending(path: ".git/objects/info/store-root").path, withDestinationPath: "..")
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAlt = destination.appending(path: "vendor/alt")
        #expect(try fixture.git.succeeds("cat-file", "-e", "HEAD:outside.txt", currentDirectory: destinationAlt))
        let mirrorRoot = try canonical(fixture.linkedWorktreeAdministration()).appending(
            path: "agentstudio-object-mirrors")
        let mirroredLink = try #require(
            try FileManager.default.contentsOfDirectory(atPath: mirrorRoot.path).lazy
                .map { mirrorRoot.appending(path: "\($0)/info/packs-link") }
                .first { GitWorktreeForkFileProbe.exists($0) })
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mirroredLink.path) == "../pack")
        let mirror = mirroredLink.deletingLastPathComponent().deletingLastPathComponent()
        #expect(try canonical(mirroredLink).path == canonical(mirror.appending(path: "pack")).path)
        let storeRootLink = mirror.appending(path: "info/store-root")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: storeRootLink.path) == "..")
        #expect(try canonical(storeRootLink).path == canonical(mirror).path)
    }

    @Test("an untranslatable sparse pattern the matcher must decide with rejects the fork before mutation")
    func untranslatableSparsePatternRejectsBeforeMutation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-sparse-untranslatable")
        defer { fixture.remove() }
        for path in ["kept/one.txt", "gone.txt"] {
            try fixture.write(path, "\(path)\n")
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "tree")
        try fixture.git.run("sparse-checkout", "set", "--no-cone", "/*", "/[[:bogus:]]x")
        try fixture.git.run("rm", "-q", "--cached", "gone.txt")
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
                    relativePath: "info/sparse-checkout", reason: .unresolvableGitAdministration, errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("a worktree-scoped core.worktree is never carried into destination configuration")
    func worktreeScopedCoreWorktreeIsNotCarriedIntoDestination() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-worktree")
        defer { fixture.remove() }
        for path in ["kept/one.txt", "dropped/two.txt"] {
            try fixture.write(path, "\(path)\n")
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "tree")
        try fixture.git.run("config", "extensions.worktreeConfig", "true")
        let sourceRoot = try canonical(fixture.source).path
        try fixture.git.run("config", "--worktree", "core.worktree", sourceRoot)
        try fixture.git.run("sparse-checkout", "set", "--cone", "kept")
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let topLevel = try fixture.git.run(["rev-parse", "--show-toplevel"], currentDirectory: destination)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try canonical(URL(fileURLWithPath: topLevel)).path == canonical(destination).path)
        #expect(
            !(try fixture.git.succeeds("config", "--worktree", "--get", "core.worktree", currentDirectory: destination))
        )
        #expect(try fixture.git.run(["sparse-checkout", "list"], currentDirectory: destination) == "kept\n")
        #expect(try fixture.statusLines(at: destination).isEmpty)
    }

    @Test("a traversing submodule name is rejected before mutation and never deletes what it points at")
    func traversingSubmoduleNameIsRejectedBeforeMutation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-submodule-name")
        defer { fixture.remove() }
        let library = try makeRepository(
            at: fixture.repository.root.appending(path: "library"), file: "library.txt", fixture: fixture)
        try fixture.git.run("submodule", "add", "-q", library.path, "deps/library")
        try fixture.git.run(
            "config", "-f", ".gitmodules", "--rename-section",
            "submodule.deps/library", "submodule.../../../review-victim")
        try fixture.git.run("add", ".gitmodules")
        try fixture.git.run("commit", "-qm", "traversing submodule name")
        let victim = fixture.source.appending(path: ".git/review-victim/owner.txt")
        try fixture.write("owner.txt", "not the fork's\n", in: victim.deletingLastPathComponent())
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
                    relativePath: "deps/library/.git", reason: .unresolvableGitAdministration, errorNumber: nil))
        #expect(try String(contentsOf: victim, encoding: .utf8) == "not the fork's\n")
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    private func makeRepository(at path: URL, file: String, fixture: GitWorktreeForkFixture) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write(file, "\(file)\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
        return path
    }

    private func absoluteGitDirectory(_ worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> String {
        let path = try fixture.git.run(["rev-parse", "--absolute-git-dir"], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try canonical(URL(fileURLWithPath: path)).path
    }

    private func alternates(of worktree: URL) -> [String] {
        let commonDirectory = worktree.appending(path: ".git")
        guard
            let text = try? String(
                contentsOf: commonDirectory.appending(path: "objects/info/alternates"), encoding: .utf8)
        else {
            return []
        }
        return text.split(separator: "\n").map(String.init)
    }

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Clears every write bit on regular files beneath `root`, the way SwiftPM locks its checkouts.
    private func makeFilesReadOnly(under root: URL) throws {
        try setRegularFileModes(under: root) { $0 & ~0o222 }
    }

    /// Restores owner write on regular files so fixture cleanup can always delete them.
    private func restoreOwnerWrite(under root: URL) {
        try? setRegularFileModes(under: root) { $0 | 0o200 }
    }

    private func setRegularFileModes(under root: URL, _ transform: (Int) -> Int) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for case let url as URL in enumerator {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            else {
                continue
            }
            try FileManager.default.setAttributes([.posixPermissions: transform(mode)], ofItemAtPath: url.path)
        }
    }
}

enum SparseScenario: String, CaseIterable, Sendable {
    case cone
    case nonCone
    case sparseIndex
}
