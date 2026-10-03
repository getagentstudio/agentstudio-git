import AgentStudioGitContracts
import Darwin
import Foundation

/// Gives a re-homed configuration value the right file to name. Re-homing re-aims a value that names a
/// captured worktree's private administration (an `allowed_signers` or included `extra.conf` there) at the
/// destination administration, but only the files re-homing writes itself come from that private source. Git
/// silently ignores a missing include or signer file, and a flattened node's administration is cloned from
/// the common administration, which may hold a different file under the same name. Git reads the
/// worktree-private file, so the private source wins: a missing counterpart is strictly cloned, and an
/// existing one that is not equivalent to it is replaced through the metadata-preserving rewrite. A source
/// entry that does not exist stays absent, exactly as Git finds nothing in the source either.
///
/// One destination name can stand for two sources: a flattened node's common and private administration both
/// land in one destination directory. When values require that name from two sources that differ, no single
/// file serves both, so the fork fails rather than silently giving one reference the other's bytes.
///
/// Every traversal is descriptor-relative beneath the two administration roots, so a symlink swapped into
/// either path fails instead of escaping. Every counterpart lands inside administration the rollback journal
/// already owns (the destination tree, nested `modules/` administration, or the fork's own administration),
/// so it needs no entry of its own.
struct WorktreeForkPrivateAdministrationCounterparts: Sendable {
    /// Private files re-homing writes itself from their source (rewritten or rebuilt), so a value naming one
    /// already has its counterpart and its bytes legitimately differ from the source.
    static let filesWrittenByRehoming: Set<String> = ["HEAD", "config.worktree", "info/sparse-checkout", "index"]

    /// Points in one realization a caller can observe, in order, for each remainder component.
    enum RealizationCheckpoint: Equatable, Sendable {
        /// Both parent descriptors for the entry are open; nothing about the entry has been examined.
        case parentsOpened(entryPath: String)
        /// An existing target was stat'ed through its parent; it has not been opened yet.
        case targetExamined(entryPath: String)
    }

    /// What one realization produced.
    enum Realization: Sendable {
        case unchanged
        case clonedFile([GitWorktreeMaterializationNormalizedEntry])
        case clonedDirectory(WorktreeForkClonedAdministrationTree)
    }

    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation
    /// Directories cloned here; their metadata is reproduced with the rest of the cloned administration.
    private(set) var administrationTrees: [WorktreeForkClonedAdministrationTree] = []
    private(set) var normalizedEntries: [GitWorktreeMaterializationNormalizedEntry] = []
    /// The source each relocated destination path is required from, keyed by destination path.
    private var requiredSources: [String: URL] = [:]
    /// Destination paths already realized from their required source. The re-homer may then edit the copy (an
    /// include's relocated values), so a later reference to the same source must not compare it with the
    /// unedited source and clone the source bytes back over those edits.
    private var realizedDestinations: Set<String> = []

    init(plan: WorktreeForkPlan, relocation: WorktreeForkSourcePathRelocation) {
        self.plan = plan
        self.relocation = relocation
    }

    /// Records that a value requires `destination` to stand for `source` (canonical), then realizes the
    /// counterpart when `source` lies in a captured private administration. A destination already required
    /// from a different, non-equivalent source fails.
    mutating func materializeCounterpart(of source: URL, at destination: URL) throws(GitWorktreeForkError) {
        try requireSingleSource(source, at: destination)
        // `requireSingleSource` has proven any earlier realization here came from this same source.
        guard realizedDestinations.insert(destination.path).inserted,
            let match = relocation.privateAdministrationMatch(of: source),
            !Self.filesWrittenByRehoming.contains(match.remainder)
        else {
            return
        }
        let plan = plan
        let realization = try Self.realize(match) { remainder in
            WorktreeForkDestinationOwnership.reportLocation(
                of: match.destinationAdministration.appending(path: remainder), plan: plan)
        }
        switch realization {
        case .unchanged:
            return
        case .clonedFile(let normalized):
            normalizedEntries += normalized
        case .clonedDirectory(let tree):
            administrationTrees.append(tree)
        }
    }

    private mutating func requireSingleSource(_ source: URL, at destination: URL) throws(GitWorktreeForkError) {
        guard let required = requiredSources[destination.path] else {
            requiredSources[destination.path] = source
            return
        }
        guard required != source,
            try !Self.sourcesAgree(required, source, relocation: relocation, reportPath: reportPath(of: destination))
        else {
            return
        }
        throw .entryFailed(
            relativePath: reportPath(of: destination), reason: .unresolvableGitAdministration, errorNumber: nil)
    }

