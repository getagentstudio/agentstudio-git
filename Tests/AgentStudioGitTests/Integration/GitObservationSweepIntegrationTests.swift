import AgentStudioGit
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

    private func statusReader(recording paths: OSAllocatedUnfairLock<[String]>) -> LibGit2StatusReader {
        LibGit2StatusReader(
            observationIdentityReader: LibGit2StatusObservationIdentityReader(
                worktreeAttributeProbe: recordingProbe(paths)))
    }

    private func recordingProbe(_ paths: OSAllocatedUnfairLock<[String]>) -> GitWorktreeAttributeProbe {
        GitWorktreeAttributeProbe { path in
            paths.withLock { $0.append(path) }
            return GitWorktreeAttributeProbe.live.isDirect(path)
        }
    }
}
