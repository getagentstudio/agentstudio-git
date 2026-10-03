import AgentStudioGit
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

/// Nested Git shapes found in real prepared worktrees: bare caches whose alternates point back into the
/// source tree, linked worktrees of the source repository itself, separate Git directories, nested sparse
/// checkouts, and submodules that were never absorbed.
@Suite("Git worktree fork nested repository integration", .serialized)
struct GitWorktreeForkNestedRepositoryIntegrationTests {
    @Test(
        "an in-tree bare repository's alternates into the source tree point at the destination copy",
        arguments: [AlternateLineForm.absolute, .relativeThroughParent]
    )
    func inTreeBareAlternatesPointAtDestinationCopy(form: AlternateLineForm) async throws {
        // Arrange: a `--shared` bare cache borrowing objects from another bare repository in the same tree.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-bare-in-tree")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
        let repositories = fixture.source.appending(path: ".build/repositories")
        let base = repositories.appending(path: "base.git")
        let shared = repositories.appending(path: "shared.git")
        try fixture.git.run(["clone", "-q", "--bare", upstream.path, base.path])
        try fixture.git.run(["clone", "-q", "--bare", "--shared", base.path, shared.path])
        let sourceAlternates = shared.appending(path: "objects/info/alternates")
        if form == .relativeThroughParent {
            let line = "../../../../../\(fixture.source.lastPathComponent)/.build/repositories/base.git/objects\n"
            try line.write(to: sourceAlternates, atomically: false, encoding: .utf8)
        }
        let sourceAlternatesBefore = try Data(contentsOf: sourceAlternates)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        let movedBase = repositories.appending(path: "base.git.moved")
        try FileManager.default.moveItem(at: base, to: movedBase)
        defer { try? FileManager.default.moveItem(at: movedBase, to: base) }

        // Assert
        let destinationShared = destination.appending(path: ".build/repositories/shared.git")
        #expect(try fixture.git.succeeds("cat-file", "-e", "HEAD:up.txt", currentDirectory: destinationShared))
        let destinationTargets = try alternateTargets(of: destinationShared)
        #expect(
            destinationTargets
                == [try canonical(destination.appending(path: ".build/repositories/base.git/objects")).path])
        #expect(try Data(contentsOf: sourceAlternates) == sourceAlternatesBefore)
    }

    @Test("tracked fixture Git directories whose relative pointers already resolve in the copy keep their bytes")
    func trackedFixtureRelativePointersKeepTheirBytes() async throws {
        // Arrange: libgit2-style fixtures commit Git directories under another name, with relative pointers.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-bare-fixture")
        defer { fixture.remove() }
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
        let fixtures = fixture.source.appending(path: "fixtures")
        let base = fixtures.appending(path: "base.gitted")
        let shared = fixtures.appending(path: "shared.gitted")
        try fixture.git.run(["clone", "-q", "--bare", upstream.path, base.path])
        try fixture.git.run(["clone", "-q", "--bare", "--shared", base.path, shared.path])
        // A committed fixture cannot record this machine's absolute paths, only relative ones.
        try fixture.git.run(
            ["config", "--file", "config", "remote.origin.url", "../base.gitted"], currentDirectory: shared)
        try fixture.write("objects/info/alternates", "../../base.gitted/objects\n", in: shared)
        try fixture.write("worktrees/linked/gitdir", "../../../linked/dotgit\n", in: shared)
        try fixture.write("linked/dotgit", "gitdir: stand-in\n", in: fixtures)
        try fixture.git.run("add", "-f", "fixtures")
        try fixture.git.run("commit", "-qm", "fixtures")
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        let movedBase = fixtures.appending(path: "base.gitted.moved")
        try FileManager.default.moveItem(at: base, to: movedBase)
        defer { try? FileManager.default.moveItem(at: movedBase, to: base) }

        // Assert
        let destinationShared = destination.appending(path: "fixtures/shared.gitted")
        #expect(try fixture.statusLines(at: destination).isEmpty)
        for pointer in ["objects/info/alternates", "worktrees/linked/gitdir"] {
            #expect(
                try Data(contentsOf: destinationShared.appending(path: pointer))
                    == Data(contentsOf: shared.appending(path: pointer)), "\(pointer)")
        }
        #expect(try fixture.git.succeeds("cat-file", "-e", "HEAD:up.txt", currentDirectory: destinationShared))
    }

    @Test(
        "a tracked fixture Git directory whose absolute pointer is re-aimed reports that file as modified",
        arguments: RewrittenFixturePointer.allCases
    )
    func trackedFixtureRewrittenPointerReportsModified(pointer: RewrittenFixturePointer) async throws {
        // Arrange: a committed fixture that recorded this machine's absolute source path, which the fork must
        // re-aim at the destination copy. The rewritten bytes differ from captured HEAD, so they are not clean.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-rewritten-fixture")
        defer { fixture.remove() }
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
        let fixtures = fixture.source.appending(path: "fixtures")
        let base = fixtures.appending(path: "base.gitted")
        let shared = fixtures.appending(path: "shared.gitted")
        try fixture.git.run(["clone", "-q", "--bare", upstream.path, base.path])
        try fixture.git.run(["clone", "-q", "--bare", "--shared", base.path, shared.path])
        let sourceBase = try canonical(base)
        let recordedLine: String
        switch pointer {
        case .configurationPath:
            try fixture.write("objects/info/alternates", "../../base.gitted/objects\n", in: shared)
            recordedLine = sourceBase.path
            try fixture.git.run(
                ["config", "--file", "config", "remote.origin.url", recordedLine], currentDirectory: shared)
        case .alternates:
            recordedLine = sourceBase.appending(path: "objects").path
            try fixture.write("objects/info/alternates", "\(recordedLine)\n", in: shared)
        }
        // Older than the index Git writes next, so every fixture entry is non-racy and eligible for adoption.
        try backdateRegularFiles(under: fixtures)
        try fixture.git.run("add", "-f", "fixtures")
        try fixture.git.run("commit", "-qm", "fixtures")
        let sourceBytes = try Data(contentsOf: shared.appending(path: pointer.relativePath))
        let rootEvidence = OSAllocatedUnfairLock<WorktreeForkIndexRefreshEvidence?>(initialState: nil)
        let observer = WorktreeForkIndexObserver { node, evidence in
            if node.isEmpty {
                rootEvidence.withLock { $0 = evidence }
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(indexObserver: observer))
        let destination = fixture.destination()

        // Act
        _ = try await client.forkWorktree(fixture.request())

        // Assert
        let trackedPath = "fixtures/shared.gitted/\(pointer.relativePath)"
        let adoptedPaths = try #require(rootEvidence.withLock { $0 }).adoptedPaths
        #expect(!adoptedPaths.contains(trackedPath), "rewritten bytes must be hashed, never adopted as clean")
        #expect(adoptedPaths.contains("fixtures/shared.gitted/HEAD"), "untouched fixture files stay adoptable")
        let status = try fixture.statusLines(at: destination)
        #expect(status.contains(" M \(trackedPath)"), "\(status)")
        let destinationBase = try canonical(destination.appending(path: "fixtures/base.gitted"))
        let wantedLine =
            pointer == .alternates ? destinationBase.appending(path: "objects").path : destinationBase.path
        let diff = try fixture.git.run(["diff", "--", trackedPath], currentDirectory: destination)
        #expect(diff.contains("-\(pointer.diffPrefix)\(recordedLine)\n"), "\(diff)")
        #expect(diff.contains("+\(pointer.diffPrefix)\(wantedLine)\n"), "\(diff)")
        #expect(try Data(contentsOf: shared.appending(path: pointer.relativePath)) == sourceBytes)
    }

    @Test("an in-tree bare repository's outside alternates, transitive ones included, become destination mirrors")
    func outsideBareAlternatesBecomeDestinationMirrors() async throws {
        // Arrange: shared.git (in the source) borrows from middle, which borrows from origin; both are outside.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-bare-outside")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let root = fixture.repository.root
        let origin = try makeRepository(at: root.appending(path: "origin"), file: "up.txt", fixture: fixture)
        let middle = root.appending(path: "middle")
        try fixture.git.run(["clone", "-q", "--shared", origin.path, middle.path])
        let shared = fixture.source.appending(path: ".build/repositories/shared.git")
        try fixture.git.run(["clone", "-q", "--bare", "--shared", middle.path, shared.path])
        let sourceAlternates = try Data(contentsOf: shared.appending(path: "objects/info/alternates"))
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        let destinationShared = destination.appending(path: ".build/repositories/shared.git")
        let targets = try alternateTargets(of: destinationShared)
        let moved = [(origin, root.appending(path: "origin.moved")), (middle, root.appending(path: "middle.moved"))]
        for (store, aside) in moved {
            try FileManager.default.moveItem(at: store, to: aside)
        }
        defer {
            for (store, aside) in moved {
                try? FileManager.default.moveItem(at: aside, to: store)
            }
        }

        // Assert
        let mirrors = try canonical(fixture.linkedWorktreeAdministration()).appending(
            path: "agentstudio-object-mirrors")
        #expect(targets.count == 1)
        #expect(targets.allSatisfy { $0.hasPrefix(mirrors.path + "/") }, "\(targets)")
        #expect(try fixture.git.succeeds("cat-file", "-e", "HEAD:up.txt", currentDirectory: destinationShared))
        #expect(try Data(contentsOf: shared.appending(path: "objects/info/alternates")) == sourceAlternates)
    }

    @Test(
        "an in-tree bare repository retires the registration of a flattened worktree and keeps the outside one"
    )
    func inTreeBareRetiresFlattenedWorktreeRegistration() async throws {
        // Arrange: a bare repository with one linked worktree inside the source and one outside it. The fork
        // flattens the inside worktree into an independent repository, so its registration has no reciprocal
        // gitfile in the destination and must not survive in the destination copy of the bare repository.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-bare-linked")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
        let project = fixture.source.appending(path: ".build/project.git")
        try fixture.git.run(["clone", "-q", "--bare", upstream.path, project.path])
        let inside = fixture.source.appending(path: ".build/work/main")
        try fixture.git.run(["worktree", "add", "-q", inside.path, "main"], currentDirectory: project)
        let outside = fixture.repository.root.appending(path: "outside-worktree")
        try fixture.git.run(["worktree", "add", "-q", "-b", "side", outside.path, "main"], currentDirectory: project)
        let sourceRegistrations = try worktreePaths(of: project, fixture)
        let sourceInsideRegistration = try Data(contentsOf: project.appending(path: "worktrees/main/gitdir"))
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationProject = destination.appending(path: ".build/project.git")
        let destinationInside = destination.appending(path: ".build/work/main")
        #expect(
            try worktreePaths(of: destinationProject, fixture)
                == [try canonical(destinationProject).path, try canonical(outside).path])
        #expect(!GitWorktreeForkFileProbe.exists(destinationProject.appending(path: "worktrees/main")))
        #expect(
            try fixture.git.run(["worktree", "prune", "-n", "-v"], currentDirectory: destinationProject).isEmpty)
        #expect(
            !(try fixture.git.run(["worktree", "list", "--porcelain"], currentDirectory: destinationProject))
                .contains("prunable"))
        let insideGitEntry = try #require(GitWorktreeForkFileProbe.info(destinationInside.appending(path: ".git")))
        #expect(insideGitEntry.st_mode & S_IFMT == S_IFDIR, "the flattened worktree is an independent repository")
        #expect(try fixture.statusLines(at: destinationInside).isEmpty)
        #expect(try fixture.blobID("HEAD", at: destinationInside) == fixture.blobID("HEAD", at: inside))
        #expect(try worktreePaths(of: project, fixture) == sourceRegistrations)
        #expect(try Data(contentsOf: project.appending(path: "worktrees/main/gitdir")) == sourceInsideRegistration)
    }

    @Test("a submodule whose .git directory was never absorbed is re-homed under destination administration")
    func nonAbsorbedSubmoduleIsRehomed() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-unabsorbed-submodule")
        defer { fixture.remove() }
        let library = try makeRepository(
            at: fixture.repository.root.appending(path: "library"), file: "library.txt", fixture: fixture)
        let sourceLibrary = fixture.source.appending(path: "deps/library")
        try fixture.git.run(["clone", "-q", library.path, sourceLibrary.path])
        try fixture.git.run("submodule", "add", "-q", library.path, "deps/library")
        try fixture.git.run("commit", "-qm", "submodule")
        let gitEntry = try #require(GitWorktreeForkFileProbe.info(sourceLibrary.appending(path: ".git")))
        #expect(gitEntry.st_mode & S_IFMT == S_IFDIR, "the source submodule keeps an embedded .git directory")
        try fixture.write("library.txt", "edited in source submodule\n", in: sourceLibrary)
        let sourceSuperStatus = try fixture.statusLines(at: fixture.source)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationLibrary = destination.appending(path: "deps/library")
        #expect(try fixture.statusLines(at: destinationLibrary) == [" M library.txt"])
        #expect(try fixture.statusLines(at: destination) == sourceSuperStatus)
        #expect(
            try absoluteGitDirectory(destinationLibrary, fixture)
                == canonical(fixture.linkedWorktreeAdministration()).appending(path: "modules/deps/library").path)
        #expect(try fixture.blobID("HEAD", at: destinationLibrary) == fixture.blobID("HEAD", at: sourceLibrary))
    }

    @Test("a linked worktree of the source repository nested inside the source is re-homed as its own repository")
    func nestedLinkedWorktreeOfSourceRepositoryIsRehomed() async throws {
        // Arrange: the `.worktrees/<name>` layout, whose administration lives in the source's own `.git/worktrees`.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-own-linked-worktree")
        defer { fixture.remove() }
        try ignore(".worktrees/", fixture: fixture)
        let sourceInner = fixture.source.appending(path: ".worktrees/inner")
        try fixture.git.run("worktree", "add", "-q", "-b", "inner", sourceInner.path)
        try fixture.write("inner.txt", "untracked in nested worktree\n", in: sourceInner)
        let innerStatus = try fixture.statusLines(at: sourceInner)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationInner = destination.appending(path: ".worktrees/inner")
        #expect(try fixture.statusLines(at: destinationInner) == innerStatus)
        #expect(try fixture.blobID("HEAD", at: destinationInner) == fixture.blobID("HEAD", at: sourceInner))
        #expect(
            try absoluteGitDirectory(destinationInner, fixture)
                == canonical(destinationInner.appending(path: ".git")).path)
        let innerWorktrees = try fixture.git.run(
            ["worktree", "list", "--porcelain"], currentDirectory: destinationInner)
        #expect(innerWorktrees.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)
        let sourceWorktrees = try fixture.git.run("worktree", "list", "--porcelain")
        #expect(sourceWorktrees.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 3)
    }

    @Test("a nested repository with a separate Git directory outside the source is re-homed")
    func separateGitDirectoryOutsideSourceIsRehomed() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-separate-git-dir")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let separateAdministration = fixture.repository.root.appending(path: "separate-admin")
        let sourceNested = fixture.source.appending(path: "vendor/separate")
        try FileManager.default.createDirectory(at: sourceNested, withIntermediateDirectories: true)
        try fixture.git.run(
            ["init", "-q", "--separate-git-dir", separateAdministration.path], currentDirectory: sourceNested)
        try fixture.write("separate.txt", "separate\n", in: sourceNested)
        try fixture.git.run(["add", "."], currentDirectory: sourceNested)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: sourceNested)
        try fixture.write("separate.txt", "dirty\n", in: sourceNested)
        let nestedStatus = try fixture.statusLines(at: sourceNested)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationNested = destination.appending(path: "vendor/separate")
        #expect(try fixture.statusLines(at: destinationNested) == nestedStatus)
        #expect(try fixture.blobID("HEAD", at: destinationNested) == fixture.blobID("HEAD", at: sourceNested))
        #expect(
            try absoluteGitDirectory(destinationNested, fixture)
                == canonical(destinationNested.appending(path: ".git")).path)
    }

    @Test("a nested repository's sparse checkout keeps its patterns and skip-worktree entries")
    func nestedSparseCheckoutKeepsSparseBehavior() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-nested-sparse")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let sourceNested = try makeRepository(
            at: fixture.source.appending(path: "vendor/sparse"), file: "root.txt", fixture: fixture)
        for path in ["kept/one.txt", "dropped/two.txt"] {
            try fixture.write(path, "\(path)\n", in: sourceNested)
        }
        try fixture.git.run(["add", "."], currentDirectory: sourceNested)
        try fixture.git.run(["commit", "-qm", "sparse tree"], currentDirectory: sourceNested)
        try fixture.git.run(["sparse-checkout", "set", "--cone", "kept"], currentDirectory: sourceNested)
        try fixture.write("kept/one.txt", "dirty inside the cone\n", in: sourceNested)
        let sourceList = try fixture.git.run(["sparse-checkout", "list"], currentDirectory: sourceNested)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationNested = destination.appending(path: "vendor/sparse")
        #expect(try fixture.statusLines(at: destinationNested) == [" M kept/one.txt"])
        #expect(try fixture.git.run(["sparse-checkout", "list"], currentDirectory: destinationNested) == sourceList)
        #expect(
            try fixture.git.run(["ls-files", "-t", "--", "dropped"], currentDirectory: destinationNested)
                .hasPrefix("S "))
        #expect(!GitWorktreeForkFileProbe.exists(destinationNested.appending(path: "dropped/two.txt")))
    }

    @Test("a nested .git entry that is not Git administration rejects the fork before mutation")
    func nonAdministrativeGitEntryRejectsBeforeMutation() async throws {
        // Arrange: some packages ship an ordinary file named `.git`; it must not be copied as plain data.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-ordinary-dotgit")
        defer { fixture.remove() }
        try ignore("node_modules/", fixture: fixture)
        try fixture.write("node_modules/example/.git", "ordinary artifact, not git administration\n")
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
                    relativePath: "node_modules/example/.git", reason: .unresolvableGitAdministration,
                    errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    private func ignore(_ pattern: String, fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "\(pattern)\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore \(pattern)")
    }

    private func backdateRegularFiles(under root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        let past = timespec(tv_sec: time(nil) - 60, tv_nsec: 0)
        for case let url as URL in enumerator {
            guard let info = GitWorktreeForkFileProbe.info(url), info.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            var times = [past, past]
            try #require(utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0)
        }
    }

    private func makeRepository(at path: URL, file: String, fixture: GitWorktreeForkFixture) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write(file, "\(file)\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
        return path
    }

    /// `git worktree list` paths, canonicalized, in Git's order: the repository itself, then registrations.
    private func worktreePaths(of repository: URL, _ fixture: GitWorktreeForkFixture) throws -> [String] {
        try fixture.git.run(["worktree", "list", "--porcelain"], currentDirectory: repository)
            .split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { try canonical(URL(fileURLWithPath: String($0.dropFirst("worktree ".count)))).path }
    }

    private func absoluteGitDirectory(_ worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> String {
        let path = try fixture.git.run(["rev-parse", "--absolute-git-dir"], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try canonical(URL(fileURLWithPath: path)).path
    }

    /// Canonical targets of a bare repository's `objects/info/alternates`, resolved the way Git does.
    private func alternateTargets(of bareRepository: URL) throws -> [String] {
        let objects = bareRepository.appending(path: "objects")
        let text = try String(contentsOf: objects.appending(path: "info/alternates"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let recorded = String(line)
            let target = recorded.hasPrefix("/") ? URL(fileURLWithPath: recorded) : objects.appending(path: recorded)
            return try canonical(target).path
        }
    }

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

enum AlternateLineForm: String, CaseIterable, Sendable {
    case absolute
    /// Climbs out of the source root and back in by name, so a byte copy would still resolve to the source.
    case relativeThroughParent
}

enum RewrittenFixturePointer: String, CaseIterable, Sendable {
    /// An absolute `remote.origin.url` re-aimed by configuration path re-homing.
    case configurationPath
    /// An absolute `objects/info/alternates` line re-aimed by copied-pointer re-homing.
    case alternates

    var relativePath: String {
        switch self {
        case .configurationPath: "config"
        case .alternates: "objects/info/alternates"
        }
    }

    /// What precedes the path on its line, as `git config` and alternates write it.
    var diffPrefix: String {
        switch self {
        case .configurationPath: "\turl = "
        case .alternates: ""
        }
    }
}
