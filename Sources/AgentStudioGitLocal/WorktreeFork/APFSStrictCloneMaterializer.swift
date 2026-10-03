import AgentStudioGitContracts
import Darwin
import Dispatch
import Foundation
import os

/// What the materializer actually realized. The validator compares it with the plan and the destination.
struct WorktreeForkMaterializationObservations: Equatable, Sendable {
    var clonedRegularFileCount = 0
    var recreatedSymbolicLinkCount = 0
    var recreatedFIFOCount = 0
    var preservedHardLinkCount = 0
    var createdDirectoryCount = 0
    var logicalRegularFileBytes: Int64 = 0
    var normalizedEntries: [GitWorktreeMaterializationNormalizedEntry] = []
    /// Regular files cloned from a descriptor whose fstat equalled the planned stat.
    var statMatchedClonePaths: Set<String> = []

    mutating func merge(_ other: Self) {
        clonedRegularFileCount += other.clonedRegularFileCount
        recreatedSymbolicLinkCount += other.recreatedSymbolicLinkCount
        recreatedFIFOCount += other.recreatedFIFOCount
        preservedHardLinkCount += other.preservedHardLinkCount
        createdDirectoryCount += other.createdDirectoryCount
        logicalRegularFileBytes += other.logicalRegularFileBytes
        normalizedEntries.append(contentsOf: other.normalizedEntries)
        statMatchedClonePaths.formUnion(other.statMatchedClonePaths)
    }
}

/// Realizes the immutable plan in the destination: directories parent-before-child, then leaves on a fixed
/// pool of blocking workers with strict per-file APFS clones and no byte-copy fallback, then hard links,
/// and finally directory metadata child-before-parent. Workers execute mechanics only.
struct APFSStrictCloneMaterializer: Sendable {
    /// The current measured default, not a public constant.
    static let leafWorkerCount = 4

    let cancellation: WorktreeForkCancellation
    let faults: WorktreeForkFaultInjector

