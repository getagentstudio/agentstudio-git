import AgentStudioGit
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree changes-only fork integration", .serialized)
struct GitWorktreeForkChangesOnlyIntegrationTests {
    @Test("a changes-only fork overlays source files onto captured HEAD and rebuilds a clean index")
    func forkOverlaysCarriedFilesAndLeavesIndexAtHead() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-changes-only")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "ignored.log\nnested/ignored.txt\ntracked-ignored.txt\n")
        try fixture.write("tracked.txt", "base\n")
        try fixture.write("delete-recreate.txt", "base delete\n")
        try fixture.write("tracked-ignored.txt", "base ignored tracked\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("add", "-f", "tracked-ignored.txt")
        try fixture.git.run("commit", "-m", "changes-only baseline")
        try fixture.write("tracked.txt", "staged version\n")
        try fixture.git.run("add", "tracked.txt")
        try fixture.write("tracked.txt", "final worktree version\n")
        try fixture.git.run("rm", "-q", "delete-recreate.txt")
        try fixture.write("delete-recreate.txt", "recreated after staged deletion\n")
        try fixture.write("staged-new-then-deleted.txt", "temporary\n")
        try fixture.git.run("add", "staged-new-then-deleted.txt")
        try FileManager.default.removeItem(at: fixture.source.appending(path: "staged-new-then-deleted.txt"))
        try fixture.write("untracked/nested.txt", "untracked payload\n")
        try fixture.write("ignored.log", "ignored payload\n")
        try fixture.write("nested/ignored.txt", "nested ignored payload\n")
        try fixture.write("tracked-ignored.txt", "changed but tracked\n")
        let infoExclude = fixture.source.appending(path: ".git/info/exclude")
        let priorInfoExclude = (try String(contentsOf: infoExclude, encoding: .utf8))
        try (priorInfoExclude + "ignored-info.txt\n").write(to: infoExclude, atomically: true, encoding: .utf8)
        let globalExclude = fixture.source.appending(path: ".git/global-ignore")
        try "ignored-global.txt\n".write(to: globalExclude, atomically: true, encoding: .utf8)
        try fixture.git.run(["config", "core.excludesFile", globalExclude.path])
        try fixture.write("ignored-info.txt", "local exclude\n")
        try fixture.write("ignored-global.txt", "global exclude\n")
        let sourceStatus = try fixture.statusLines(at: fixture.source)
        let head = try fixture.blobID("HEAD", at: fixture.source)
        let destination = fixture.destination()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: fixture.source,
            destinationPath: destination,
            mode: .newBranch(name: "fork-changes-only", start: .sourceHead, upstream: nil),
            materialization: .changesOnly,
            copyRules: GitWorktreeCopyRules(ignoredPaths: .copyAll)
        )

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)

        // Assert
        #expect(try fixture.blobID("HEAD", at: destination) == head)
        #expect(
            try String(contentsOf: destination.appending(path: "tracked.txt"), encoding: .utf8)
                == "final worktree version\n")
        #expect(
            try String(contentsOf: destination.appending(path: "delete-recreate.txt"), encoding: .utf8)
                == "recreated after staged deletion\n")
        #expect(
            try String(contentsOf: destination.appending(path: "untracked/nested.txt"), encoding: .utf8)
                == "untracked payload\n")
        #expect(
            try String(contentsOf: destination.appending(path: "tracked-ignored.txt"), encoding: .utf8)
                == "changed but tracked\n")
        #expect(
            !FileManager.default.fileExists(atPath: destination.appending(path: "staged-new-then-deleted.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "ignored.log").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "nested/ignored.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "ignored-info.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "ignored-global.txt").path))
        #expect(try fixture.git.succeeds("diff", "--cached", "--quiet", currentDirectory: destination))
        #expect(try fixture.statusLines(at: fixture.source) == sourceStatus)
        guard case .changesOnly(let report) = result.materialization else {
            Issue.record("expected changes-only materialization, got \(String(describing: result.materialization))")
            return
        }
        #expect(report.ignoredExcluded)
        #expect(report.trackedChanges == 3)
        #expect(report.untrackedFiles == 1)
    }

    @Test("changes-only materialization never invokes the APFS clone worker")
    func changesOnlyDoesNotUseCloneWorker() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-no-clone")
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "changed\n")
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            if case .beforeRegularFileClone = point {
                throw .entryFailed(relativePath: "tracked.txt", reason: .strictCloneFailed, errorNumber: nil)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let result = try await client.forkWorktree(
            fixture.request(materialization: .changesOnly))

        // Assert
        guard case .changesOnly = result.materialization else {
            Issue.record("expected changes-only materialization")
            return
        }
        #expect(
            try String(contentsOf: fixture.destination().appending(path: "tracked.txt"), encoding: .utf8)
                == "changed\n")
    }

    @Test("renames, file-directory replacements, symlinks, and executable mode are overlaid")
    func changesOnlyPreservesPathKindsAndModes() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-types")
        defer { fixture.remove() }
        try fixture.write("move.txt", "move me\n")
        try fixture.write("node", "replace with directory\n")
        try fixture.write("folder/child.txt", "replace directory with file\n")
        try fixture.write("swap.txt", "replace with symbolic link\n")
        try fixture.write("tool", "run me\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "path kind baseline")
        try fixture.git.run("mv", "move.txt", "moved-once.txt")
        try fixture.git.run("mv", "moved-once.txt", "moved-final.txt")
        try FileManager.default.removeItem(at: fixture.source.appending(path: "node"))
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "node"), withIntermediateDirectories: true)
        try fixture.write("node/new.txt", "new child\n")
        try FileManager.default.removeItem(at: fixture.source.appending(path: "folder"))
        try fixture.write("folder", "now a file\n")
        try FileManager.default.removeItem(at: fixture.source.appending(path: "swap.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: fixture.source.appending(path: "swap.txt").path,
            withDestinationPath: "moved-final.txt"
        )
        #expect(chmod(fixture.source.appending(path: "tool").path, 0o755) == 0)
        #expect(
            (try #require(GitWorktreeForkFileProbe.info(fixture.source.appending(path: "node")))).st_mode & S_IFMT
                == S_IFDIR)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(materialization: .changesOnly))

        // Assert
        let destination = fixture.destination()
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "move.txt").path))
        #expect(try String(contentsOf: destination.appending(path: "moved-final.txt"), encoding: .utf8) == "move me\n")
        #expect(try String(contentsOf: destination.appending(path: "node/new.txt"), encoding: .utf8) == "new child\n")
        #expect(try String(contentsOf: destination.appending(path: "folder"), encoding: .utf8) == "now a file\n")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "swap.txt").path)
                == "moved-final.txt")
        let toolInfo = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: "tool")))
        #expect(toolInfo.st_mode & S_IXUSR != 0)
        #expect(try fixture.git.succeeds("diff", "--cached", "--quiet", currentDirectory: destination))
    }

    @Test("same-size source edits after capture are detected and rolled back")
    func sameSizeSourceEditAfterCaptureIsDetected() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-content-race")
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "base\n")
        try fixture.git.run("add", "tracked.txt")
        try fixture.git.run("commit", "-m", "content race baseline")
        try fixture.write("tracked.txt", "version A\n")
        let sourceFile = fixture.source.appending(path: "tracked.txt")
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterChangesOnlyCapture,
                let handle = try? FileHandle(forWritingTo: sourceFile)
            else {
                return
            }
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: Data("version B\n".utf8))
            try? handle.close()
        }
        let destination = fixture.destination()
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(destination: destination, materialization: .changesOnly))
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        switch failure {
        case .sourceChanged(relativePath: "tracked.txt", reason: .contentChanged):
            break
        case .cleanupIncomplete(primary: .sourceChanged(relativePath: "tracked.txt", reason: .contentChanged), _):
            break
        default:
            Issue.record("expected contentChanged source refusal, got \(String(describing: failure))")
        }
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("failures after registration, checkout, overlay, and validation remove transaction state")
    func failuresAtChangesOnlyPhasesRollBack() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-changes-rollback")
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "base\n")
        try fixture.git.run("add", "tracked.txt")
        try fixture.git.run("commit", "-m", "rollback baseline")
        try fixture.write("tracked.txt", "changed\n")
        let failurePoints: [WorktreeForkFaultPoint] = [
            .afterWorktreeAdded,
            .afterHeadCheckedOut,
            .afterChangesOnlyOverlay,
            .afterValidation,
        ]

        for (index, failurePoint) in failurePoints.enumerated() {
            let name = "changes-rollback-\(index)"
            let destination = fixture.destination(name)
            let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
                if point == failurePoint {
                    throw .entryFailed(relativePath: ".", reason: .entryCreationFailed, errorNumber: nil)
                }
            }
            let phaseClient = LibGit2AgentStudioGitLocalClient(
                worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

            // Act
            let failure: GitWorktreeForkError?
            do {
                _ = try await phaseClient.forkWorktree(
                    fixture.request(
                        destination: destination, mode: .newBranch(name: name, start: .sourceHead, upstream: nil),
                        materialization: .changesOnly))
                failure = nil
            } catch {
                failure = error
            }

            // Assert
            #expect(failure != nil)
            #expect(!GitWorktreeForkFileProbe.exists(destination))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(name)))
            #expect(try fixture.branchNames() == ["refs/heads/main"])
        }
    }

    @Test("cancellation after the clean checkout rolls back before returning")
    func cancellationAfterCheckoutRollsBack() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-changes-cancel")
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "base\n")
        try fixture.git.run("add", "tracked.txt")
        try fixture.git.run("commit", "-m", "cancellation baseline")
        try fixture.write("tracked.txt", "changed\n")
        let (events, continuation) = AsyncStream.makeStream(of: Bool.self)
        var eventIterator = events.makeAsyncIterator()
        let releaseCheckout = DispatchSemaphore(value: 0)
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            if point == .afterHeadCheckedOut {
                continuation.yield(true)
                releaseCheckout.wait()
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))
        let destination = fixture.destination()

        // Act
        let fork = Task { () -> GitWorktreeForkError? in
            do throws(GitWorktreeForkError) {
                _ = try await client.forkWorktree(
                    fixture.request(destination: destination, materialization: .changesOnly))
                return nil
            } catch {
                return error
            }
        }
        #expect(await eventIterator.next() == true)
        fork.cancel()
        releaseCheckout.signal()
        let failure = await fork.value
        continuation.finish()

        // Assert
        #expect(failure == .cancelled)
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("HEAD and index moves after capture refuse with repositoryStateChanged")
    func repositoryStateMovesAfterCaptureAreDetected() async throws {
        for (name, command) in [
            ("head-race", ["update-ref", "refs/heads/main", "HEAD~1"]),
            ("index-race", ["add", "tracked.txt"]),
        ] {
            // Arrange
            let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-\(name)")
            defer { fixture.remove() }
            try fixture.write("tracked.txt", "first commit\n")
            try fixture.git.run("add", "tracked.txt")
            try fixture.git.run("commit", "-m", "first state")
            try fixture.write("tracked.txt", "second commit\n")
            try fixture.git.run("add", "tracked.txt")
            try fixture.git.run("commit", "-m", "second state")
            try fixture.write("tracked.txt", "captured working change\n")
            let sourceRoot = fixture.source
            let destination = fixture.destination(name)
            let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
                guard point == .afterChangesOnlyCapture else {
                    return
                }
                _ = try? GitProcess(repositoryPath: sourceRoot).run(command)
            }
            let client = LibGit2AgentStudioGitLocalClient(
                worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

            // Act
            let failure: GitWorktreeForkError?
            do {
                _ = try await client.forkWorktree(
                    fixture.request(
                        destination: destination, mode: .newBranch(name: name, start: .sourceHead, upstream: nil),
                        materialization: .changesOnly))
                failure = nil
            } catch {
                failure = error
            }

            // Assert
            #expect(failure == .sourceChanged(relativePath: ".", reason: .repositoryStateChanged))
            #expect(!GitWorktreeForkFileProbe.exists(destination))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(name)))
            #expect(try fixture.branchNames().allSatisfy { $0 == "refs/heads/main" })
        }
    }

    @Test("a symlink swap in a carried path ancestor is contained and rolled back")
    func symlinkAncestorSwapIsContained() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-symlink-race")
        defer { fixture.remove() }
        try fixture.write("nested/tracked.txt", "base\n")
        try fixture.git.run("add", "nested/tracked.txt")
        try fixture.git.run("commit", "-m", "symlink race baseline")
        try fixture.write("nested/tracked.txt", "captured change\n")
        let sourceRoot = fixture.source
        let parkedDirectory = fixture.source.appending(path: "nested-parked")
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterChangesOnlyCapture else {
                return
            }
            try? FileManager.default.moveItem(
                at: sourceRoot.appending(path: "nested"), to: parkedDirectory)
            try? FileManager.default.createSymbolicLink(
                atPath: sourceRoot.appending(path: "nested").path, withDestinationPath: "/private/tmp")
        }
        let destination = fixture.destination()
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(destination: destination, materialization: .changesOnly))
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        switch failure {
        case .sourceChanged(relativePath: "nested/tracked.txt", reason: .containmentEscape),
            .sourceChanged(relativePath: "nested", reason: .containmentEscape):
            break
        case .cleanupIncomplete(primary: .sourceChanged(_, reason: .containmentEscape), _):
            break
        default:
            Issue.record("expected a contained sourceChanged refusal, got \(String(describing: failure))")
        }
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("conflicts, active operations, index flags, nested repositories, and special nodes refuse before mutation")
    func unsupportedGitAndFilesystemStatesRefuseBeforeMutation() async throws {
        let scenarios: [(String, GitWorktreeWorkingStateRefusalReason, String?)] = [
            ("conflicts", .conflicts, "conflict.txt"),
            ("operation", .operationInProgress, nil),
            ("intent", .intentToAdd, "new.txt"),
            ("skip-worktree", .sparseOrSkipWorktree, "README.md"),
            ("assume-unchanged", .sparseOrSkipWorktree, "README.md"),
            ("nested-repo", .nestedRepository, "nested-repo"),
            ("fifo", .unsupportedEntryKind, "events.fifo"),
        ]

        for (scenario, expectedReason, expectedPath) in scenarios {
            // Arrange
            let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-refusal-\(scenario)")
            defer { fixture.remove() }
            switch scenario {
            case "conflicts":
                try fixture.write("conflict.txt", "base\n")
                try fixture.git.run("add", "conflict.txt")
                try fixture.git.run("commit", "-m", "conflict baseline")
                try fixture.git.run("branch", "side")
                try fixture.git.run("checkout", "-q", "side")
                try fixture.write("conflict.txt", "side\n")
                try fixture.git.run("add", "conflict.txt")
                try fixture.git.run("commit", "-m", "side change")
                try fixture.git.run("checkout", "-q", "main")
                try fixture.write("conflict.txt", "main\n")
                try fixture.git.run("add", "conflict.txt")
                try fixture.git.run("commit", "-m", "main change")
                // The merge intentionally leaves unmerged index stages in this disposable repository.
                // The fixture's Git helper reports the nonzero exit without changing this process.
                _ = try fixture.git.succeeds("merge", "side")
            case "operation":
                try fixture.write("first.txt", "base\n")
                try fixture.git.run("add", "first.txt")
                try fixture.git.run("commit", "-m", "operation baseline")
                try fixture.git.run("branch", "side")
                try fixture.git.run("checkout", "-q", "side")
                try fixture.write("side.txt", "side\n")
                try fixture.git.run("add", "side.txt")
                try fixture.git.run("commit", "-m", "side change")
                try fixture.git.run("checkout", "-q", "main")
                try fixture.write("main.txt", "main\n")
                try fixture.git.run("add", "main.txt")
                try fixture.git.run("commit", "-m", "main change")
                try fixture.git.run("merge", "--no-commit", "side")
            case "intent":
                try fixture.write("new.txt", "intent to add\n")
                try fixture.git.run("add", "-N", "new.txt")
            case "skip-worktree":
                try fixture.git.run("update-index", "--skip-worktree", "README.md")
            case "assume-unchanged":
                try fixture.git.run("update-index", "--assume-unchanged", "README.md")
            case "nested-repo":
                let nestedRoot = fixture.source.appending(path: "nested-repo")
                try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
                let nestedGit = GitProcess(repositoryPath: nestedRoot)
                try nestedGit.run("init")
                try fixture.write("README.md", "nested content\n", in: nestedRoot)
                try nestedGit.run("add", "README.md")
                try nestedGit.run("commit", "-m", "nested repository")
            case "fifo":
                try fixture.write("events.fifo", "tracked baseline\n")
                try fixture.git.run("add", "events.fifo")
                try fixture.git.run("commit", "-m", "fifo replacement baseline")
                try FileManager.default.removeItem(at: fixture.source.appending(path: "events.fifo"))
                #expect(mkfifo(fixture.source.appending(path: "events.fifo").path, 0o600) == 0)
            default:
                Issue.record("unexpected refusal scenario \(scenario)")
                continue
            }
            let destination = fixture.destination()
            let branchesBefore = try fixture.branchNames()
            // Act
            let failure = await forkFailure(
                fixture.request(destination: destination, materialization: .changesOnly))

            // Assert
            #expect(
                failure
                    == .workingStateUnsupported(
                        GitWorktreeWorkingStateRefusal(reason: expectedReason, relativePath: expectedPath)),
                "\(scenario): \(String(describing: failure))"
            )
            #expect(!GitWorktreeForkFileProbe.exists(destination))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
            #expect(try fixture.branchNames() == branchesBefore)
        }
    }

    @Test("a dirty submodule is refused before creating the destination")
    func dirtySubmoduleRefusesBeforeMutation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-dirty-submodule")
        defer { fixture.remove() }
        let moduleRoot = fixture.repository.root.appending(path: "module-source")
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        let moduleGit = GitProcess(repositoryPath: moduleRoot)
        try moduleGit.run("init")
        try fixture.write("README.md", "module base\n", in: moduleRoot)
        try moduleGit.run("add", "README.md")
        try moduleGit.run("commit", "-m", "module baseline")
        try fixture.git.run(["submodule", "add", "-q", moduleRoot.path, "deps/module"])
        try fixture.git.run("commit", "-m", "add submodule")
        let submodulePath = fixture.source.appending(path: "deps/module")
        try fixture.write("README.md", "dirty module\n", in: submodulePath)
        let destination = fixture.destination()
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure = await forkFailure(
            fixture.request(destination: destination, materialization: .changesOnly))

        // Assert
        #expect(
            failure
                == .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(reason: .submoduleChanged, relativePath: "deps/module")))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("an unchanged submodule stays uninitialized in the changes-only checkout")
    func unchangedSubmoduleRemainsUninitialized() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-uninitialized-submodule")
        defer { fixture.remove() }
        let moduleRoot = fixture.repository.root.appending(path: "module-source")
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        let moduleGit = GitProcess(repositoryPath: moduleRoot)
        try moduleGit.run("init")
        try fixture.write("README.md", "module content\n", in: moduleRoot)
        try moduleGit.run("add", "README.md")
        try moduleGit.run("commit", "-m", "module baseline")
        try fixture.git.run(["submodule", "add", "-q", moduleRoot.path, "deps/module"])
        try fixture.git.run("commit", "-m", "add unchanged submodule")
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(destination: destination, materialization: .changesOnly))

        // Assert
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "deps/module/.git")))
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "deps/module/README.md")))
        #expect(try fixture.git.succeeds("diff", "--cached", "--quiet", currentDirectory: destination))
        #expect(try fixture.statusLines(at: fixture.source).isEmpty)
    }

    private func forkFailure(_ request: GitForkWorktreeRequest) async -> GitWorktreeForkError? {
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }
}
