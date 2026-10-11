import AgentStudioGit
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git observation sweep integration", .serialized)
struct GitObservationSweepIntegrationTests {
    enum IneligibleRead: CaseIterable {
        case noPlan
        case unsupportedPlan
        case pathspec
        case emptyPathspec
        case withoutUntracked
        case dirty
    }

    @Test("reads that cannot mint a baseline do not probe worktree attributes", arguments: IneligibleRead.allCases)
    func ineligibleReadsDoNotSweep(reason: IneligibleRead) async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-ineligible")
        defer { fixture.remove() }
        let preparedPlan = try await LibGit2AgentStudioGitLocalClient().statusObservationPlan(
            for: fixture.repositoryPath)
        let probePaths = OSAllocatedUnfairLock(initialState: [String]())
        let reader = statusReader(recording: probePaths)
        var plan: GitStatusObservationPlan? = preparedPlan
        let options: GitStatusOptions
        switch reason {
        case .noPlan:
            plan = nil
            options = GitStatusOptions()
        case .unsupportedPlan:
            plan = GitStatusObservationPlan(
                identity: preparedPlan.identity, scopes: preparedPlan.scopes, support: .unsupported)
            options = GitStatusOptions()
        case .pathspec:
            options = GitStatusOptions(pathspecs: ["README.md"])
        case .emptyPathspec:
            options = GitStatusOptions(pathspecs: [])
        case .withoutUntracked:
            options = GitStatusOptions(includeUntracked: false)
        case .dirty:
            try fixture.write("README.md", contents: "hello\nchanged\n")
            options = GitStatusOptions()
        }

        // Act
        let read = try reader.statusFacts(for: fixture.repositoryPath, options: options, observationPlan: plan)

