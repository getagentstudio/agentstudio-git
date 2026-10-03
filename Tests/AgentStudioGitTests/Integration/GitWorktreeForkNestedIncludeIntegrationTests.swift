import AgentStudioGit
import Foundation
import Testing

/// Configuration a nested repository reaches through includes: every file the fork owns a copy of is
/// re-homed at every level, include conditions naming relocated administration follow it, and cycles end.
@Suite("Git worktree fork nested include integration", .serialized)
struct GitWorktreeForkNestedIncludeIntegrationTests {
    @Test("configuration reached through nested includes is re-homed at every level")
    func includedConfigurationIsRehomedAtEveryLevel() async throws {
        // Arrange: config includes extra.conf, which includes deeper.conf and names the source's LFS storage.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-include-chain")
        defer { fixture.remove() }
        try ignoreVendorAndStorage(fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let administration = try canonical(tool.appending(path: ".git"))
        let storage = try canonical(fixture.source.appending(path: "large-file-store"))
        let extra = administration.appending(path: "extra.conf")
        let deeper = administration.appending(path: "deeper.conf")
        try "[include]\n\tpath = \(deeper.path)\n[lfs]\n\tstorage = \(storage.path)\n"
            .write(to: extra, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tmarker = original\n".write(to: deeper, atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", extra.path], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        try "[agentstudio]\n\tmarker = changed-in-source\n".write(to: deeper, atomically: false, encoding: .utf8)

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        let destinationAdministration = try canonical(destinationTool.appending(path: ".git"))
        #expect(
            try configValues("include.path", at: destinationTool, fixture)
                == [
                    destinationAdministration.appending(path: "extra.conf").path,
                    destinationAdministration.appending(path: "deeper.conf").path,
                ])
        #expect(
            try configuredPath("lfs.storage", at: destinationTool, fixture)
                == canonical(destination.appending(path: "large-file-store")).path)
        #expect(try configValue("agentstudio.marker", at: destinationTool, fixture) == "original")
    }

    @Test("a relative include inside an included file reaches a re-homed file whose source paths are re-homed")
    func relativeInnerIncludeIsRehomed() async throws {
        // Arrange: extra.conf includes deeper.conf by a relative path; deeper.conf names the source storage.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-include-relative")
        defer { fixture.remove() }
        try ignoreVendorAndStorage(fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let administration = try canonical(tool.appending(path: ".git"))
        let storage = try canonical(fixture.source.appending(path: "large-file-store"))
        let extra = administration.appending(path: "extra.conf")
        try "[include]\n\tpath = deeper.conf\n".write(to: extra, atomically: false, encoding: .utf8)
        try "[lfs]\n\tstorage = \(storage.path)\n"
            .write(to: administration.appending(path: "deeper.conf"), atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "include.path", extra.path], currentDirectory: tool)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationTool = destination.appending(path: "vendor/tool")
        #expect(
            try configuredPath("lfs.storage", at: destinationTool, fixture)
                == canonical(destination.appending(path: "large-file-store")).path)
        #expect(
            try String(contentsOf: destinationTool.appending(path: ".git/extra.conf"), encoding: .utf8)
                == "[include]\n\tpath = deeper.conf\n")
    }

    @Test("an include cycle in nested configuration finishes with a typed failure and leaves nothing behind")
    func includeCycleFailsWithoutLooping() async throws {
        // Arrange: config includes a.conf, a.conf includes b.conf, and b.conf includes a.conf again.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-include-cycle")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let tool = try makeRepository(
            at: fixture.source.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let administration = try canonical(tool.appending(path: ".git"))
        try "[include]\n\tpath = b.conf\n"
            .write(to: administration.appending(path: "a.conf"), atomically: false, encoding: .utf8)
        try "[include]\n\tpath = a.conf\n"
            .write(to: administration.appending(path: "b.conf"), atomically: false, encoding: .utf8)
        try fixture.git.run(
            [
                "config", "--file", administration.appending(path: "config").path, "include.path",
                administration.appending(path: "a.conf").path,
            ])
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
                    relativePath: "vendor/tool/.git", reason: .unresolvableGitAdministration, errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("a bare cache whose configuration includes cycle is one Git cannot open, so it is copied as content")
    func copiedGitDirectoryIncludeCycleIsOrdinaryContent() async throws {
        // Arrange: Git itself refuses this directory, so the fork must neither loop nor treat it as a repository.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-copied-cycle")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: "upstream"), file: "up.txt", fixture: fixture)
        let cache = fixture.source.appending(path: ".build/cache.git")
        try fixture.git.run(["clone", "-q", "--bare", upstream.path, cache.path])
        try "[include]\n\tpath = b.conf\n".write(
            to: cache.appending(path: "a.conf"), atomically: false, encoding: .utf8)
        try "[include]\n\tpath = a.conf\n".write(
            to: cache.appending(path: "b.conf"), atomically: false, encoding: .utf8)
        try fixture.git.run(["config", "--file", cache.appending(path: "config").path, "include.path", "a.conf"])
        #expect(!(try fixture.git.succeeds("rev-parse", "--git-dir", currentDirectory: cache)))
        let sourceConfiguration = try Data(contentsOf: cache.appending(path: "config"))
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        #expect(
            try Data(contentsOf: destination.appending(path: ".build/cache.git/config")) == sourceConfiguration)
    }

    @Test("a relative include that climbs out through the source directory's name reaches the destination copy")
    func relativeIncludeClimbingThroughSourceNameFollowsCopy() async throws {
        // Arrange: the Advisor's shape; a byte copy of this relative path would still reach the source file.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-climbing-include")
        defer { fixture.remove() }
        try ignore("dependency/", fixture: fixture)
        let dependency = try makeRepository(
            at: fixture.source.appending(path: "dependency"), file: "tracked.txt", fixture: fixture)
        let extra = dependency.appending(path: ".git/extra.conf")
        try "[agentstudio]\n\tmarker = relative-original\n".write(to: extra, atomically: false, encoding: .utf8)
        let climbing = "../../../\(fixture.source.lastPathComponent)/dependency/.git/extra.conf"
        try fixture.git.run(["config", "include.path", climbing], currentDirectory: dependency)
        #expect(try configValue("agentstudio.marker", at: dependency, fixture) == "relative-original")
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        try "[agentstudio]\n\tmarker = relative-changed-in-source\n"
            .write(to: extra, atomically: false, encoding: .utf8)

        // Assert
        let destinationDependency = destination.appending(path: "dependency")
        #expect(try configValue("agentstudio.marker", at: destinationDependency, fixture) == "relative-original")
        #expect(
            try configuredPath("include.path", at: destinationDependency, fixture)
                == canonical(destinationDependency.appending(path: ".git/extra.conf")).path)
    }

    @Test(
        "an active gitdir condition naming the nested .git stays active at its destination counterpart",
        arguments: ["gitdir:", "gitdir/i:"]
    )
    func gitDirectoryConditionFollowsDestinationAdministration(conditionPrefix: String) async throws {
        // Arrange: the Advisor's 509b-conditional-gitdir-exact shape.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-conditional")
        defer { fixture.remove() }
        try ignore("dependency/", fixture: fixture)
        let dependency = try makeRepository(
            at: fixture.source.appending(path: "dependency"), file: "tracked.txt", fixture: fixture)
        let administration = try canonical(dependency.appending(path: ".git"))
        let included = administration.appending(path: "conditional.conf")
        try "[agentstudio]\n\tmarker = conditional-active\n".write(to: included, atomically: false, encoding: .utf8)
        let configuration = administration.appending(path: "config")
        try fixture.git.run([
            "config", "--file", configuration.path,
            "includeIf.\(conditionPrefix)\(administration.path).path", included.path,
        ])
        #expect(try configValue("agentstudio.marker", at: dependency, fixture) == "conditional-active")
        let sourceConfiguration = try Data(contentsOf: configuration)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationDependency = destination.appending(path: "dependency")
        let destinationAdministration = try canonical(destinationDependency.appending(path: ".git"))
        #expect(try configValue("agentstudio.marker", at: destinationDependency, fixture) == "conditional-active")
        let conditional = try fixture.git.run(
            ["config", "--get-regexp", "^includeif\\."], currentDirectory: destinationDependency)
        #expect(
            conditional
                == "includeif.\(conditionPrefix)\(destinationAdministration.path).path "
                + "\(destinationAdministration.appending(path: "conditional.conf").path)\n")
        #expect(try Data(contentsOf: configuration) == sourceConfiguration)
    }

    @Test("a gitdir condition with a glob inside the source-owned part fails instead of guessing its counterpart")
    func gitDirectoryConditionGlobInSourcePartFails() async throws {
        // Arrange: `*` could match the nested repository, whose administration relocates on its own.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-conditional-glob")
        defer { fixture.remove() }
        try ignore("dependency/", fixture: fixture)
        let dependency = try makeRepository(
            at: fixture.source.appending(path: "dependency"), file: "tracked.txt", fixture: fixture)
        let administration = try canonical(dependency.appending(path: ".git"))
        let pattern = "\(try canonical(fixture.source).path)/*/.git"
        try fixture.git.run([
            "config", "--file", administration.appending(path: "config").path,
            "includeIf.gitdir:\(pattern).path", administration.appending(path: "conditional.conf").path,
        ])
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
                    relativePath: "dependency/.git/config: includeif.gitdir:*/.git.path",
                    reason: .unresolvableGitAdministration, errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test(
        "an included file's core.hooksPath into the linked source's private administration follows the fork",
        arguments: [IncludeForm.relative, .absolute]
    )
    func includedHooksPathIntoSourcePrivateAdministrationFollowsFork(form: IncludeForm) async throws {
        // Arrange: fork a linked worktree; its nested repository includes extra.conf, which includes deeper.conf
        // relatively, which points core.hooksPath into the linked source's private administration.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-config-include-private")
        defer { fixture.remove() }
        try ignore("vendor/", fixture: fixture)
        let linkedSource = fixture.repository.root.appending(path: "linked-source")
        try fixture.git.run("worktree", "add", "-q", "-b", "linked-source", linkedSource.path)
        let tool = try makeRepository(
            at: linkedSource.appending(path: "vendor/tool"), file: "tool.txt", fixture: fixture)
        let administration = try canonical(tool.appending(path: ".git"))
        let sourceHooks = try canonical(fixture.linkedWorktreeAdministration("linked-source")).appending(path: "hooks")
        let extra = administration.appending(path: "extra.conf")
        try "[include]\n\tpath = deeper.conf\n".write(to: extra, atomically: false, encoding: .utf8)
        try "[core]\n\thooksPath = \(sourceHooks.path)\n"
            .write(to: administration.appending(path: "deeper.conf"), atomically: false, encoding: .utf8)
        let includeValue = form == .relative ? "extra.conf" : extra.path
        try fixture.git.run(["config", "include.path", includeValue], currentDirectory: tool)
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
            try configValue("core.hooksPath", at: destination.appending(path: "vendor/tool"), fixture)
                == canonical(fixture.linkedWorktreeAdministration()).appending(path: "hooks").path)
    }

    private func ignoreVendorAndStorage(_ fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "vendor/\nlarge-file-store/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore vendor and storage")
        try fixture.write("large-file-store/objects/placeholder", "stored\n")
    }

    private func configValues(_ key: String, at worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> [String] {
        try fixture.git.run(["config", "--get-all", key], currentDirectory: worktree)
            .split(separator: "\n").map { try canonical(URL(fileURLWithPath: String($0))).path }
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

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

enum IncludeForm: String, CaseIterable, Sendable {
    case relative
    case absolute
}
