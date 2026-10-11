import Dispatch
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("libgit2 blocking read executor", .serialized)
struct LibGit2BlockingReadExecutorTests {
    @Test("blocking reads leave the main actor")
    func blockingReadsLeaveTheMainActor() async {
        let executor = LibGit2BlockingReadExecutor.shared
        let callerRanOnMainThread = await MainActor.run {
            Thread.isMainThread
        }
        let task = await MainActor.run {
            Task {
                await executor.execute {
                    Thread.isMainThread
                }
            }
        }

        let operationRanOnMainThread = await task.value

        #expect(callerRanOnMainThread)
        #expect(!operationRanOnMainThread)
    }

    @Test("cancellation does not claim a running blocking read stopped")
    func cancellationDoesNotClaimARunningBlockingReadStopped() async {
        let executor = LibGit2BlockingReadExecutor.shared
        let operationGate = BlockingReadOperationGate()
        let task = Task {
            await executor.execute {
                operationGate.runUntilReleased()
                return 42
            }
        }
        await operationGate.waitUntilRunning()

        task.cancel()

        #expect(operationGate.isRunning)
        #expect(!operationGate.isFinished)

        operationGate.release()
        let result = await task.value

        #expect(result == 42)
        #expect(operationGate.isFinished)
    }

    @Test("the enqueue seam preserves typed failures")
    func enqueueSeamPreservesTypedFailures() async {
        let enqueuedOperation = LockedEnqueuedOperation()
        let executor = LibGit2BlockingReadExecutor(enqueue: enqueuedOperation.enqueue)

        let task = Task {
            do throws(BlockingReadTestError) {
                _ = try await executor.execute { () throws(BlockingReadTestError) -> Bool in
                    throw BlockingReadTestError.expected
                }
                return Result<Bool, BlockingReadTestError>.success(true)
            } catch {
                return Result<Bool, BlockingReadTestError>.failure(error)
            }
        }
        await enqueuedOperation.waitUntilEnqueued()
        enqueuedOperation.run()
        let result = await task.value

        #expect(result == .failure(.expected))
    }

    @Test("local client read APIs use the blocking executor")
    func localClientReadAPIsUseTheBlockingExecutor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let enqueueRecorder = SynchronousEnqueueRecorder()
        let executor = LibGit2BlockingReadExecutor(enqueue: enqueueRecorder.enqueue)
        let client = LibGit2AgentStudioGitLocalClient(blockingReadExecutor: executor)

        let identity = try await client.repositoryIdentity(for: root)

        #expect(identity.mainWorktreePath?.path == root.path)
        #expect(enqueueRecorder.enqueueCount == 1)
    }

    @Test("each local client blocking read API enqueues exactly once", arguments: BlockingReadAPI.allCases)
    private func eachLocalClientBlockingReadAPIEnqueuesExactlyOnce(blockingReadAPI: BlockingReadAPI) async throws {
        // Arrange
        let missingRepositoryPath = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-missing-blocking-read-\(UUID().uuidString)")
        let enqueueRecorder = SynchronousEnqueueRecorder()
        let executor = LibGit2BlockingReadExecutor(enqueue: enqueueRecorder.enqueue)
        let client = LibGit2AgentStudioGitLocalClient(blockingReadExecutor: executor)

        // Act
        switch blockingReadAPI {
        case .worktrees:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.worktrees(for: missingRepositoryPath)
            }
        case .validateWorktree:
            let validation = try await client.validateWorktree(
                GitValidateWorktreeRequest(worktreePath: missingRepositoryPath)
            )
            #expect(validation == GitWorktreeValidation(snapshot: nil, isValid: false))
        case .statusFacts:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.statusFacts(for: missingRepositoryPath, options: GitStatusOptions())
            }
        case .exactLineCountDetail:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.exactLineCountDetail(for: missingRepositoryPath, excludeSubmodules: false)
            }
        case .completeStatus:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.completeStatus(for: missingRepositoryPath, options: GitStatusOptions())
            }
        case .trackedPaths:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.trackedPaths(for: missingRepositoryPath, options: GitTrackedPathsOptions())
            }
        case .isPathIgnored:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.isPathIgnored(
                    repositoryAt: missingRepositoryPath,
                    relativePath: "README.md"
                )
            }
        case .ignoredPaths:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.ignoredPaths(
                    repositoryAt: missingRepositoryPath,
                    relativePaths: ["README.md"]
                )
            }
        case .branches:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.branches(for: missingRepositoryPath)
            }
        case .resolveReviewDefaultTarget:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.resolveReviewDefaultTarget(for: missingRepositoryPath)
            }
        case .resolveRevision:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.resolveRevision(
                    GitRevisionResolutionRequest(repositoryPath: missingRepositoryPath, target: .named("HEAD"))
                )
            }
        case .readTree:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.readTree(
                    GitTreeReadRequest(repositoryPath: missingRepositoryPath, revision: .named("HEAD"), path: nil)
                )
            }
        case .diff:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.diff(
                    GitDiffRequest(repositoryPath: missingRepositoryPath, base: .head, compare: .workingTree)
                )
            }
        case .countCommitRange:
            await assertMissingRepositoryCommitRangeUsesBlockingExecutor(
                client: client,
                missingRepositoryPath: missingRepositoryPath
            )
        case .summarizeDiffImpact:
            await assertMissingRepositoryDiffImpactUsesBlockingExecutor(
                client: client,
                missingRepositoryPath: missingRepositoryPath
            )
        case .contributionDiff:
            await assertMissingRepositoryContributionDiffUsesBlockingExecutor(
                client: client,
                missingRepositoryPath: missingRepositoryPath
            )
        case .directReviewComparison:
            await assertMissingRepositoryDirectReviewUsesBlockingExecutor(
                client: client,
                missingRepositoryPath: missingRepositoryPath
            )
        case .content:
            await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
                _ = try await client.content(
                    GitContentRequest(repositoryPath: missingRepositoryPath, target: .head, path: "README.md")
                )
            }
        }

        // Assert
        #expect(enqueueRecorder.enqueueCount == 1)
    }

    @Test("bounded review capture uses the blocking executor")
    func boundedReviewCaptureUsesTheBlockingExecutor() async {
        let missingRepositoryPath = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-missing-capture-\(UUID().uuidString)")
        let enqueueRecorder = SynchronousEnqueueRecorder()
        let client = LibGit2AgentStudioGitLocalClient(
            blockingReadExecutor: LibGit2BlockingReadExecutor(enqueue: enqueueRecorder.enqueue)
        )
        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.captureReviewComparisonTargets(
                GitReviewComparisonTargetCaptureRequest(
                    repositoryPath: missingRepositoryPath,
                    capturedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    cutoff: 0,
                    maximumRows: 10,
                    currentBranchReference: nil
                )
            )
        }
        #expect(enqueueRecorder.enqueueCount == 1)
    }

    @Test("discovery reads use the blocking executor")
    func discoveryReadsUseTheBlockingExecutor() async {
        let enqueueRecorder = SynchronousEnqueueRecorder()
        let executor = LibGit2BlockingReadExecutor(enqueue: enqueueRecorder.enqueue)
        let runtime = LibGit2Runtime(initializeLibGit2: { 1 })
        let client = LibGit2AgentStudioGitDiscoveryReadClient(
            runtime: runtime,
            blockingReadExecutor: executor
        )

        let outcome = await client.readDiscoveryCandidate(
            GitDiscoveryReadRequest(candidatePath: URL(fileURLWithPath: "/path/that/is/not/a/repository"))
        )

        #expect(outcome == .notRepository(.exactCandidateIsNotRepository))
        #expect(enqueueRecorder.enqueueCount == 1)
    }
}

