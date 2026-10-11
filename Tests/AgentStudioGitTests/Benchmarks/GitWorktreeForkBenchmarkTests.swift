import AgentStudioGit
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

/// V-08 evidence only: phase costs and physical allocation for representative sources. There is no
/// pass/fail threshold (no latency budget is authorized) and the suite is excluded from `mise run test`.
/// Run with `mise run benchmark-worktree-fork`; the report lands in `tmp/benchmarks/`.
@Suite(
    "Git worktree fork benchmarks",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_FORK_BENCHMARK"] == "1")
)
struct GitWorktreeForkBenchmarkTests {
    private static let runsPerFixture = 3

    @Test("record fork phase costs for ordinary, 50,000-file, and prepared-cache sources")
    func recordForkPhaseCosts() async throws {
        // Arrange
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtures: [(String, (GitWorktreeForkFixture) throws -> Void)] = [
            ("ordinary (clone of this package)", { try Self.populateOrdinary($0, packageRoot: packageRoot) }),
            ("50,000 tracked files (loose objects, as just committed)", Self.populateManyFiles),
            (
                "50,000 tracked files (packed objects)",
                { fixture in
                    try Self.populateManyFiles(fixture)
                    try fixture.git.run("repack", "-adq")
                }
            ),
            ("prepared cache (ignored dependencies + 256 MiB blobs)", Self.populatePreparedCache),
        ]
        var sections: [String] = []

        for (label, populate) in fixtures {
            let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-benchmark")
            defer { fixture.remove() }
            try populate(fixture)
            var rows: [BenchmarkRow] = []
            for run in 1...Self.runsPerFixture {
                // Act
                rows.append(try await measureFork(fixture, destinationName: "fork-\(run)"))
            }
            sections.append(Self.section(label, rows))
        }

        // Assert
        let report = Self.report(sections)
        let reportURL = packageRoot.appending(path: "tmp/benchmarks/2026-09-23-worktree-fork-phases.md")
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        print(report)
        #expect(!sections.isEmpty)
    }

    private func measureFork(_ fixture: GitWorktreeForkFixture, destinationName: String) async throws -> BenchmarkRow {
        let marks = OSAllocatedUnfairLock(initialState: [(WorktreeForkFaultPoint, ContinuousClock.Instant)]())
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            if case .beforeRegularFileClone = point {
                return
            }
            let now = ContinuousClock.now
            marks.withLock { $0.append((point, now)) }
        }
        let rootEvidence = OSAllocatedUnfairLock<WorktreeForkIndexRefreshEvidence?>(initialState: nil)
        let observer = WorktreeForkIndexObserver { node, evidence in
            if node.isEmpty {
                rootEvidence.withLock { $0 = evidence }
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults, indexObserver: observer))
        let destination = fixture.destination(destinationName)
        let freeBefore = Self.availableBytes(fixture.repository.root)
        let start = ContinuousClock.now
        let result = try await client.forkWorktree(
            fixture.request(destination: destination, mode: .detached(start: .sourceHead)))
        let materializationReport: GitWorktreeMaterializationReport
        if case .copyOnWrite(let report) = result.materialization {
            materializationReport = report
        } else {
            throw GitWorktreeForkError.validationFailed(reason: .entryCountMismatch, relativePath: nil)
        }
        let end = ContinuousClock.now
        let freeAfter = Self.availableBytes(fixture.repository.root)
        let statusStart = ContinuousClock.now
        _ = try await client.statusFacts(for: destination, options: GitStatusOptions())
        let firstStatus = ContinuousClock.now - statusStart

