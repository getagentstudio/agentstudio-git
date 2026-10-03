import AgentStudioGit
import Foundation
import Testing

/// Relocating an `includeIf "gitdir:…"` condition must keep configuration semantics: the section stays where
/// it was, so values, their order, and last-wins precedence are the same in the destination as in the source.
@Suite("Git worktree fork include order integration", .serialized)
struct GitWorktreeForkIncludeOrderIntegrationTests {
    @Test(
        "relocating a gitdir condition keeps its section in place, so a later local override still wins",
        arguments: ["gitdir:", "gitdir/i:"]
    )
    func relocatedConditionKeepsPrecedence(conditionPrefix: String) async throws {
        // Arrange: the Advisor's shape; an active conditional include, then a later override of the same key.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-precedence")
        defer { fixture.remove() }
        try ignore("dependency/", fixture: fixture)
        let dependency = try makeRepository(
            at: fixture.source.appending(path: "dependency"), file: "tracked.txt", fixture: fixture)
        let administration = try canonical(dependency.appending(path: ".git"))
        let included = administration.appending(path: "conditional.conf")
        try "[agentstudio]\n\tmarker = included-value\n".write(to: included, atomically: false, encoding: .utf8)
        let configuration = administration.appending(path: "config")
        try fixture.git.run([
            "config", "--file", configuration.path, "includeIf.\(conditionPrefix)\(administration.path).path",
            included.path,
        ])
        try fixture.git.run(["config", "--file", configuration.path, "agentstudio.marker", "local-override"])
        #expect(try configValue("agentstudio.marker", at: dependency, fixture) == "local-override")
        let sourceBytes = try Data(contentsOf: configuration)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationDependency = destination.appending(path: "dependency")
        #expect(try configValue("agentstudio.marker", at: destinationDependency, fixture) == "local-override")
        #expect(
            try fixture.git.run(["config", "--get-all", "agentstudio.marker"], currentDirectory: destinationDependency)
                == "included-value\nlocal-override\n")
        #expect(try Data(contentsOf: configuration) == sourceBytes)
    }

    @Test("relocating a gitdir condition rewrites only its header, keeping several paths and their comments")
    func relocatedConditionKeepsSectionBody() async throws {
        // Arrange: a commented condition section with two relative includes, followed by a later override.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-section-body")
        defer { fixture.remove() }
        try ignore("dependency/", fixture: fixture)
        let dependency = try makeRepository(
            at: fixture.source.appending(path: "dependency"), file: "tracked.txt", fixture: fixture)
        let administration = try canonical(dependency.appending(path: ".git"))
        try "[agentstudio]\n\tmarker = one\n"
            .write(to: administration.appending(path: "one.conf"), atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tmarker = two\n"
            .write(to: administration.appending(path: "two.conf"), atomically: false, encoding: .utf8)
        let configuration = administration.appending(path: "config")
        let section =
            "# conditional settings for this checkout\n[includeIf \"gitdir:\(administration.path)\"]\n"
            + "\t# first include\n\tpath = one.conf\n\tpath = two.conf ; second include\n"
            + "[agentstudio]\n\tmarker = local-override\n"
        let handle = try FileHandle(forWritingTo: configuration)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(section.utf8))
        try handle.close()
        let sourceText = try String(contentsOf: configuration, encoding: .utf8)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationDependency = destination.appending(path: "dependency")
        let destinationAdministration = try canonical(destinationDependency.appending(path: ".git"))
        #expect(
            try String(contentsOf: destinationAdministration.appending(path: "config"), encoding: .utf8)
                == sourceText.replacingOccurrences(
                    of: "[includeIf \"gitdir:\(administration.path)\"]",
                    with: "[includeIf \"gitdir:\(destinationAdministration.path)\"]"))
        #expect(
            try fixture.git.run(["config", "--get-all", "agentstudio.marker"], currentDirectory: destinationDependency)
                == "one\ntwo\nlocal-override\n")
        #expect(try String(contentsOf: configuration, encoding: .utf8) == sourceText)
    }

    @Test(
        "repeated relocated gitdir sections interleaved with overrides keep the same values in the same order",
        arguments: ["gitdir:", "gitdir/i:"]
    )
    func repeatedRelocatedSectionsKeepOrder(conditionPrefix: String) async throws {
        // Arrange: the same condition appears twice, each time with includes, between two plain overrides.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-include-repeated")
        defer { fixture.remove() }
        try ignore("dependency/", fixture: fixture)
        let dependency = try makeRepository(
            at: fixture.source.appending(path: "dependency"), file: "tracked.txt", fixture: fixture)
        let administration = try canonical(dependency.appending(path: ".git"))
        for name in ["one", "two", "three"] {
            try "[agentstudio]\n\tmarker = \(name)\n"
                .write(to: administration.appending(path: "\(name).conf"), atomically: false, encoding: .utf8)
        }
        let configuration = administration.appending(path: "config")
        let header = "[includeIf \"\(conditionPrefix)\(administration.path)\"]"
        let sections =
            "\(header)\n\tpath = one.conf\n\tpath = two.conf\n[agentstudio]\n\tmarker = middle\n"
            + "\(header)\n\tpath = three.conf\n[agentstudio]\n\tmarker = local-override\n"
        let handle = try FileHandle(forWritingTo: configuration)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(sections.utf8))
        try handle.close()
        let sourceMarkers = try fixture.git.run(
            ["config", "--get-all", "agentstudio.marker"], currentDirectory: dependency)
        #expect(sourceMarkers == "one\ntwo\nmiddle\nthree\nlocal-override\n")
        let sourceBytes = try Data(contentsOf: configuration)
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationDependency = destination.appending(path: "dependency")
        #expect(
            try fixture.git.run(["config", "--get-all", "agentstudio.marker"], currentDirectory: destinationDependency)
                == sourceMarkers)
        #expect(try configValue("agentstudio.marker", at: destinationDependency, fixture) == "local-override")
        #expect(try Data(contentsOf: configuration) == sourceBytes)
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