    private func reportPath(of destination: URL) -> String {
        WorktreeForkDestinationOwnership.reportLocation(of: destination, plan: plan)
    }

    /// Two sources agree when neither exists (Git finds nothing through either) or both are equivalent files.
    /// Only sources in relocated administration can share a destination name; each is read descriptor-relative
    /// beneath its administration root.
    static func sourcesAgree(
        _ first: URL,
        _ second: URL,
        relocation: WorktreeForkSourcePathRelocation,
        reportPath: String
    ) throws(GitWorktreeForkError) -> Bool {
        let lookupFailed = GitWorktreeForkError.entryFailed(
            relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        let firstExists: Bool
        let secondExists: Bool
        switch (WorktreeForkDescriptors.existence(first), WorktreeForkDescriptors.existence(second)) {
        case (.success(let first), .success(let second)):
            (firstExists, secondExists) = (first, second)
        default:
            throw lookupFailed
        }
        switch (firstExists, secondExists) {
        case (false, false):
            return true
        case (true, true):
            guard let firstMatch = relocation.administrationMatch(of: first),
                let secondMatch = relocation.administrationMatch(of: second)
            else {
                return false
            }
            return try WorktreeForkFileEquivalence.isEquivalent(
                .init(root: firstMatch.sourceAdministration, remainder: firstMatch.remainder),
                .init(root: secondMatch.sourceAdministration, remainder: secondMatch.remainder),
                reportPath: reportPath)
        default:
            return false
        }
    }

    /// Walks `match.remainder` beneath both administration roots one component at a time. The topmost
    /// destination entry that is missing is cloned from its source; an existing regular-file target that is
    /// not equivalent to its source is replaced. `reportPath` maps a remainder prefix to its report location.
    /// Every destination operation goes through the parent descriptor opened for that entry, never a path, so
    /// a destination ancestor replaced after it was opened cannot redirect a write. `atCheckpoint` observes the
    /// points `RealizationCheckpoint` names.
    static func realize(
        _ match: WorktreeForkSourcePathRelocation.AdministrationMatch,
        reportPath: (String) -> String,
        atCheckpoint: (RealizationCheckpoint) -> Void = { _ in }
    ) throws(GitWorktreeForkError) -> Realization {
        let sourceRoot = try openRoot(match.sourceAdministration, reportPath: reportPath(""))
        defer { close(sourceRoot) }
        let destinationRoot = try openRoot(match.destinationAdministration, reportPath: reportPath(""))
        defer { close(destinationRoot) }
        let components = match.remainder.split(separator: "/").map(String.init)
        var parentPath = ""
        for (index, name) in components.enumerated() {
            let entryPath = WorktreeForkDescriptors.joined(parentPath, name)
            let report = reportPath(entryPath)
            let sourceParent = try openContainedDirectory(sourceRoot, parentPath, report, isSource: true)
            defer { close(sourceParent) }
            let destinationParent = try openContainedDirectory(destinationRoot, parentPath, report, isSource: false)
            defer { close(destinationParent) }
            atCheckpoint(.parentsOpened(entryPath: entryPath))
            guard let sourceInfo = try entryInfo(in: sourceParent, name: name, report: report) else {
                return .unchanged
            }
            let destinationInfo = try entryInfo(in: destinationParent, name: name, report: report)
            let sourceKind = WorktreeForkEntryKind(mode: sourceInfo.st_mode)
            let isTarget = index == components.count - 1
            switch (sourceKind, destinationInfo.map { WorktreeForkEntryKind(mode: $0.st_mode) }) {
            case (.symbolicLink, _):
                guard isTarget else {
                    throw .sourceChanged(relativePath: report, reason: .containmentEscape)
                }
                throw .entryFailed(relativePath: report, reason: .unsupportedEntryKind, errorNumber: nil)
            case (.directory, nil):
                let sourceDirectory = try openContainedDirectory(sourceParent, name, report, isSource: true)
                defer { close(sourceDirectory) }
                let cloner = WorktreeForkAdministrationCloner(reportPath: report)
                return .clonedDirectory(
                    try cloner.cloneTree(
                        fromDirectory: sourceDirectory, intoNewDirectory: name, beneath: destinationParent,
                        source: match.sourceAdministration.appending(path: entryPath),
                        destination: match.destinationAdministration.appending(path: entryPath)))
            case (.directory, .directory) where !isTarget:
                parentPath = entryPath
            case (.regularFile, nil) where isTarget:
                return .clonedFile(
                    try cloneFile(name, from: sourceParent, into: destinationParent, report: report))
            case (.regularFile, .regularFile) where isTarget:
                return try replaceIfDifferent(
                    name, sourceParent: sourceParent, destinationParent: destinationParent, report: report
                ) { atCheckpoint(.targetExamined(entryPath: entryPath)) }
            case (.regularFile, _) where !isTarget:
                return .unchanged
            case (.fifo, _), (.unixSocket, _), (.characterDevice, _), (.blockDevice, _), (.unknown, _):
                throw .entryFailed(relativePath: report, reason: .unsupportedEntryKind, errorNumber: nil)
            default:
                // A destination entry of another kind, or an existing directory target, cannot be made the
                // private source's counterpart without discarding what is there.
                throw .entryFailed(relativePath: report, reason: .unresolvableGitAdministration, errorNumber: nil)
            }
        }
        return .unchanged
    }

    /// Replaces the existing target with a clone of its source, entirely through `destinationParent` and the
    /// target's and clone's own descriptors: protection is lifted from the target, the clone gets the source's
    /// attributes and mode, is renamed into place, and only then gets the ACL and flags that would have
    /// forbidden the rename. Before the rename, a failure puts the target's protection back.
    private static func replaceIfDifferent(
        _ name: String,
        sourceParent: Int32,
        destinationParent: Int32,
        report: String,
        targetExamined: () -> Void
    ) throws(GitWorktreeForkError) -> Realization {
        let source = try openSourceFile(name, in: sourceParent, report: report)
        defer { close(source) }
        guard case .success(let targetInfo) = WorktreeForkDescriptors.statEntry(in: destinationParent, name: name)
        else {
            throw .entryFailed(relativePath: report, reason: .unresolvableGitAdministration, errorNumber: errno)
        }
        // Swapping one name of a hard-link group would split it from its other names.
        guard targetInfo.st_nlink == 1 else {
            throw .entryFailed(relativePath: report, reason: .metadataNotReproducible, errorNumber: nil)
        }
        targetExamined()
        let target = try openTarget(name, in: destinationParent, info: targetInfo, report: report)
        defer { close(target) }
        if try WorktreeForkFileEquivalence.isEquivalent(source, target, reportPath: report) {
            return .unchanged
        }
        let protection = try WorktreeForkReplacementProtection.lift(
            descriptor: target, originalInfo: targetInfo, reportPath: report)
        let temporary = ".\(name).agentstudio-\(UUID().uuidString).tmp"
        var renamed = false
        do throws(GitWorktreeForkError) {
            let metadata = try WorktreeForkFileMetadata.capture(fromDescriptor: source, reportPath: report)
            let clone = try cloneUnprotected(source, as: temporary, into: destinationParent, report: report)
            defer { close(clone) }
            try metadata.applyAttributesAndMode(toDescriptor: clone, reportPath: report)
            let renameResult = temporary.withCString { temporaryName in
                name.withCString { renameat(destinationParent, temporaryName, destinationParent, $0) }
            }
            guard renameResult == 0 else {
                throw .entryFailed(relativePath: report, reason: .entryCreationFailed, errorNumber: errno)
            }
            renamed = true
            try metadata.applyAccessControlAndFlags(toDescriptor: clone, reportPath: report)
        } catch {
            if !renamed {
                _ = temporary.withCString { unlinkat(destinationParent, $0, 0) }
                try? protection.restore(reportPath: report)
            }
            throw error
        }
        return .clonedFile(try normalization(source: source, name: name, in: destinationParent, report: report))
    }

    /// Opens the existing target beneath `destinationParent` without following it and proves the open inode is
    /// the one examined, still with no other link. Nothing about the target changes before that proof: the name
    /// may by now be a hard link to a source file, so a target its owner cannot read fails instead of being
    /// granted read by name.
    private static func openTarget(
        _ name: String,
        in destinationParent: Int32,
        info: Darwin.stat,
        report: String
    ) throws(GitWorktreeForkError) -> Int32 {
        let target = name.withCString { openat(destinationParent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard target >= 0 else {
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: errno)
        }
        guard case .success(let opened) = WorktreeForkDescriptors.statDescriptor(target),
            WorktreeForkEntryIdentity(opened) == WorktreeForkEntryIdentity(info), opened.st_nlink == 1
        else {
            close(target)
            throw .entryFailed(relativePath: report, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        return target
    }

    private static func cloneFile(
        _ name: String,
        from sourceParent: Int32,
        into destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        let source = try openSourceFile(name, in: sourceParent, report: report)
        defer { close(source) }
        try strictClone(source, as: name, into: destinationParent, report: report)
        return try normalization(source: source, name: name, in: destinationParent, report: report)
    }

    /// Clones under a temporary name and returns the clone's descriptor, with the clone's flags and ACL
    /// cleared and owner write granted: a user-immutable flag or a `deny delete` entry would forbid renaming it
    /// into place, and a read-only mode would refuse its extended attributes. The caller applies the source's
    /// metadata through the returned descriptor. On failure nothing is left under the temporary name.
    private static func cloneUnprotected(
        _ source: Int32,
        as temporary: String,
        into destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) -> Int32 {
        try strictClone(source, as: temporary, into: destinationParent, report: report)
        let clone = temporary.withCString { openat(destinationParent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        var failure: Int32 = clone < 0 ? errno : 0
        if failure == 0, fchflags(clone, 0) != 0 { failure = errno }
        if failure == 0 { failure = WorktreeForkDescriptorMetadata.removeAccessControlList(clone) }
        if failure == 0, fchmod(clone, 0o600) != 0 { failure = errno }
        guard failure == 0 else {
            if clone >= 0 {
                close(clone)
            }
            _ = temporary.withCString { unlinkat(destinationParent, $0, 0) }
            throw .entryFailed(relativePath: report, reason: .entryCreationFailed, errorNumber: failure)
        }
        return clone
    }

    private static func strictClone(
        _ source: Int32,
        as name: String,
        into destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: report) {
            () throws(GitWorktreeForkError) in
            let cloned = name.withCString {
                fclonefileat(source, destinationParent, $0, WorktreeForkLeafWorker.cloneFlags)
            }
            guard cloned == 0 else {
                throw .entryFailed(relativePath: report, reason: .strictCloneFailed, errorNumber: errno)
            }
        }
    }

    private static func openSourceFile(
        _ name: String,
        in sourceParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) -> Int32 {
        let source = name.withCString { openat(sourceParent, $0, WorktreeForkLeafWorker.leafOpenFlags) }
        guard source >= 0 else {
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: errno)
        }
        switch WorktreeForkDescriptors.statDescriptor(source) {
        case .success(let info) where info.st_mode & S_IFMT == S_IFREG:
            guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
                close(source)
                throw .entryFailed(relativePath: report, reason: .datalessFile, errorNumber: nil)
            }
            return source
        case .success:
            close(source)
            throw .sourceChanged(relativePath: report, reason: .entryKindChanged)
        case .failure(let failure):
            close(source)
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: failure.code)
        }
    }

    private static func normalization(
        source: Int32,
        name: String,
        in destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        guard case .success(let sourceInfo) = WorktreeForkDescriptors.statDescriptor(source) else {
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: nil)
        }
        switch WorktreeForkDescriptors.statEntry(in: destinationParent, name: name) {
        case .success(let destinationInfo):
            return try WorktreeForkEntryMetadata.normalization(
                source: sourceInfo, destination: destinationInfo, relativePath: report)
        case .failure(let failure):
            throw .entryFailed(relativePath: report, reason: .entryCreationFailed, errorNumber: failure.code)
        }
    }

    /// The entry's lstat information, or nil when it does not exist.
    private static func entryInfo(
        in parent: Int32,
        name: String,
        report: String
    ) throws(GitWorktreeForkError) -> Darwin.stat? {
        switch WorktreeForkDescriptors.statEntry(in: parent, name: name) {
        case .success(let info):
            return info
        case .failure(let failure) where failure.code == ENOENT:
            return nil
        case .failure(let failure):
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: failure.code)
        }
    }

    private static func openRoot(_ root: URL, reportPath: String) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: root) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }

    /// Opens `relativePath` beneath `root` with no symlink anywhere in it. A symlink in the source path is a
    /// containment escape; anything else that stops the open fails the counterpart.
    private static func openContainedDirectory(
        _ root: Int32,
        _ relativePath: String,
        _ report: String,
        isSource: Bool
    ) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openDirectory(beneath: root, relativePath: relativePath) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure) where isSource && (failure.code == ELOOP || failure.code == ENOTDIR):
            throw .sourceChanged(relativePath: report, reason: .containmentEscape)
        case .failure(let failure):
            throw .entryFailed(
                relativePath: report, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }
}
