import AgentStudioGit
import Foundation
import Testing

/// Real-target smoke for copy-on-write forks. Synthetic fixtures don't carry real build-output quirks
/// (read-only SwiftPM checkouts, nested repositories, LFS objects). Only a real built checkout does, so
/// this forks one, checks the result, then removes the fork and its branch. It's excluded from
/// `mise run test`. Run it with `AGENTSTUDIO_GIT_FORK_REAL_SOURCE=<absolute path of a clean checkout>`.
@Suite(
    "Git worktree fork real-checkout smoke",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_FORK_REAL_SOURCE"] != nil)
)
struct GitWorktreeForkRealCheckoutSmokeTests {
    @Test("a real built checkout forks copy-on-write, keeps nested repositories, and is cleaned up")
    func realCheckoutForks() async throws {
        // Arrange
        let sourcePath = try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_FORK_REAL_SOURCE"])
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let branch = "agentstudio-fork-smoke-\(suffix)"
        let destination = source.deletingLastPathComponent().appending(path: "\(source.lastPathComponent).\(branch)")
        let git = GitProcess(repositoryPath: source)
        defer { removeFork(at: destination, branch: branch, source: source, git: git) }

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            GitForkWorktreeRequest(
                sourceWorktreePath: source,
                destinationPath: destination,
                mode: .newBranch(name: branch),
                materialization: .copyOnWrite
            ))

        // Assert
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(report.skippedEntries.isEmpty, "skipped: \(report.skippedEntries)")
        let sourceHead = try git.run(["rev-parse", "HEAD"], currentDirectory: source)
        let destinationHead = try git.run(["rev-parse", "HEAD"], currentDirectory: destination)
        #expect(destinationHead == sourceHead)
        #expect(
            try git.run(["branch", "--show-current"], currentDirectory: destination)
                .trimmingCharacters(in: .whitespacesAndNewlines) == branch)
        let sourceStatus = try git.run(["status", "--porcelain"], currentDirectory: source)
        let destinationStatus = try git.run(["status", "--porcelain"], currentDirectory: destination)
        #expect(destinationStatus == sourceStatus, "destination status differs from source")
        print(
            "real-checkout fork: preservedGitRepositories=\(report.preservedGitRepositoryCount) "
                + "clonedFiles=\(report.clonedRegularFileCount) bytes=\(report.logicalRegularFileBytes) "
                + "normalized=\(report.normalizedEntries.count)")
    }

    /// Removes the fork and its branch, records every step that fails, then proves both are gone, so a
    /// green run means the real checkout was left as it was found. A failed fork may have rolled back
    /// already, so each step runs only when its target still exists.
    private func removeFork(at destination: URL, branch: String, source: URL, git: GitProcess) {
        if GitWorktreeForkFileProbe.exists(destination) {
            do {
                try git.run(["worktree", "remove", "--force", destination.path], currentDirectory: source)
            } catch {
                Issue.record("could not remove fork worktree \(destination.path): \(error)")
            }
        }
        if branchExists(branch, source: source, git: git) {
            do {
                try git.run(["branch", "-D", branch], currentDirectory: source)
            } catch {
                Issue.record("could not delete fork branch \(branch): \(error)")
            }
        }
        #expect(!GitWorktreeForkFileProbe.exists(destination), "fork worktree remains at \(destination.path)")
        #expect(!branchExists(branch, source: source, git: git), "fork branch \(branch) remains")
    }

    private func branchExists(_ branch: String, source: URL, git: GitProcess) -> Bool {
        do {
            return try git.succeeds("show-ref", "--verify", "--quiet", "refs/heads/\(branch)", currentDirectory: source)
        } catch {
            Issue.record("could not query fork branch \(branch): \(error)")
            return true
        }
    }
}
