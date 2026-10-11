import Foundation
import Testing

@Suite("Source structure contracts")
struct SourceStructureTests {
    @Test("production Swift files stay below the local split threshold")
    func productionSwiftFilesStayBelowTheLocalSplitThreshold() throws {
        let oversizedFiles = try sourceSwiftFiles().compactMap { filePath -> String? in
            let lineCount = try lineCount(for: filePath)
            guard lineCount > 600 else {
                return nil
            }
            return "\(filePath):\(lineCount)"
        }

        #expect(oversizedFiles.isEmpty)
    }

    @Test("async git process runner does not block while polling process exit")
    func asyncGitProcessRunnerDoesNotBlockWhilePollingProcessExit() throws {
        let pollingSourcePaths = [
            "Sources/AgentStudioGitRemote/GitProcessOutputCapture.swift",
            "Sources/AgentStudioGitRemote/GitProcessWaitCoordinator.swift",
        ]
        let pollingSources = try pollingSourcePaths.map(sourceContents).joined(separator: "\n")

        #expect(!pollingSources.contains("DispatchGroup"))
        #expect(!pollingSources.contains("DispatchSemaphore"))
        #expect(!pollingSources.contains("Task.sleep"))
        #expect(!pollingSources.contains("Thread.sleep"))
        #expect(!pollingSources.contains("usleep"))
        #expect(pollingSources.contains("withCheckedContinuation"))
        #expect(pollingSources.contains("asyncAfter"))
    }

    @Test("public local client does not expose repository backed ignore sessions")
    func publicLocalClientDoesNotExposeRepositoryBackedIgnoreSessions() throws {
        let clientSource = try sourceContents(
            "Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift"
        )
        let ignoreReaderSource = try sourceContents(
            "Sources/AgentStudioGitLocal/Status/LibGit2IgnoreReader.swift"
        )

        #expect(!clientSource.contains("public func withIgnoreSession"))
        #expect(!ignoreReaderSource.contains("public final class LibGit2IgnoreSession"))
        #expect(!ignoreReaderSource.contains("LibGit2IgnoreSession: @unchecked Sendable"))
        #expect(ignoreReaderSource.contains("defer { git_repository_free(repository) }"))
    }

    @Test("status fact reads cannot invoke exact line detail")
    func statusFactReadsCannotInvokeExactLineDetail() throws {
        let readerSource = try sourceContents(
            "Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift"
        )
        let factsStart = try #require(
            readerSource.range(of: "private func statusFacts(")
        )
        let detailStart = try #require(
            readerSource.range(
                of: "private func exactLineCountDetail(repository:",
                range: factsStart.upperBound..<readerSource.endIndex
            )
        )
        let factsImplementation = readerSource[factsStart.lowerBound..<detailStart.lowerBound]

        #expect(!factsImplementation.contains("shortstat"))
        #expect(!factsImplementation.contains("git_diff_tree_to_workdir_with_index"))
    }

    @Test("ordinary status facts do not resolve continuity dependencies")
    func ordinaryStatusFactsDoNotResolveContinuityDependencies() throws {
        let readerSource = try sourceContents(
            "Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift"
        )
        let factsStart = try #require(readerSource.range(of: "private func statusFacts("))
        let snapshotStart = try #require(
            readerSource.range(
                of: "private func statusFactsSnapshot(", range: factsStart.upperBound..<readerSource.endIndex)
        )
        let factsImplementation = readerSource[factsStart.lowerBound..<snapshotStart.lowerBound]
        let noPlanGuard = try #require(factsImplementation.range(of: "guard let observationPlan else"))
        let planResolution = try #require(
            factsImplementation.range(of: "observationIdentityReader.plan(")
        )

        #expect(noPlanGuard.lowerBound < planResolution.lowerBound)
    }

    @Test("baseline-capable status includes unreadable entries")
    func baselineCapableStatusIncludesUnreadableEntries() throws {
        let readerSource = try sourceContents(
            "Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift"
        )

        #expect(readerSource.contains("GIT_STATUS_OPT_INCLUDE_UNREADABLE.rawValue"))
        #expect(readerSource.contains("statusContains(flags, GIT_STATUS_WT_UNREADABLE)"))
    }

    private func sourceSwiftFiles() throws -> [String] {
        try filePaths(under: "Sources").filter { $0.hasSuffix(".swift") }
    }

    private func filePaths(under rootPath: String) throws -> [String] {
        let packageRootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let rootURL = packageRootURL.appending(path: rootPath)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ))
        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            paths.append(fileURL.path.replacingOccurrences(of: packageRootURL.path + "/", with: ""))
        }
        return paths.sorted()
    }

    private func sourceContents(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: path),
            encoding: .utf8
        )
    }

    private func lineCount(for path: String) throws -> Int {
        try sourceContents(path).split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