private enum BlockingReadTestError: Error, Equatable, Sendable {
    case expected
}

private func assertMissingRepositoryCommitRangeUsesBlockingExecutor(
    client: LibGit2AgentStudioGitLocalClient,
    missingRepositoryPath: URL
) async {
    await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
        _ = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: missingRepositoryPath,
                base: .named("base"),
                candidate: .named("candidate"),
                maximumCount: 10,
                maximumTraversalCount: 64
            )
        )
    }
}

private func assertMissingRepositoryDiffImpactUsesBlockingExecutor(
    client: LibGit2AgentStudioGitLocalClient,
    missingRepositoryPath: URL
) async {
    await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
        _ = try await client.summarizeDiffImpact(
            GitDiffImpactSummaryRequest(
                repositoryPath: missingRepositoryPath,
                base: .head,
                compare: .workingTree,
                maximumChangedFileCount: 25,
                maximumChangedLineCount: 1000,
                maximumDiffableBlobByteCount: 1_048_576
            )
        )
    }
}

private func assertMissingRepositoryContributionDiffUsesBlockingExecutor(
    client: LibGit2AgentStudioGitLocalClient,
    missingRepositoryPath: URL
) async {
    await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
        _ = try await client.contributionDiff(
            GitContributionDiffRequest(
                repositoryPath: missingRepositoryPath,
                target: .named("refs/heads/main")
            )
        )
    }
}

private func assertMissingRepositoryDirectReviewUsesBlockingExecutor(
    client: LibGit2AgentStudioGitLocalClient,
    missingRepositoryPath: URL
) async {
    await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
        _ = try await client.directReviewComparison(
            GitDirectReviewComparisonRequest(
                repositoryPath: missingRepositoryPath,
                target: .named("refs/heads/main")
            )
        )
    }
}

private enum BlockingReadAPI: String, CaseIterable, Sendable {
    case worktrees
    case validateWorktree
    case statusFacts
    case exactLineCountDetail
    case completeStatus
    case trackedPaths
    case isPathIgnored
    case ignoredPaths
    case branches
    case resolveReviewDefaultTarget
    case resolveRevision
    case readTree
    case diff
    case countCommitRange
    case summarizeDiffImpact
    case contributionDiff
    case directReviewComparison
    case content
}

private final class BlockingReadOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var running = false
    private var released = false
    private var finished = false
    private var runningWaiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return running
    }

    var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    func runUntilReleased() {
        condition.lock()
        running = true
        let waiters = runningWaiters
        runningWaiters.removeAll()
        condition.unlock()
        for waiter in waiters {
            waiter.resume()
        }

        condition.lock()
        while !released {
            condition.wait()
        }
        running = false
        finished = true
        condition.unlock()
    }

    func waitUntilRunning() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            guard !running else {
                condition.unlock()
                continuation.resume()
                return
            }
            runningWaiters.append(continuation)
            condition.unlock()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class LockedEnqueuedOperation: @unchecked Sendable {
    private let condition = NSCondition()
    private var operation: (@Sendable () -> Void)?
    private var enqueueWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        condition.lock()
        self.operation = operation
        let waiters = enqueueWaiters
        enqueueWaiters.removeAll()
        condition.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilEnqueued() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            guard operation == nil else {
                condition.unlock()
                continuation.resume()
                return
            }
            enqueueWaiters.append(continuation)
            condition.unlock()
        }
    }

    func run() {
        condition.lock()
        let operation = operation
        self.operation = nil
        condition.unlock()
        operation?()
    }
}

private final class SynchronousEnqueueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var enqueueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        count += 1
        lock.unlock()
        operation()
    }
}
