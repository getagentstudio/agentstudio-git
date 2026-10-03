import AgentStudioGit
import Foundation
import Testing

/// Absolute paths a nested repository's configuration records: inside the source they must lead to the
/// destination counterpart (re-homed administration first, then the destination tree); outside they stay.
@Suite("Git worktree fork nested configuration integration", .serialized)
struct GitWorktreeForkNestedConfigurationIntegrationTests {
    @Test("an absolute include into a nested repository's source .git follows the re-homed administration")
    func nestedIncludeFollowsRehomedAdministration() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-include")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let include = tool.appending(path: ".git/extra.conf")
        try "[agentstudio]\n\tmarker = source\n".write(to: include, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", include.path], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        try "[agentstudio]\n\tmarker = edited\n".write(to: include, atomically: false, encoding: .utf8)

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        #expect(
            try configuredPath("include.path", at: destinationTool, fixture)
                == canonical(destinationTool.appending(path: ".git/extra.conf")).path)
        #expect(try configValue("agentstudio.marker", at: destinationTool, fixture) == "source")
    }

    @Test("an absolute include into an absorbed submodule's source administration follows its re-homed modules")
    func submoduleIncludeFollowsRehomedModules() async throws {
        // Arrange: plain source-root substitution would aim at `<destination>/.git/modules`, but the fork's
        // `.git` is a gitfile; the submodule's administration lives under the fork's own administration.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-submodule")
        defer { fixture.remove() }
        let library = try makeRepository(
            at: fixture.repository.root.appending(path: "library"), file: "library.txt", fixture: fixture)
        try fixture.git.run("submodule", "add", "-q", library.path, "deps/library")
        try fixture.git.run("commit", "-qm", "submodule")
        let sourceLibrary = fixture.source.appending(path: "deps/library")
        let include = URL(fileURLWithPath: try absoluteGitDirectory(sourceLibrary, fixture))
            .appending(path: "extra.conf")
        try "[agentstudio]\n\tmarker = source\n".write(to: include, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", include.path], currentDirectory: sourceLibrary)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        try "[agentstudio]\n\tmarker = edited\n".write(to: include, atomically: false, encoding: .utf8)

        // Assert
        let destinationLibrary = destination.appending(path: "deps/library")
        #expect(
            try configuredPath("include.path", at: destinationLibrary, fixture)
                == canonical(fixture.linkedWorktreeAdministration()).appending(path: "modules/deps/library/extra.conf")
                .path)
        #expect(try configValue("agentstudio.marker", at: destinationLibrary, fixture) == "source")
    }

    @Test("an absolute include into a nested linked worktree's external common directory follows its flattened copy")
    func linkedWorktreeIncludeFollowsFlattenedAdministration() async throws {
        // Arrange: the include lives outside the source tree, but in administration the fork re-homes.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-linked")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let outside = try makeRepository(
            at: fixture.repository.root.appending(path: "outside"), file: "outside.txt", fixture: fixture)
        let sourceLinked = fixture.source.appending(path: "vendor/linked")
        try fixture.git.run(
            ["worktree", "add", "-q", "-b", "nested-linked", sourceLinked.path], currentDirectory: outside)
        let include = outside.appending(path: ".git/extra.conf")
        try "[agentstudio]\n\tmarker = source\n".write(to: include, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", include.path], currentDirectory: outside)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        try "[agentstudio]\n\tmarker = edited\n".write(to: include, atomically: false, encoding: .utf8)

        // Assert
        let destinationLinked = destination.appending(path: "vendor/linked")
        #expect(
            try configuredPath("include.path", at: destinationLinked, fixture)
                == canonical(destinationLinked.appending(path: ".git/extra.conf")).path)
        #expect(try configValue("agentstudio.marker", at: destinationLinked, fixture) == "source")
        #expect(try configValue("include.path", at: outside, fixture) == include.path)
    }

    @Test("an absolute lfs.storage inside the source tree points at the destination copy")
    func nestedLargeFileStorageFollowsDestinationCopy() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-lfs-storage")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "vendor/\nlarge-file-store/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore vendor and storage")
        try fixture.write("large-file-store/objects/placeholder", "stored\n")
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let storage = fixture.source.appending(path: "large-file-store")
        try fixture.git.run(["config", "lfs.storage", storage.path], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        #expect(
            try configuredPath("lfs.storage", at: destination.appending(path: "vendor/tool"), fixture)
                == canonical(destination.appending(path: "large-file-store")).path)
        #expect(try configuredPath("lfs.storage", at: tool, fixture) == canonical(storage).path)
    }

    @Test("an absolute include outside the source tree is left unchanged")
    func outsideIncludeIsUnchanged() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-outside")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let include = fixture.repository.root.appending(path: "shared.conf")
        try "[agentstudio]\n\tmarker = shared\n".write(to: include, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", include.path], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        #expect(try configValue("include.path", at: destinationTool, fixture) == include.path)
        #expect(try configValue("agentstudio.marker", at: destinationTool, fixture) == "shared")
    }

    @Test("a nested linked worktree's shared config naming another worktree's private path keeps that path")
    func uncapturedWorktreePrivatePathIsShared() async throws {
        // Arrange: the real-checkout shape. Agent worktrees of the source repository live in an ignored folder,
        // and the shared repository config names a file in a third worktree's private administration.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-other-worktree")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let other = fixture.repository.root.appending(path: "other-worktree")
        try fixture.git.run("worktree", "add", "-q", "-b", "other", other.path)
        let signers = try canonical(fixture.source.appending(path: ".git/worktrees/other-worktree"))
            .appending(path: "allowed_signers")
        try "signers\n".write(to: signers, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAgent = destination.appending(path: ".claude/worktrees/agent")
        #expect(try configValue("gpg.ssh.allowedSignersFile", at: destinationAgent, fixture) == signers.path)
        #expect(
            try absoluteGitDirectory(destinationAgent, fixture)
                == canonical(destinationAgent.appending(path: ".git")).path)
    }

    @Test("a nested linked worktree's config naming its own private administration follows its destination copy")
    func nestedWorktreePrivatePathFollowsDestinationAdministration() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-own-private")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let signers = try canonical(fixture.source.appending(path: ".git/worktrees/agent"))
            .appending(path: "allowed_signers")
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAgent = destination.appending(path: ".claude/worktrees/agent")
        #expect(
            try configValue("gpg.ssh.allowedSignersFile", at: destinationAgent, fixture)
                == canonical(destinationAgent.appending(path: ".git")).appending(path: "allowed_signers").path)
    }

    @Test("a linked source's private administration path in nested config follows the fork's private administration")
    func linkedSourcePrivatePathFollowsForkAdministration() async throws {
        // Arrange: fork from a linked worktree whose nested repository names that worktree's private administration.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-linked-source")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let linkedSource = fixture.repository.root.appending(path: "linked-source")
        try fixture.git.run("worktree", "add", "-q", "-b", "linked-source", linkedSource.path)
        let tool = try makeRepository(
            at: linkedSource.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let sourcePrivate = try canonical(fixture.linkedWorktreeAdministration("linked-source"))
        try fixture.git.run(
            ["config", "gpg.ssh.allowedSignersFile", sourcePrivate.appending(path: "allowed_signers").path],
            currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            GitForkWorktreeRequest(
                sourceWorktreePath: linkedSource,
                destinationPath: destination,
                mode: .newBranch(name: "fork"),
                materialization: .copyOnWrite
            ))

        // Assert
        #expect(
            try configValue("gpg.ssh.allowedSignersFile", at: destination.appending(path: "vendor/tool"), fixture)
                == canonical(fixture.linkedWorktreeAdministration()).appending(path: "allowed_signers").path)
    }

    @Test("a nested repository's config naming a shared file in the source repository's common directory keeps it")
    func sharedCommonDirectoryPathIsUnchanged() async throws {
        // Arrange: the fork is a linked worktree of the same repository, so the common directory is shared.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-common")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let shared = try canonical(fixture.source.appending(path: ".git")).appending(path: "shared.conf")
        try "[agentstudio]\n\tmarker = shared\n".write(to: shared, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", shared.path], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        #expect(try configValue("include.path", at: destinationTool, fixture) == shared.path)
        #expect(try configValue("agentstudio.marker", at: destinationTool, fixture) == "shared")
    }

    @Test("a diff driver's regex values are not paths, so one starting with the source root keeps its bytes")
    func diffDriverRegexValuesAreNotRelocated() async throws {
        // Arrange: Git reads xfuncname, funcname, and wordRegex as regular expressions (userdiff_config).
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-diff-regex")
        defer { fixture.remove() }
        try ignoreVendorAndStorage(fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let sourceRoot = try canonical(fixture.source).path
        let regexes = [
            "diff.swift.xfuncname": "\(sourceRoot)/^func .*$",
            "diff.swift.funcname": "\(sourceRoot)/^struct .*$",
            "diff.swift.wordRegex": "\(sourceRoot)/[a-z]+",
        ]
        for (key, regex) in regexes {
            try fixture.git.run(["config", key, regex], currentDirectory: tool)
        }
        let storage = try canonical(fixture.source.appending(path: "large-file-store"))
        try fixture.git.run(["config", "lfs.storage", storage.path], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        for (key, regex) in regexes {
            #expect(try configValue(key, at: destinationTool, fixture) == regex, "\(key)")
        }
        #expect(
            try configuredPath("lfs.storage", at: destinationTool, fixture)
                == canonical(destination.appending(path: "large-file-store")).path)
    }

    private func ignoreVendorAndStorage(_ fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "vendor/\nlarge-file-store/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore vendor and storage")
        try fixture.write("large-file-store/objects/placeholder", "stored\n")
    }

    private func ignore(_ pattern: String, fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "\(pattern)\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore \(pattern)")
    }

    private func makeRepository(at path: URL, file: String, fixture: GitWorktreeForkFixture) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write(file, "\(file)\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
        return path
    }

    private func configValue(_ key: String, at worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> String {
        try fixture.git.run(["config", "--get", key], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configuredPath(_ key: String, at worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> String {
        try canonical(URL(fileURLWithPath: configValue(key, at: worktree, fixture))).path
    }

    private func absoluteGitDirectory(_ worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> String {
        let path = try fixture.git.run(["rev-parse", "--absolute-git-dir"], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try canonical(URL(fileURLWithPath: path)).path
    }

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
