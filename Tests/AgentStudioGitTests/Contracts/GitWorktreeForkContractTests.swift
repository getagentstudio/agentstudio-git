import AgentStudioGit
import Foundation
import Testing

@Suite("Git worktree fork contracts")
struct GitWorktreeForkContractTests {
    @Test("fork modes carry an explicit kind, a start or pinned tips, and an optional upstream")
    func forkModesUseExplicitKindDiscriminators() throws {
        // Arrange
        let tip = "0123456789abcdef0123456789abcdef01234567"
        let next = "89abcdef0123456789abcdef0123456789abcdef"
        let modes: [GitForkWorktreeMode] = [
            .existingBranch(name: "feature", expectedTip: tip, fastForwardTo: nil),
            .existingBranch(name: "feature", expectedTip: tip, fastForwardTo: next),
            .newBranch(name: "fork-feature", start: .sourceHead, upstream: nil),
            .newBranch(
                name: "feat", start: .commit(next),
                upstream: GitBranchUpstream(remoteName: "origin", branchName: "feat")),
            .detached(start: .sourceHead),
            .detached(start: .commit(tip)),
        ]

        // Act
        let encodedModes = try modes.map { try sortedEncoder().encode($0) }
        let decodedModes = try encodedModes.map { try JSONDecoder().decode(GitForkWorktreeMode.self, from: $0) }

        // Assert
        #expect(decodedModes == modes)
        #expect(
            encodedModes.map { jsonText($0) } == [
                #"{"expectedTip":"\#(tip)","kind":"existingBranch","name":"feature"}"#,
                #"{"expectedTip":"\#(tip)","fastForwardTo":"\#(next)","kind":"existingBranch","name":"feature"}"#,
                #"{"kind":"newBranch","name":"fork-feature","start":{"kind":"sourceHead"}}"#,
                #"{"kind":"newBranch","name":"feat","start":{"commit":"\#(next)","kind":"commit"},"#
                    + #""upstream":{"branchName":"feat","remoteName":"origin"}}"#,
                #"{"kind":"detached","start":{"kind":"sourceHead"}}"#,
                #"{"kind":"detached","start":{"commit":"\#(tip)","kind":"commit"}}"#,
            ])
    }

    @Test("fork mode decoding rejects missing starts, abbreviated tips, and stray fields")
    func forkModeDecodingRejectsInvalidShapes() {
        // Arrange
        let tip = "0123456789abcdef0123456789abcdef01234567"
        let payloads = [
            #"{"kind":"newBranch","name":"feat"}"#,
            #"{"kind":"newBranch","name":"feat","start":{"kind":"commit","commit":"main"}}"#,
            #"{"kind":"newBranch","name":"feat","start":{"kind":"sourceHead","commit":"\#(tip)"}}"#,
            #"{"kind":"newBranch","name":"feat","start":{"kind":"sourceHead"},"expectedTip":"\#(tip)"}"#,
            #"{"kind":"newBranch","name":"feat","start":{"kind":"sourceHead"},"#
                + #""upstream":{"remoteName":"","branchName":"x"}}"#,
            #"{"kind":"existingBranch","name":"feat"}"#,
            #"{"kind":"existingBranch","name":"feat","expectedTip":"0123456"}"#,
            #"{"kind":"existingBranch","name":"feat","expectedTip":"\#(tip)","fastForwardTo":"HEAD"}"#,
            #"{"kind":"existingBranch","name":"feat","expectedTip":"\#(tip)","start":{"kind":"sourceHead"}}"#,
            #"{"kind":"detached"}"#,
            #"{"kind":"detached","name":"stray","start":{"kind":"sourceHead"}}"#,
        ]

        // Act / Assert
        for payload in payloads {
            #expect(throws: DecodingError.self, "\(payload)") {
                _ = try JSONDecoder().decode(GitForkWorktreeMode.self, from: Data(payload.utf8))
            }
        }
    }

    @Test("fork requests round-trip with stable field names")
    func forkRequestsRoundTripWithStableFieldNames() throws {
        // Arrange
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: URL(fileURLWithPath: "/tmp/source"),
            destinationPath: URL(fileURLWithPath: "/tmp/destination"),
            mode: .newBranch(name: "fork", start: .sourceHead, upstream: nil),
            materialization: .copyOnWrite,
            copyRules: GitWorktreeCopyRules(ignoredPaths: .copyAll)
        )

        // Act
        let encoded = try sortedEncoder().encode(request)
        let decoded = try JSONDecoder().decode(GitForkWorktreeRequest.self, from: encoded)

        // Assert
        #expect(decoded == request)
        #expect(
            jsonText(encoded)
                == #"{"copyRules":{"ignoredPaths":{"kind":"copyAll"}},"destinationPath":"file:///tmp/destination","materialization":"copyOnWrite","mode":{"kind":"newBranch","name":"fork","start":{"kind":"sourceHead"}},"#
                + #""sourceWorktreePath":"file:///tmp/source"}"#
        )
    }

    @Test("fork results carry the validated snapshot and ordered materialization report")
    func forkResultsCarrySnapshotAndOrderedReport() throws {
        // Arrange
        let report = GitWorktreeMaterializationReport(
            clonedRegularFileCount: 12,
            createdDirectoryCount: 4,
            recreatedSymbolicLinkCount: 2,
            preservedHardLinkCount: 1,
            preservedGitRepositoryCount: 1,
            recreatedFIFOCount: 1,
            logicalRegularFileBytes: 4096,
            skippedEntries: [
                GitWorktreeMaterializationSkippedEntry(
                    relativePath: "run/agent.sock",
                    kind: .unixSocket,
                    reason: .unixSocketNotReproducible
                )
            ],
            normalizedEntries: [
                GitWorktreeMaterializationNormalizedEntry(
                    relativePath: "bin/tool",
                    attribute: .setUserIDBit,
                    reason: .clearedByCopyOnWriteClone
                ),
                GitWorktreeMaterializationNormalizedEntry(
                    relativePath: "shared/data",
                    attribute: .ownerUser,
                    reason: .ownershipNotAssignable
                ),
            ],
            ignoredIncludedPatterns: [".build*/", "Frameworks/"],
            ignoredExcludedCount: 42,
            nestedWorktreesSkipped: [".claude/worktrees/agent"],
            sourceState: .asIs,
            submodulesNotAtStart: [],
            largeFiles: nil
        )
        let result = GitForkWorktreeResult(
            worktree: worktreeSnapshot(), materialization: .copyOnWrite(report))

        // Act
        let decoded = try JSONDecoder().decode(GitForkWorktreeResult.self, from: sortedEncoder().encode(result))

        // Assert
        #expect(decoded == result)
        guard case .copyOnWrite(let decodedReport) = decoded.materialization else {
            Issue.record("expected copy-on-write result")
            return
        }
        #expect(decodedReport.skippedEntries.map(\.relativePath) == ["run/agent.sock"])
        #expect(decodedReport.normalizedEntries.map(\.relativePath) == ["bin/tool", "shared/data"])
    }

    @Test("a reset report carries its source state, submodules not at the start, and its fill")
    func resetReportCarriesSourceStateSubmodulesAndFill() throws {
        // Arrange
        let largeFiles = GitLargeFileFill(materializedCount: 2, missing: [], residuePaths: [], scan: .complete)
        let report = GitWorktreeMaterializationReport(
            clonedRegularFileCount: 1, createdDirectoryCount: 0, recreatedSymbolicLinkCount: 0,
            preservedHardLinkCount: 0, preservedGitRepositoryCount: 0, recreatedFIFOCount: 0,
            logicalRegularFileBytes: 6, skippedEntries: [], normalizedEntries: [], ignoredIncludedPatterns: [],
            ignoredExcludedCount: 0, nestedWorktreesSkipped: [], sourceState: .reset,
            submodulesNotAtStart: ["vendor/sub"], largeFiles: largeFiles)
        let base =
            #""clonedRegularFileCount":1,"createdDirectoryCount":0,"ignoredExcludedCount":0,"#
            + #""ignoredIncludedPatterns":[],"kind":"copyOnWrite","#
        let tail =
            #""logicalRegularFileBytes":6,"nestedWorktreesSkipped":[],"normalizedEntries":[],"#
            + #""preservedGitRepositoryCount":0,"preservedHardLinkCount":0,"recreatedFIFOCount":0,"#
            + #""recreatedSymbolicLinkCount":0,"skippedEntries":[],"#
        let fill = #""largeFiles":{"materializedCount":0,"missing":[],"residuePaths":[],"scan":"complete"},"#
        let invalidPayloads = [
            "{" + base + tail + #""sourceState":"asIs","submodulesNotAtStart":["sub"]}"#,
            "{" + base + fill + tail + #""sourceState":"asIs","submodulesNotAtStart":[]}"#,
            "{" + base + tail + #""sourceState":"reset","submodulesNotAtStart":[]}"#,
            "{" + base + tail + #""submodulesNotAtStart":[]}"#,
        ]

        // Act
        let encoded = try sortedEncoder().encode(GitWorktreeMaterializationResult.copyOnWrite(report))
        let decoded = try JSONDecoder().decode(GitWorktreeMaterializationResult.self, from: encoded)

        // Assert
        #expect(decoded == .copyOnWrite(report))
        #expect(
            jsonText(encoded)
                == "{" + base
                + #""largeFiles":{"materializedCount":2,"missing":[],"residuePaths":[],"scan":"complete"},"#
                + tail + #""sourceState":"reset","submodulesNotAtStart":["vendor/sub"]}"#)
        for payload in invalidPayloads {
            #expect(throws: DecodingError.self, "\(payload)") {
                _ = try JSONDecoder().decode(GitWorktreeMaterializationResult.self, from: Data(payload.utf8))
            }
        }
    }

    @Test("changes-only reports and refusals use explicit tagged payloads")
    func changesOnlyContractsUseExplicitTags() throws {
        // Arrange
        let largeFiles = GitLargeFileFill(materializedCount: 1, missing: [], residuePaths: [], scan: .complete)
        let report = GitChangesOnlyMaterializationReport(
            trackedChanges: 3,
            untrackedFiles: 2,
            largeFiles: largeFiles
        )
        let refusal = GitWorktreeWorkingStateRefusal(reason: .customFilter, relativePath: "assets/icon.png")
        let result = GitWorktreeMaterializationResult.changesOnly(report)
        let error = GitWorktreeForkError.workingStateUnsupported(refusal)

        // Act
        let encodedResult = try sortedEncoder().encode(result)
        let encodedError = try sortedEncoder().encode(error)

        // Assert
        #expect(try JSONDecoder().decode(GitWorktreeMaterializationResult.self, from: encodedResult) == result)
        #expect(try JSONDecoder().decode(GitWorktreeForkError.self, from: encodedError) == error)
        #expect(
            jsonText(encodedResult)
                == #"{"ignoredExcluded":true,"kind":"changesOnly","largeFiles":{"materializedCount":1,"missing":[],"residuePaths":[],"scan":"complete"},"trackedChanges":3,"untrackedFiles":2}"#
        )
        #expect(
            jsonText(encodedError)
                == #"{"workingStateUnsupported":{"refusal":{"reason":"customFilter","relativePath":"assets/icon.png"}}}"#
        )
        for invalidPayload in [
            #"{"kind":"changesOnly","trackedChanges":-1,"untrackedFiles":0,"ignoredExcluded":true,"largeFiles":{"materializedCount":0,"missing":[],"residuePaths":[],"scan":"complete"}}"#,
            #"{"kind":"changesOnly","trackedChanges":1,"untrackedFiles":0,"ignoredExcluded":false,"largeFiles":{"materializedCount":0,"missing":[],"residuePaths":[],"scan":"complete"}}"#,
            #"{"kind":"changesOnly","trackedChanges":1,"untrackedFiles":0,"ignoredExcluded":true,"largeFiles":{"materializedCount":0,"missing":[],"residuePaths":[],"scan":"complete"},"clonedRegularFileCount":0}"#,
            #"{"kind":"changesOnly","trackedChanges":1,"untrackedFiles":0,"ignoredExcluded":true}"#,
        ] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitWorktreeMaterializationResult.self, from: Data(invalidPayload.utf8))
            }
        }
    }

    @Test("every fork failure variant round-trips through its explicit case key")
    func everyForkFailureVariantRoundTrips() throws {
        // Arrange
        let primary = GitWorktreeForkError.entryFailed(
            relativePath: "cache/blob.bin",
            reason: .strictCloneFailed,
            errorNumber: 45
        )
        let errors: [GitWorktreeForkError] = [
            .rejected(reason: .clientCapabilityUnavailable),
            .rejected(reason: .destinationExists),
            .branchCheckedOut(worktreePath: URL(fileURLWithPath: "/tmp/repository.feat")),
            .workingStateUnsupported(
                GitWorktreeWorkingStateRefusal(reason: .nestedRepository, relativePath: "vendor/module")),
            .workingStateUnsupported(
                GitWorktreeWorkingStateRefusal(reason: .attributesChanged, relativePath: ".gitattributes")),
            .gitFailure(.headUnavailable),
            .sourceChanged(relativePath: "src/main.swift", reason: .entryKindChanged),
            primary,
            .cancelled,
            .validationFailed(reason: .indexStatNotRefreshed, relativePath: "README.md"),
            .validationFailed(reason: .headMismatch, relativePath: nil),
            .cleanupIncomplete(
                primary: primary,
                residue: [
                    GitWorktreeForkResidue(kind: .destinationContent, location: "."),
                    GitWorktreeForkResidue(kind: .linkedWorktreeAdministration, location: "worktrees/fork"),
                    GitWorktreeForkResidue(kind: .createdBranch, location: "refs/heads/fork"),
                    GitWorktreeForkResidue(kind: .lockFile, location: "worktrees/fork/index.lock"),
                    GitWorktreeForkResidue(kind: .branchMoveNotUndone, location: "refs/heads/feat"),
                ]
            ),
        ]

        // Act
        let encoded = try errors.map { try sortedEncoder().encode($0) }
        let decoded = try encoded.map { try JSONDecoder().decode(GitWorktreeForkError.self, from: $0) }

        // Assert
        #expect(decoded == errors)
        #expect(
            jsonText(encoded[0]) == #"{"rejected":{"reason":"clientCapabilityUnavailable"}}"#)
        #expect(
            jsonText(encoded[2]) == #"{"branchCheckedOut":{"worktreePath":"file:///tmp/repository.feat"}}"#)
        #expect(
            jsonText(encoded[4])
                == #"{"workingStateUnsupported":{"refusal":{"reason":"attributesChanged","relativePath":".gitattributes"}}}"#
        )
        #expect(jsonText(encoded[8]) == #"{"cancelled":{}}"#)
        #expect(
            jsonText(encoded[5]) == #"{"gitFailure":{"error":{"headUnavailable":{}}}}"#
        )
    }

    @Test("fork failure decoding rejects ambiguous or unknown cases")
    func forkFailureDecodingRejectsAmbiguousOrUnknownCases() {
        // Arrange
        let payloads = [
            #"{"rejected":{"reason":"destinationExists"},"cancelled":{}}"#,
            #"{"teleported":{}}"#,
            #"{"rejected":{"reason":"teleported"}}"#,
            #"{"workingStateUnsupported":{"refusal":{"reason":"customFilter","relativePath":"../escape"}}}"#,
            #"{"kind":"detached","name":"stray"}"#,
        ]

        // Act / Assert
        for payload in payloads.prefix(4) {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitWorktreeForkError.self, from: Data(payload.utf8))
            }
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitForkWorktreeMode.self, from: Data(payloads[4].utf8))
        }
    }

    @Test("fork eligibility uses an explicit state discriminator and rejects contradictory payloads")
    func forkEligibilityUsesExplicitStateDiscriminator() throws {
        // Arrange
        let values: [GitWorktreeForkEligibility] = [.available, .unavailable(.fileProviderManagedLocation)]
        let contradictory = [
            #"{"state":"available","reason":"crossDevice"}"#,
            #"{"state":"unavailable"}"#,
            #"{"state":"teleported"}"#,
        ]

        // Act
        let encoded = try values.map { try sortedEncoder().encode($0) }
        let decoded = try encoded.map { try JSONDecoder().decode(GitWorktreeForkEligibility.self, from: $0) }

        // Assert
        #expect(decoded == values)
        #expect(
            encoded.map(jsonText) == [
                #"{"state":"available"}"#,
                #"{"reason":"fileProviderManagedLocation","state":"unavailable"}"#,
            ])
        for payload in contradictory {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitWorktreeForkEligibility.self, from: Data(payload.utf8))
            }
        }
    }

    @Test("existing conformers report fork eligibility as unavailable")
    func existingConformersReportForkEligibilityUnavailable() async {
        // Arrange
        let client: any AgentStudioGitLocalClient = LegacyLocalClientDouble()

        // Act
        let eligibility = await client.forkWorktreeEligibility(
            sourceWorktreePath: URL(fileURLWithPath: "/tmp/source"),
            destinationPath: URL(fileURLWithPath: "/tmp/destination"),
            materialization: .copyOnWrite
        )

        // Assert
        #expect(eligibility == .unavailable(.clientCapabilityUnavailable))
    }

    @Test("create requests use case-keyed modes with pinned tips and an optional upstream")
    func createRequestsUseCaseKeyedModes() throws {
        // Arrange
        let repositoryPath = URL(fileURLWithPath: "/tmp/repo")
        let destinationPath = URL(fileURLWithPath: "/tmp/wt")
        let tip = "0123456789abcdef0123456789abcdef01234567"
        let next = "89abcdef0123456789abcdef0123456789abcdef"
        let modes: [GitWorktreeCreateMode] = [
            .existingBranch(name: "main", expectedTip: tip, fastForwardTo: nil),
            .existingBranch(name: "main", expectedTip: tip, fastForwardTo: next),
            .newBranch(name: "feature", startPoint: .named("HEAD"), upstream: nil),
            .newBranch(
                name: "feature", startPoint: .named(next),
                upstream: GitBranchUpstream(remoteName: "origin", branchName: "feature")),
            .detached(startPoint: .named("HEAD")),
        ]
        let payloads = [
            #"{"existingBranch":{"expectedTip":"\#(tip)","name":"main"}}"#,
            #"{"existingBranch":{"expectedTip":"\#(tip)","fastForwardTo":"\#(next)","name":"main"}}"#,
            #"{"newBranch":{"name":"feature","startPoint":{"name":"HEAD"}}}"#,
            #"{"newBranch":{"name":"feature","startPoint":{"name":"\#(next)"},"#
                + #""upstream":{"branchName":"feature","remoteName":"origin"}}}"#,
            #"{"detached":{"startPoint":{"name":"HEAD"}}}"#,
        ]
        let invalidPayloads = [
            #"{"existingBranch":{"name":"main"}}"#,
            #"{"existingBranch":{"name":"main","expectedTip":"0123456"}}"#,
            #"{"existingBranch":{"name":"main","expectedTip":"\#(tip)","fastForwardTo":"origin/main"}}"#,
            #"{"detached":{"startPoint":{"name":"HEAD"}},"newBranch":{"name":"x","startPoint":{"name":"HEAD"}}}"#,
            #"{"teleported":{}}"#,
        ]

        // Act
        let encoded = try modes.map {
            jsonText(
                try sortedEncoder().encode(
                    GitCreateWorktreeRequest(repositoryPath: repositoryPath, destinationPath: destinationPath, mode: $0)
                ))
        }
        let decoded = try payloads.map { try JSONDecoder().decode(GitWorktreeCreateMode.self, from: Data($0.utf8)) }

        // Assert
        #expect(
            encoded
                == payloads.map {
                    #"{"destinationPath":"file:///tmp/wt","mode":"# + $0 + #","repositoryPath":"file:///tmp/repo"}"#
                })
        #expect(decoded == modes)
        for payload in invalidPayloads {
            #expect(throws: DecodingError.self, "\(payload)") {
                _ = try JSONDecoder().decode(GitWorktreeCreateMode.self, from: Data(payload.utf8))
            }
        }
    }

    @Test("existing conformers without a fork implementation compile and report the capability unavailable")
    func existingConformersReportForkCapabilityUnavailable() async {
        // Arrange
        let client: any AgentStudioGitLocalClient = LegacyLocalClientDouble()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: URL(fileURLWithPath: "/tmp/source"),
            destinationPath: URL(fileURLWithPath: "/tmp/destination"),
            mode: .detached(start: .sourceHead),
            materialization: .copyOnWrite,
            copyRules: GitWorktreeCopyRules(ignoredPaths: .copyAll)
        )

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(request)
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(failure == .rejected(reason: .clientCapabilityUnavailable))
    }

    private func jsonText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    private func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func worktreeSnapshot() -> GitWorktreeSnapshot {
        let repositoryID = GitRepositoryID(rawValue: "common:/tmp/repo/.git")
        return GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "worktree:/tmp/destination"),
            repositoryID: repositoryID,
            displayName: "destination",
            path: URL(fileURLWithPath: "/tmp/destination"),
            canonicalPath: URL(fileURLWithPath: "/tmp/destination"),
            gitDirectory: URL(fileURLWithPath: "/tmp/repo/.git/worktrees/destination"),
            indexPath: URL(fileURLWithPath: "/tmp/repo/.git/worktrees/destination/index"),
            isMainWorktree: false,
            isLocked: false,
            lockReason: nil,
            head: nil
        )
    }
}