    func createDirectories(
        _ plan: WorktreeForkFilesystemPlan,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> Int {
        for directory in plan.directories where !directory.relativePath.isEmpty {
            try cancellation.throwIfCancelled()
            let (parent, name) = WorktreeForkDescriptors.splitParent(directory.relativePath)
            let parentDescriptor = try openDestinationDirectory(destinationRootDescriptor, parent)
            defer { close(parentDescriptor) }
            guard name.withCString({ mkdirat(parentDescriptor, $0, 0o700) }) == 0 else {
                throw .entryFailed(
                    relativePath: directory.relativePath, reason: .entryCreationFailed, errorNumber: errno)
            }
        }
        return plan.createdDirectoryCount
    }

    func materializeLeaves(
        _ plan: WorktreeForkFilesystemPlan,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> WorktreeForkMaterializationObservations {
        let batches = plan.leafBatches
        let nextBatchIndex = OSAllocatedUnfairLock(initialState: 0)
        let outcome = OSAllocatedUnfairLock(initialState: WorktreeForkWorkerOutcome())
        let worker = WorktreeForkLeafWorker(
            sourceRootDescriptor: sourceRootDescriptor,
            destinationRootDescriptor: destinationRootDescriptor,
            faults: faults
        )

        DispatchQueue.concurrentPerform(iterations: Self.leafWorkerCount) { _ in
            let prior: WorktreeForkDatalessPolicy.PriorPolicy
            switch WorktreeForkDatalessPolicy.denyMaterializationOnCurrentThread() {
            case .success(let established):
                prior = established
            case .failure(let failure):
                outcome.withLock {
                    $0.record(
                        .entryFailed(relativePath: ".", reason: .datalessPolicyUnavailable, errorNumber: failure.code))
                }
                return
            }
            defer { WorktreeForkDatalessPolicy.restore(prior) }

            var observations = WorktreeForkMaterializationObservations()
            while !cancellation.isCancelled, !outcome.withLock({ $0.hasFailure }) {
                let batchIndex = nextBatchIndex.withLock { index in
                    defer { index += 1 }
                    return index
                }
                guard batchIndex < batches.count else {
                    break
                }
                do throws(GitWorktreeForkError) {
                    try faults.reach(.leafBatchStarted)
                    try worker.realize(batches[batchIndex], into: &observations)
                } catch {
                    outcome.withLock { $0.record(error) }
                    break
                }
            }
            let workerObservations = observations
            outcome.withLock { $0.observations.merge(workerObservations) }
        }

        let finished = outcome.withLock { $0 }
        if let failure = finished.firstFailure {
            throw failure
        }
        try cancellation.throwIfCancelled()
        return finished.observations
    }

    /// `link(2)` refuses an immutable or append-only inode, and each primary clone already carries its
    /// source's flags. Those flags are lifted from the destination primary only while its secondaries are
    /// linked, then put back, so the inode still ends with the source's flags.
    static let linkBlockingFlagMask = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    func linkHardLinkSecondaries(
        _ plan: WorktreeForkFilesystemPlan,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> Int {
        var linkedCount = 0
        for group in plan.hardLinkGroups {
            let (primaryParent, primaryName) = WorktreeForkDescriptors.splitParent(group.primaryRelativePath)
            let primaryDescriptor = try openDestinationDirectory(destinationRootDescriptor, primaryParent)
            defer { close(primaryDescriptor) }
            let primaryFile = primaryName.withCString {
                openat(primaryDescriptor, $0, WorktreeForkLeafWorker.leafOpenFlags)
            }
            guard primaryFile >= 0 else {
                throw .entryFailed(
                    relativePath: group.primaryRelativePath, reason: .entryCreationFailed, errorNumber: errno)
            }
            defer { close(primaryFile) }
            let primaryFlags: UInt32
            switch WorktreeForkDescriptors.statDescriptor(primaryFile) {
            case .success(let info):
                primaryFlags = info.st_flags
            case .failure(let failure):
                throw .entryFailed(
                    relativePath: group.primaryRelativePath, reason: .entryCreationFailed, errorNumber: failure.code)
            }
            let blockingFlags = primaryFlags & Self.linkBlockingFlagMask
            if blockingFlags != 0, fchflags(primaryFile, primaryFlags & ~blockingFlags) != 0 {
                throw .entryFailed(
                    relativePath: group.primaryRelativePath, reason: .metadataNotReproducible, errorNumber: errno)
            }
            var linkFailure: GitWorktreeForkError?
            do throws(GitWorktreeForkError) {
                linkedCount += try linkSecondaries(
                    of: group,
                    primaryDescriptor: primaryDescriptor,
                    primaryName: primaryName,
                    sourceRootDescriptor: sourceRootDescriptor,
                    destinationRootDescriptor: destinationRootDescriptor
                )
            } catch {
                linkFailure = error
            }
            if blockingFlags != 0, fchflags(primaryFile, primaryFlags) != 0, linkFailure == nil {
                linkFailure = .entryFailed(
                    relativePath: group.primaryRelativePath, reason: .metadataNotReproducible, errorNumber: errno)
            }
            if let linkFailure {
                throw linkFailure
            }
        }
        return linkedCount
    }

    private func linkSecondaries(
        of group: WorktreeForkHardLinkGroup,
        primaryDescriptor: Int32,
        primaryName: String,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> Int {
        var linkedCount = 0
        for secondaryPath in group.secondaryRelativePaths {
            try cancellation.throwIfCancelled()
            let (parent, name) = WorktreeForkDescriptors.splitParent(secondaryPath)
            try verifySourceIdentity(
                sourceRootDescriptor, parent: parent, name: name, expected: group.identity, path: secondaryPath)
            let parentDescriptor = try openDestinationDirectory(destinationRootDescriptor, parent)
            defer { close(parentDescriptor) }
            let linkResult = primaryName.withCString { primary in
                name.withCString { secondary in linkat(primaryDescriptor, primary, parentDescriptor, secondary, 0) }
            }
            guard linkResult == 0 else {
                throw .entryFailed(relativePath: secondaryPath, reason: .entryCreationFailed, errorNumber: errno)
            }
            linkedCount += 1
        }
        return linkedCount
    }

    /// Applies directory metadata child-before-parent, after every child exists, so restrictive modes and
    /// final timestamps do not fight later creation.
    func finalizeDirectories(
        _ plan: WorktreeForkFilesystemPlan,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        var normalized: [GitWorktreeMaterializationNormalizedEntry] = []
        for directory in plan.directories.reversed() {
            let reportPath = directory.relativePath.isEmpty ? "." : directory.relativePath
            let sourceDescriptor: Int32
            switch WorktreeForkDescriptors.openDirectory(
                beneath: sourceRootDescriptor, relativePath: directory.relativePath)
            {
            case .success(let opened):
                sourceDescriptor = opened
            case .failure(let failure):
                throw WorktreeForkSourceWalker.sourceFailure(relativePath: reportPath, errorNumber: failure.code)
            }
            defer { close(sourceDescriptor) }
            let destinationDescriptor = try openDestinationDirectory(destinationRootDescriptor, directory.relativePath)
            defer { close(destinationDescriptor) }
            let sourceInfo: Darwin.stat
            switch WorktreeForkDescriptors.statDescriptor(sourceDescriptor) {
            case .success(let info) where WorktreeForkEntryIdentity(info) == directory.identity:
                sourceInfo = info
            case .success:
                throw .sourceChanged(relativePath: reportPath, reason: .entryIdentityChanged)
            case .failure(let failure):
                throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: failure.code)
            }
            normalized += try WorktreeForkEntryMetadata.copyInodeMetadata(
                sourceDescriptor: sourceDescriptor,
                destinationDescriptor: destinationDescriptor,
                sourceInfo: sourceInfo,
                relativePath: reportPath
            )
        }
        return normalized
    }

    private func openDestinationDirectory(
        _ destinationRootDescriptor: Int32,
        _ relativePath: String
    ) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openDirectory(beneath: destinationRootDescriptor, relativePath: relativePath) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw .entryFailed(
                relativePath: relativePath.isEmpty ? "." : relativePath,
                reason: .entryCreationFailed,
                errorNumber: failure.code
            )
        }
    }

    private func verifySourceIdentity(
        _ sourceRootDescriptor: Int32,
        parent: String,
        name: String,
        expected: WorktreeForkEntryIdentity,
        path: String
    ) throws(GitWorktreeForkError) {
        let parentDescriptor: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: sourceRootDescriptor, relativePath: parent) {
        case .success(let opened):
            parentDescriptor = opened
        case .failure(let failure):
            throw WorktreeForkSourceWalker.sourceFailure(relativePath: path, errorNumber: failure.code)
        }
        defer { close(parentDescriptor) }
        switch WorktreeForkDescriptors.statEntry(in: parentDescriptor, name: name) {
        case .success(let info) where WorktreeForkEntryIdentity(info) == expected:
            return
        case .success:
            throw .sourceChanged(relativePath: path, reason: .entryIdentityChanged)
        case .failure(let failure):
            throw WorktreeForkSourceWalker.sourceFailure(relativePath: path, errorNumber: failure.code)
        }
    }
}

private struct WorktreeForkWorkerOutcome: Sendable {
    var firstFailure: GitWorktreeForkError?
    var observations = WorktreeForkMaterializationObservations()

    var hasFailure: Bool {
        firstFailure != nil
    }

    mutating func record(_ failure: GitWorktreeForkError) {
        if firstFailure == nil {
            firstFailure = failure
        }
    }
}
