import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// Includes the fork does not own a copy of (outside the source, in the shared repository, or reached through
/// `~/`): never edited, read with their own includes, and refused when they still name relocated source state.
@Suite("Git worktree fork external include integration", .serialized)
struct GitWorktreeForkExternalIncludeIntegrationTests {
    @Test("a shared include naming a captured worktree's private administration refuses the fork, unedited")
    func sharedIncludeEscapingIntoCapturedPrivateAdministrationRefuses() async throws {
        // Arrange: the shared repository config includes a common-directory file whose core.hooksPath names
        // the private administration of a nested linked worktree the fork captures. The fork may not edit
        // that shared file, and keeping it would leave the destination reading source-private state.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-shared-escape")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let common = try canonical(fixture.source.appending(path: ".git"))
        let sharedInclude = common.appending(path: "shared-hooks.conf")
        try "[core]\n\thooksPath = \(common.path)/worktrees/agent/hooks\n"
            .write(to: sharedInclude, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "include.path", sharedInclude.path)
        let sharedBytes = try Data(contentsOf: sharedInclude)
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
                    relativePath: ".claude/worktrees/agent/.git/config: core.hookspath = .git/worktrees/agent/hooks",
                    reason: .unresolvableGitAdministration, errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == branchesBefore)
        #expect(try Data(contentsOf: sharedInclude) == sharedBytes)
    }

    @Test("an include outside the source holding only outside paths is read, left unedited, and the fork succeeds")
    func outsideIncludeWithOutsideValuesIsAccepted() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-outside-values")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let root = try canonical(fixture.repository.root)
        let outsideInclude = root.appending(path: "outside.conf")
        let outsideHooks = root.appending(path: "outside-hooks").path
        try "[core]\n\thooksPath = \(outsideHooks)\n".write(to: outsideInclude, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", outsideInclude.path], currentDirectory: tool)
        let outsideBytes = try Data(contentsOf: outsideInclude)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        #expect(try configValue("include.path", at: destinationTool, fixture) == outsideInclude.path)
        #expect(try configValue("core.hooksPath", at: destinationTool, fixture) == outsideHooks)
        #expect(try Data(contentsOf: outsideInclude) == outsideBytes)
    }

    @Test(
        "an unedited include chain outside the fork naming a captured private administration refuses the fork",
        arguments: [ExternalIncludeLocation.outsideSource, .sharedRepository]
    )
    func externalIncludeChainEscapeRefuses(location: ExternalIncludeLocation) async throws {
        // Arrange: the shared repository config includes a.conf, which includes b.conf by a relative path, and
        // b.conf points core.hooksPath into a captured nested worktree's private administration.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-chain-escape")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        try fixture.git.run(
            "worktree", "add", "-q", "-b", "agent", fixture.source.appending(path: ".claude/worktrees/agent").path)
        let common = try canonical(fixture.source.appending(path: ".git"))
        let directory = location == .sharedRepository ? common : try canonical(fixture.repository.root)
        let first = directory.appending(path: "a.conf")
        let second = directory.appending(path: "b.conf")
        try "[include]\n\tpath = b.conf\n".write(to: first, atomically: false, encoding: .utf8)
        try "[core]\n\thooksPath = \(common.path)/worktrees/agent/hooks\n"
            .write(to: second, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "include.path", first.path)
        let externalBytes = [try Data(contentsOf: first), try Data(contentsOf: second)]
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
                    relativePath: ".claude/worktrees/agent/.git/config: core.hookspath = .git/worktrees/agent/hooks",
                    reason: .unresolvableGitAdministration, errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == branchesBefore)
        #expect([try Data(contentsOf: first), try Data(contentsOf: second)] == externalBytes)
    }

    @Test("an outside include chain holding only a marker is read, left unedited, and stays effective")
    func outsideIncludeChainMarkerIsAccepted() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-chain-safe")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let root = try canonical(fixture.repository.root)
        let first = root.appending(path: "a.conf")
        let second = root.appending(path: "b.conf")
        try "[include]\n\tpath = b.conf\n".write(to: first, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tmarker = outside-safe\n".write(to: second, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", first.path], currentDirectory: tool)
        let externalBytes = [try Data(contentsOf: first), try Data(contentsOf: second)]
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        let ownInclude = try fixture.git.run(
            ["config", "--file", destinationTool.appending(path: ".git/config").path, "--get", "include.path"])
        #expect(ownInclude == "\(first.path)\n")
        #expect(try configValue("agentstudio.marker", at: destinationTool, fixture) == "outside-safe")
        #expect([try Data(contentsOf: first), try Data(contentsOf: second)] == externalBytes)
    }

    @Test("a ~/ include into relocated administration follows it; home resolves through the injected seam")
    func homeIncludeIntoRelocatedAdministrationFollowsIt() async throws {
        // Arrange: home is the fixture root (never the real home), so `~/<source>/...` names the nested `.git`.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-home-mapped")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let home = try canonical(fixture.repository.root)
        let extra = try canonical(tool.appending(path: ".git")).appending(path: "extra.conf")
        try "[agentstudio]\n\tmarker = source\n".write(to: extra, atomically: false, encoding: .utf8)
        let homeValue = "~/\(fixture.source.lastPathComponent)/vendor/tool/.git/extra.conf"
        try fixture.git.run(["config", "include.path", homeValue], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await client(home: home).forkWorktree(fixture.request())
        try "[agentstudio]\n\tmarker = changed-in-source\n".write(to: extra, atomically: false, encoding: .utf8)

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        #expect(
            try configValue("include.path", at: destinationTool, fixture)
                == canonical(destinationTool.appending(path: ".git/extra.conf")).path)
        #expect(try configValue("agentstudio.marker", at: destinationTool, fixture) == "source")
    }

    @Test("a ~/ include outside the source is left exactly as written")
    func homeIncludeOutsideSourceIsUnchanged() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-home-outside")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let home = try canonical(fixture.repository.root)
        try "[agentstudio]\n\tmarker = home\n"
            .write(to: home.appending(path: "outside.conf"), atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", "~/outside.conf"], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await client(home: home).forkWorktree(fixture.request())

        // Assert
        #expect(
            try configValue("include.path", at: destination.appending(path: "vendor/tool"), fixture)
                == "~/outside.conf")
    }

    /// A client whose fork resolves `~/` against `home` instead of the process's home directory.
    private func client(home: URL) -> LibGit2AgentStudioGitLocalClient {
        let live = WorktreeForkHostFactsProvider.live
        return LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(
                hostFacts: WorktreeForkHostFactsProvider(
                    operatingSystemMajorVersion: live.operatingSystemMajorVersion,
                    volumeFacts: live.volumeFacts,
                    homeDirectory: { home }
                )))
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

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

enum ExternalIncludeLocation: String, CaseIterable, Sendable {
    case outsideSource
    case sharedRepository
}
