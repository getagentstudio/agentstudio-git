import AgentStudioGit
import Foundation
import Testing

@Suite("Git status submodule integration", .serialized)
struct GitStatusSubmoduleIntegrationTests {
    @Test("exclusion skips dirty moved submodules while retaining parent edits", arguments: [false, true])
    func exclusionPreservesParentEdits(stageSubmoduleHead: Bool) async throws {
        // Arrange
        let parent = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-submodule")
        defer { parent.remove() }
        let child = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-submodule-child")
        defer { child.remove() }
        try parent.git.run("submodule", "add", child.repositoryPath.path, "Vendor/Child")
        try parent.git.run("commit", "-am", "add submodule")
        let submodulePath = parent.repositoryPath.appending(path: "Vendor/Child")
        try parent.write("README.md", contents: "hello\ncommitted child edit\n", in: submodulePath)
        try parent.git.run("commit", "-am", "move submodule head", currentDirectory: submodulePath)
        if stageSubmoduleHead {
            try parent.git.run("add", "Vendor/Child")
        }
        try parent.write("README.md", contents: "hello\ncommitted child edit\ndirty child edit\n", in: submodulePath)
        try parent.write("README.md", contents: "hello\nparent edit\n")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let included = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: false))
        let excluded = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: true))
        let excludedFacts = try await client.statusFacts(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: true))
        let standaloneDetail = try await client.exactLineCountDetail(for: parent.repositoryPath)
        let includedNumstat = try parent.git.run("diff", "--numstat", "--ignore-submodules=none", "HEAD", "--")
        let excludedNumstat = try parent.git.run("diff", "--numstat", "--ignore-submodules=all", "HEAD", "--")

        // Assert
        #expect(included.facts.entries.map(\.path) == ["README.md", "Vendor/Child"])
        let submoduleEntry = try #require(included.facts.entries.first { $0.path == "Vendor/Child" })
        #expect(submoduleEntry.indexState == (stageSubmoduleHead ? .modified : nil))
        #expect(submoduleEntry.worktreeState == .modified)
        #expect(includedNumstat == "1\t0\tREADME.md\n1\t1\tVendor/Child\n")
        #expect(included.lineCountDetail.linesAdded == 2)
        #expect(included.lineCountDetail.linesDeleted == 1)
        #expect(standaloneDetail.linesAdded == included.lineCountDetail.linesAdded)
        #expect(standaloneDetail.linesDeleted == included.lineCountDetail.linesDeleted)

        #expect(excluded.facts.entries.map(\.path) == ["README.md"])
        #expect(excluded.facts.entries.first?.worktreeState == .modified)
        #expect(excluded.facts.summary.changedFileCount == 1)
        #expect(excluded.facts.summary.stagedFileCount == 0)
        #expect(excluded.facts.summary.unstagedFileCount == 1)
        #expect(excludedFacts.facts.entries == excluded.facts.entries)
        #expect(excludedNumstat == "1\t0\tREADME.md\n")
        #expect(excluded.lineCountDetail.linesAdded == 1)
        #expect(excluded.lineCountDetail.linesDeleted == 0)
    }
}
