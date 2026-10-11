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
        let sdk = AgentStudioGitSDK(local: client, remote: SystemGitRemoteClient())

        // Act
        let included = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: false))
        let excluded = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: true))
        let excludedFacts = try await client.statusFacts(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: true))
        let standaloneIncluded = try await sdk.local.exactLineCountDetail(
            for: parent.repositoryPath, excludeSubmodules: false)
        let standaloneExcluded = try await sdk.local.exactLineCountDetail(
            for: parent.repositoryPath, excludeSubmodules: true)
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
        #expect(standaloneIncluded.linesAdded == included.lineCountDetail.linesAdded)
        #expect(standaloneIncluded.linesDeleted == included.lineCountDetail.linesDeleted)
        #expect(standaloneExcluded.linesAdded == 1)
        #expect(standaloneExcluded.linesDeleted == 0)

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

    enum SubmoduleChange: CaseIterable {
        case added
        case deleted
        case renamed
    }

    @Test("submodule additions deletions and renames exclude gitlink lines", arguments: SubmoduleChange.allCases)
    func structuralSubmoduleChangesExcludeGitlinkLines(change: SubmoduleChange) async throws {
        // Arrange
        let parent = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-submodule-structure")
        defer { parent.remove() }
        let child = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-submodule-source")
        defer { child.remove() }
        try parent.git.run("submodule", "add", child.repositoryPath.path, "Vendor/Child")
        switch change {
        case .added:
            break
        case .deleted:
            try parent.git.run("commit", "-am", "seed submodule")
            try parent.git.run("rm", "Vendor/Child")
        case .renamed:
            try parent.git.run("commit", "-am", "seed submodule")
            try parent.git.run("mv", "Vendor/Child", "Vendor/Renamed")
        }
        try parent.write("README.md", contents: "hello\nparent edit\n")
        let client = LibGit2AgentStudioGitLocalClient()
        let sdk = AgentStudioGitSDK(local: client, remote: SystemGitRemoteClient())

        // Act
        let included = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: false))
        let excluded = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: true))
        let standaloneIncluded = try await sdk.local.exactLineCountDetail(
            for: parent.repositoryPath, excludeSubmodules: false)
        let standaloneExcluded = try await sdk.local.exactLineCountDetail(
            for: parent.repositoryPath, excludeSubmodules: true)
        // The status line-count diff does not pair renames, so the CLI oracle uses the same semantics.
        let fullNumstat = try parent.git.run(
            "diff", "--no-renames", "--numstat", "--ignore-submodules=none", "HEAD", "--")
        let parentNumstat = try parent.git.run(
            "diff", "--no-renames", "--numstat", "HEAD", "--", "README.md", ".gitmodules")
        let fullCounts = try lineCounts(from: fullNumstat)
        let parentCounts = try lineCounts(from: parentNumstat)

        // Assert
        #expect(included.lineCountDetail.linesAdded == fullCounts.additions)
        #expect(included.lineCountDetail.linesDeleted == fullCounts.deletions)
        #expect(standaloneIncluded.linesAdded == fullCounts.additions)
        #expect(standaloneIncluded.linesDeleted == fullCounts.deletions)
        #expect(standaloneExcluded.linesAdded == parentCounts.additions)
        #expect(standaloneExcluded.linesDeleted == parentCounts.deletions)
        #expect(fullCounts.additions + fullCounts.deletions > parentCounts.additions + parentCounts.deletions)
        #expect(excluded.facts.entries.map(\.path) == [".gitmodules", "README.md"])
        #expect(excluded.lineCountDetail.linesAdded == parentCounts.additions)
        #expect(excluded.lineCountDetail.linesDeleted == parentCounts.deletions)
    }

    enum ParentFileKind: CaseIterable {
        case regularFile
        case symbolicLink

        var lineCount: Int { self == .regularFile ? 2 : 1 }
    }

    @Test(
        "submodule type transitions retain only the non-gitlink side's lines",
        arguments: [false, true], ParentFileKind.allCases
    )
    func submoduleTypeTransitionsRetainParentContent(startsAsSubmodule: Bool, fileKind: ParentFileKind) async throws {
        // Arrange
        let parent = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-submodule-type")
        defer { parent.remove() }
        let child = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-submodule-type-source")
        defer { child.remove() }
        if startsAsSubmodule {
            try parent.git.run("submodule", "add", child.repositoryPath.path, "Vendor/Child")
        } else {
            try writeParentFile(fileKind, in: parent)
            try parent.git.run("add", "Vendor/Child")
        }
        try parent.git.run("commit", "-m", "seed transition source")
        try parent.git.run("rm", "Vendor/Child")
        if startsAsSubmodule {
            try writeParentFile(fileKind, in: parent)
            try parent.git.run("add", "Vendor/Child")
        } else {
            try parent.git.run("submodule", "add", child.repositoryPath.path, "Vendor/Child")
        }
        try parent.write("README.md", contents: "hello\nparent edit\n")
        let client = LibGit2AgentStudioGitLocalClient()
        let sdk = AgentStudioGitSDK(local: client, remote: SystemGitRemoteClient())

        // Act
        let included = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: false))
        let excluded = try await client.completeStatus(
            for: parent.repositoryPath, options: GitStatusOptions(excludeSubmodules: true))
        let standaloneIncluded = try await sdk.local.exactLineCountDetail(
            for: parent.repositoryPath, excludeSubmodules: false)
        let standaloneExcluded = try await sdk.local.exactLineCountDetail(
            for: parent.repositoryPath, excludeSubmodules: true)
        let fullNumstat = try parent.git.run(
            "diff", "--no-renames", "--numstat", "--ignore-submodules=none", "HEAD", "--")
        let parentNumstat = try parent.git.run(
            "diff", "--no-renames", "--numstat", "HEAD", "--", "README.md", ".gitmodules")
        let fullCounts = try lineCounts(from: fullNumstat)
        let parentCounts = try lineCounts(from: parentNumstat)

        // Assert
        #expect(included.lineCountDetail.linesAdded == fullCounts.additions)
        #expect(included.lineCountDetail.linesDeleted == fullCounts.deletions)
        #expect(standaloneIncluded.linesAdded == fullCounts.additions)
        #expect(standaloneIncluded.linesDeleted == fullCounts.deletions)
        #expect(
            standaloneExcluded.linesAdded == parentCounts.additions + (startsAsSubmodule ? fileKind.lineCount : 0))
        #expect(
            standaloneExcluded.linesDeleted == parentCounts.deletions + (startsAsSubmodule ? 0 : fileKind.lineCount))
        #expect(excluded.facts.entries.map(\.path) == [".gitmodules", "README.md", "Vendor/Child"])
        #expect(excluded.facts.entries.first { $0.path == "Vendor/Child" }?.indexState == .typeChanged)
        #expect(
            excluded.lineCountDetail.linesAdded == parentCounts.additions + (startsAsSubmodule ? fileKind.lineCount : 0)
        )
        #expect(
            excluded.lineCountDetail.linesDeleted == parentCounts.deletions
                + (startsAsSubmodule ? 0 : fileKind.lineCount))
    }

    private func writeParentFile(_ kind: ParentFileKind, in parent: GitFixtureRepository) throws {
        switch kind {
        case .regularFile:
            try parent.write("Vendor/Child", contents: "parent content\nsecond line\n")
        case .symbolicLink:
            let path = parent.repositoryPath.appending(path: "Vendor/Child")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "../README.md")
        }
    }

    private func lineCounts(from numstat: String) throws -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in numstat.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            try #require(columns.count >= 3)
            additions += try #require(Int(columns[0]))
            deletions += try #require(Int(columns[1]))
        }
        return (additions, deletions)
    }
}