        let recorded = Dictionary(marks.withLock { $0 }, uniquingKeysWith: { first, _ in first })
        func mark(_ point: WorktreeForkFaultPoint) -> ContinuousClock.Instant {
            recorded[point] ?? end
        }
        return BenchmarkRow(
            preflight: mark(.afterPreflight) - start,
            planning: mark(.afterPlanning) - mark(.afterPreflight),
            registration: mark(.afterWorktreeAdded) - mark(.afterPlanning),
            materialization: mark(.afterMaterialization) - mark(.afterWorktreeAdded),
            rehoming: mark(.afterGitStateRehomed) - mark(.afterMaterialization),
            directoryMetadata: mark(.afterDirectoryMetadataApplied) - mark(.afterGitStateRehomed),
            indexes: mark(.afterIndexesBuilt) - mark(.afterDirectoryMetadataApplied),
            validation: mark(.afterValidation) - mark(.afterIndexesBuilt),
            total: end - start,
            firstStatus: firstStatus,
            regularFiles: materializationReport.clonedRegularFileCount,
            adoptedEntries: rootEvidence.withLock { $0?.adoptedPaths.count ?? 0 },
            logicalBytes: materializationReport.logicalRegularFileBytes,
            freeSpaceDeltaBytes: freeBefore - freeAfter
        )
    }

    private static func populateOrdinary(_ fixture: GitWorktreeForkFixture, packageRoot: URL) throws {
        let clone = fixture.repository.root.appending(path: "ordinary")
        try fixture.git.run(["clone", "-q", "--no-local", packageRoot.path, clone.path])
        try FileManager.default.removeItem(at: fixture.source)
        try FileManager.default.moveItem(at: clone, to: fixture.source)
    }

    private static func populateManyFiles(_ fixture: GitWorktreeForkFixture) throws {
        for directory in 0..<500 {
            let directoryURL = fixture.source.appending(path: "tree/\(directory)")
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for file in 0..<100 {
                try Data("file \(directory)-\(file)\n".utf8).write(to: directoryURL.appending(path: "f\(file).txt"))
            }
        }
        try fixture.git.run("add", "-A")
        try fixture.git.run("commit", "-qm", "many files")
    }

    private static func populatePreparedCache(_ fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "node_modules/\ncache/\n")
        for directory in 0..<20 {
            try fixture.write("src/module-\(directory).swift", "let module\(directory) = \(directory)\n")
        }
        try fixture.git.run("add", "-A")
        try fixture.git.run("commit", "-qm", "sources")
        for package in 0..<200 {
            let packageURL = fixture.source.appending(path: "node_modules/package-\(package)/lib")
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            for file in 0..<100 {
                try Data("module.exports = \(package * 100 + file)\n".utf8).write(
                    to: packageURL.appending(path: "m\(file).js"))
            }
        }
        let chunk = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 131) })
        let cache = fixture.source.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for blob in 0..<4 {
            let blobURL = cache.appending(path: "blob-\(blob).bin")
            FileManager.default.createFile(atPath: blobURL.path, contents: nil)
            let writer = try FileHandle(forWritingTo: blobURL)
            for _ in 0..<64 {
                try writer.write(contentsOf: chunk)
            }
            try writer.close()
        }
    }

    private static func availableBytes(_ url: URL) -> Int64 {
        var fileSystem = statfs()
        guard url.path.withCString({ statfs($0, &fileSystem) }) == 0 else {
            return 0
        }
        return Int64(fileSystem.f_bavail) * Int64(fileSystem.f_bsize)
    }

    private static func section(_ label: String, _ rows: [BenchmarkRow]) -> String {
        var lines = [
            "## \(label)",
            "",
            "| run | preflight | planning | registration | materialization | re-homing | dir metadata | indexes |"
                + " validation | total | first status | files | adopted index entries | logical MiB |"
                + " free-space delta MiB |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for (index, row) in rows.enumerated() {
            lines.append(
                "| \(index + 1) | \(ms(row.preflight)) | \(ms(row.planning)) | \(ms(row.registration)) |"
                    + " \(ms(row.materialization)) | \(ms(row.rehoming)) | \(ms(row.directoryMetadata)) | \(ms(row.indexes)) |"
                    + " \(ms(row.validation)) | \(ms(row.total)) | \(ms(row.firstStatus)) | \(row.regularFiles) | \(row.adoptedEntries) |"
                    + " \(mib(row.logicalBytes)) | \(mib(row.freeSpaceDeltaBytes)) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func report(_ sections: [String]) -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return """
            # Worktree Fork phase costs (V-08)

            Host: macOS \(version), \(ProcessInfo.processInfo.activeProcessorCount) cores. Times in ms, wall clock,
            detached forks from a warm source. Free-space delta is volume-wide and noisy; logical MiB is the cloned
            payload. First status is the SDK status read (no index refresh) immediately after the fork.

            \(sections.joined(separator: "\n\n"))
            """
    }

    private static func ms(_ duration: Duration) -> String {
        String(
            format: "%.1f", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }

    private static func mib(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

private struct BenchmarkRow {
    let preflight: Duration
    let planning: Duration
    let registration: Duration
    let materialization: Duration
    let rehoming: Duration
    let directoryMetadata: Duration
    let indexes: Duration
    let validation: Duration
    let total: Duration
    let firstStatus: Duration
    let regularFiles: Int
    let adoptedEntries: Int
    let logicalBytes: Int64
    let freeSpaceDeltaBytes: Int64
}