        // Assert
        #expect(read.exactCleanBaseline == nil)
        #expect(probePaths.withLock { $0 }.isEmpty)
        #expect(read.facts.entries.isEmpty == (reason != .dirty))
    }

    @Test("supported clean reads still perform fresh coverage checks")
    func eligibleReadsStillSweep() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-eligible")
        defer { fixture.remove() }
        let plan = try await LibGit2AgentStudioGitLocalClient().statusObservationPlan(for: fixture.repositoryPath)
        let probePaths = OSAllocatedUnfairLock(initialState: [String]())

        // Act
        let read = try statusReader(recording: probePaths).statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)

        // Assert
        #expect(read.facts.entries.isEmpty)
        #expect(read.exactCleanBaseline?.observationIdentity == plan.identity)
        #expect(probePaths.withLock { $0 }.count == 1)
    }

    @Test("incomplete config coverage makes the attribute walk lazy")
    func unsupportedConstructionDoesNotSweep() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-incomplete")
        defer { fixture.remove() }
        try fixture.git.run("config", "include.path", fixture.root.appending(path: "missing.gitconfig").path)
        let probePaths = OSAllocatedUnfairLock(initialState: [String]())
        let reader = LibGit2StatusObservationIdentityReader(worktreeAttributeProbe: recordingProbe(probePaths))

        // Act
        let plan = try reader.plan(for: fixture.repositoryPath)

        // Assert
        #expect(plan.support == .unsupported)
        #expect(probePaths.withLock { $0 }.isEmpty)
        let descriptor = plan.scopes.sorted { ($0.path.path, $0.kind.rawValue) < ($1.path.path, $1.kind.rawValue) }
            .map { "\($0.kind.rawValue):\($0.path.path)" }.joined(separator: "\u{0}")
        #expect(plan.identity.rawValue == Data(descriptor.utf8).base64EncodedString())
        #expect(plan.scopes.contains { $0.path.path.hasSuffix("/.git/index") && $0.kind == .item })
        #expect(plan.scopes.contains { $0.path.path.hasSuffix("/.git/config") && $0.kind == .item })
    }

    @Test(
        "invalid index and configuration still fail before authority can be considered", arguments: ["index", "config"])
    func validationErrorsArePreserved(fileName: String) async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-errors")
        defer { fixture.remove() }
        let prepared = try await LibGit2AgentStudioGitLocalClient().statusObservationPlan(for: fixture.repositoryPath)
        let plan = GitStatusObservationPlan(identity: prepared.identity, scopes: prepared.scopes, support: .unsupported)
        try fixture.write(".git/\(fileName)", contents: "invalid repository input\n")
        let probePaths = OSAllocatedUnfairLock(initialState: [String]())

        // Act / Assert
        #expect(throws: GitDataPlaneError.self) {
            _ = try statusReader(recording: probePaths).statusFacts(
                for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        }
        #expect(throws: GitDataPlaneError.self) {
            _ = try LibGit2StatusObservationIdentityReader(worktreeAttributeProbe: recordingProbe(probePaths))
                .plan(for: fixture.repositoryPath)
        }
    }

    @Test("native probes do not call permission errors missing attributes")
    func inaccessibleAttributesDeclineCoverage() throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-denied")
        defer { fixture.remove() }
        let deniedDirectory = fixture.repositoryPath.appending(path: "denied")
        try fixture.write("denied/.gitattributes", contents: "*.txt -text\n")
        try #require(chmod(deniedDirectory.path, 0) == 0)
        defer { chmod(deniedDirectory.path, 0o755) }

        // Act
        let nativePath = GitFixtureRepository.resolvedPath(fixture.repositoryPath) + "/denied/.gitattributes"
        let lookup = nativePath.withCString { GitWorktreeAttributeProbe.live.lookup($0) }
        let direct = nativePath.withCString {
            GitWorktreeAttributeProbe.live.isDirect($0)
        }

        // Assert
        #expect(!direct)
        guard case .failure(let errorNumber) = lookup else {
            Issue.record("expected permission failure from native metadata lookup")
            return
        }
        #expect(errorNumber == EACCES)
    }

    @Test("only ENOENT is a covered absence", arguments: [ENOENT, EACCES, ELOOP, EIO, ENOTDIR])
    func lookupFailuresDoNotGrantAuthority(errorNumber: Int32) throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-probe-error")
        defer { fixture.remove() }
        let plan = try LibGit2StatusObservationIdentityReader().plan(for: fixture.repositoryPath)
        let probe = GitWorktreeAttributeProbe { _ in .failure(errorNumber) }
        let reader = LibGit2StatusReader(
            observationIdentityReader: LibGit2StatusObservationIdentityReader(worktreeAttributeProbe: probe))

        // Act
        let read = try reader.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)

        // Assert
        #expect(read.facts.entries.isEmpty)
        #expect((read.exactCleanBaseline != nil) == (errorNumber == ENOENT))
    }

    @Test("native paths probe each distinct indexed ancestor once")
    func uniqueAncestorProbesUseFilesystemPaths() throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-paths")
        defer { fixture.remove() }
        for path in ["src/a.txt", "src/b.txt", "src/deeper/c.txt", "docs/d.txt", "space % # Café/e.txt"] {
            try fixture.write(path, contents: "one\n")
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "indexed directories")
        let paths = OSAllocatedUnfairLock(initialState: [String]())

        // Act
        let plan = try LibGit2StatusObservationIdentityReader(worktreeAttributeProbe: recordingProbe(paths))
            .plan(for: fixture.repositoryPath)

        // Assert
        #expect(plan.support == .supported)
        let rootPath = GitFixtureRepository.resolvedPath(fixture.repositoryPath)
        let expected = Set(
            ["", "src/", "src/deeper/", "docs/", "space % # Café/"].map { rootPath + "/" + $0 + ".gitattributes" })
        let recorded = paths.withLock { $0 }
        #expect(Set(recorded) == expected)
        #expect(recorded.count == expected.count)
    }

    @Test(
        "attribute appearance and disappearance deny stale clean baselines",
        arguments: [false, true], ["", "nested/"]
    )
    func attributePresenceChangesRemainExact(disappears: Bool, directory: String) async throws {
        // Arrange
        let fixture = try attributeFixture(prefix: "agentstudio-git-observation-presence")
        defer { fixture.remove() }
        let relativeFile = directory + "Lines.txt"
        let relativeAttributes = directory + ".gitattributes"
        if disappears {
            let fallback = fixture.root.appending(path: "fallback-attributes")
            try "Lines.txt text eol=lf\n".write(to: fallback, atomically: true, encoding: .utf8)
            try fixture.git.run("config", "core.attributesFile", fallback.path)
            try fixture.write(relativeAttributes, contents: "Lines.txt -text\n")
        }
        try seedAttributeLines(fixture, relativePath: relativeFile)
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let before = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        #expect(before.facts.entries.isEmpty)
        #expect(before.exactCleanBaseline != nil)

        // Act
        if disappears {
            try FileManager.default.removeItem(at: fixture.repositoryPath.appending(path: relativeAttributes))
        } else {
            try fixture.write(relativeAttributes, contents: "Lines.txt text eol=lf\n")
        }
        let after = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)

        // Assert
        #expect(after.facts.entries.contains { $0.path == relativeFile && $0.worktreeState == .modified })
        #expect(after.exactCleanBaseline == nil)
    }

    @Test("a new attribute alias cannot reuse previously supported clean coverage")
    func attributeAliasTransitionDeclinesCleanAuthority() async throws {
        // Arrange
        let fixture = try attributeFixture(prefix: "agentstudio-git-observation-alias")
        defer { fixture.remove() }
        try fixture.write(".gitattributes", contents: "Lines.txt -text\n")
        try seedAttributeLines(fixture)
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let before = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        #expect(before.exactCleanBaseline != nil)
        let indexBefore = try Data(contentsOf: fixture.repositoryPath.appending(path: ".git/index"))
        let target = fixture.root.appending(path: "external-attributes")
        try "Lines.txt -text\n".write(to: target, atomically: true, encoding: .utf8)

        // Act
        let alias = fixture.repositoryPath.appending(path: ".gitattributes")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let currentPlan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let read = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)

        // Assert
        #expect(try Data(contentsOf: fixture.repositoryPath.appending(path: ".git/index")) == indexBefore)
        #expect(currentPlan.identity == plan.identity)
        #expect(currentPlan.support == .unsupported)
        #expect(read.facts.entries.isEmpty)
        #expect(read.exactCleanBaseline == nil)
        try "Lines.txt text eol=lf\n".write(to: target, atomically: true, encoding: .utf8)
        let changed = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        #expect(changed.facts.entries.contains { $0.path == "Lines.txt" && $0.worktreeState == .modified })
        #expect(changed.exactCleanBaseline == nil)
        try FileManager.default.removeItem(at: alias)
        try fixture.write(".gitattributes", contents: "Lines.txt -text\n")
        let repaired = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        #expect(repaired.facts.entries.isEmpty)
        #expect(repaired.exactCleanBaseline != nil)
    }

    @Test(
        "symlinked ancestor directories remain unsupported with present or missing attributes",
        arguments: [false, true])
    func ancestorAliasesDeclineCoverage(hasAttributes: Bool) async throws {
        // Arrange
        let fixture = try attributeFixture(prefix: "agentstudio-git-observation-ancestor")
        defer { fixture.remove() }
        try fixture.write("nested/Lines.txt", contents: "one\n")
        try fixture.git.run("add", "nested/Lines.txt")
        try fixture.git.run("commit", "-m", "nested file")
        if hasAttributes { try fixture.write("nested/.gitattributes", contents: "*.txt -text\n") }
        let directory = fixture.repositoryPath.appending(path: "nested")
        let externalDirectory = fixture.root.appending(path: "external-directory")

        // Act
        try FileManager.default.moveItem(at: directory, to: externalDirectory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: externalDirectory)
        let plan = try await LibGit2AgentStudioGitLocalClient().statusObservationPlan(for: fixture.repositoryPath)
        let direct = directory.appending(path: ".gitattributes").path.withCString {
            GitWorktreeAttributeProbe.live.isDirect($0)
        }

        // Assert
        #expect(!direct)
        #expect(plan.support == .unsupported)
    }

    @Test("new indexed directories are checked even when the entry count is unchanged", arguments: [false, true])
    func newIndexedDirectoriesDeclineAliasAuthority(movesExistingFile: Bool) async throws {
        // Arrange
        let fixture = try attributeFixture(prefix: "agentstudio-git-observation-new-directory")
        defer { fixture.remove() }
        try fixture.write("old/Lines.txt", contents: "one\n")
        try fixture.git.run("add", "old/Lines.txt")
        try fixture.git.run("commit", "-m", "old directory")
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let target = fixture.root.appending(path: "external-attributes")
        try "*.txt -text\n".write(to: target, atomically: true, encoding: .utf8)
        let newDirectory = fixture.repositoryPath.appending(path: "new")
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)

        // Act
        if movesExistingFile {
            try fixture.git.run("mv", "old/Lines.txt", "new/Lines.txt")
        } else {
            try fixture.write("new/Lines.txt", contents: "one\n")
            try fixture.git.run("add", "new/Lines.txt")
        }
        try fixture.git.run("commit", "-m", "new indexed directory")
        try FileManager.default.createSymbolicLink(
            at: newDirectory.appending(path: ".gitattributes"), withDestinationURL: target)
        let read = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        let current = try await client.statusObservationPlan(for: fixture.repositoryPath)

        // Assert
        #expect(read.facts.entries.isEmpty)
        #expect(current.identity == plan.identity)
        #expect(current.support == .unsupported)
        #expect(read.exactCleanBaseline == nil)
    }

    enum AttributeNodeKind: CaseIterable {
        case absent
        case regularFile
        case directory
        case symbolicLink
        case danglingLink
        case selfLink
    }

    @Test("native leaf probes return symlink mode without following the target", arguments: AttributeNodeKind.allCases)
    func nativeLeafKindsPreserveCoveragePolicy(kind: AttributeNodeKind) throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-observation-leaf-kind")
        defer { fixture.remove() }
        let leaf = fixture.repositoryPath.appending(path: ".gitattributes")
        switch kind {
        case .absent:
            break
        case .regularFile:
            try fixture.write(".gitattributes", contents: "*.txt -text\n")
        case .directory:
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        case .symbolicLink:
            let target = fixture.root.appending(path: "external-attributes")
            try "*.txt -text\n".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
        case .danglingLink:
            try FileManager.default.createSymbolicLink(
                at: leaf, withDestinationURL: fixture.root.appending(path: "missing"))
        case .selfLink:
            try FileManager.default.createSymbolicLink(atPath: leaf.path, withDestinationPath: ".gitattributes")
        }
        let path = GitFixtureRepository.resolvedPath(fixture.repositoryPath) + "/.gitattributes"

        // Act
        let outcome = path.withCString { GitWorktreeAttributeProbe.live.lookup($0) }
        let direct = path.withCString { GitWorktreeAttributeProbe.live.isDirect($0) }

        // Assert
        #expect(direct == (kind == .absent || kind == .regularFile || kind == .directory))
        if kind == .symbolicLink || kind == .danglingLink || kind == .selfLink {
            guard case .mode(let mode) = outcome else {
                Issue.record("expected final-link metadata without following the link")
                return
            }
            #expect(mode & S_IFMT == S_IFLNK)
        }
    }

    private func attributeFixture(prefix: String) throws -> GitFixtureRepository {
        let fixture = try GitFixtureRepository.makeRepository(prefix: prefix)
        try fixture.git.run("config", "core.autocrlf", "false")
        try fixture.write(".git/info/exclude", contents: ".gitattributes\n")
        return fixture
    }

    private func seedAttributeLines(_ fixture: GitFixtureRepository, relativePath: String = "Lines.txt") throws {
        try fixture.write(relativePath, contents: "first\r\nsecond\r\n")
        try fixture.git.run("add", relativePath)
        try fixture.git.run("commit", "-m", "raw line endings")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4_102_444_800)],
            ofItemAtPath: fixture.repositoryPath.appending(path: relativePath).path)
    }

    private func statusReader(recording paths: OSAllocatedUnfairLock<[String]>) -> LibGit2StatusReader {
        LibGit2StatusReader(
            observationIdentityReader: LibGit2StatusObservationIdentityReader(
                worktreeAttributeProbe: recordingProbe(paths)))
    }

    private func recordingProbe(_ paths: OSAllocatedUnfairLock<[String]>) -> GitWorktreeAttributeProbe {
        GitWorktreeAttributeProbe { pathPointer in
            let path = String(cString: pathPointer)
            paths.withLock { $0.append(path) }
            return GitWorktreeAttributeProbe.live.lookup(pathPointer)
        }
    }
}
