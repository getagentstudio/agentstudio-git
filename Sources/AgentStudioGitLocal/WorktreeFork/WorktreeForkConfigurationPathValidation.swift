import AgentStudioGitContracts
import Foundation

/// Proves the re-homed configuration closure, independently of the re-homer, in two walks:
///
/// - the destination closure, external files included, must hold no value that still names a source location
///   the fork relocates elsewhere, or one with no counterpart;
/// - the unchanged source closure decides what each reference requires. Every source value naming relocated
///   administration gives an exact source target and the destination that must stand for it: present when the
///   source is present and absent when it is absent, one source per destination name, an included
///   configuration file holding exactly the source's entries with the authorized relocations applied, and any
///   other file equivalent to its source. Unreferenced files that merely share a name are irrelevant.
struct WorktreeForkConfigurationPathValidation: Sendable {
    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation

    func validate(_ roots: [WorktreeForkConfigurationCopy]) throws(GitWorktreeForkError) {
        try validateNoSourceReferences(roots.map { ($0.destination, $0.reportPath) })
        try validateRequiredCounterparts(roots)
    }

    private func validateNoSourceReferences(_ roots: [(file: URL, reportPath: String)]) throws(GitWorktreeForkError) {
        var visited = Set<String>()
        var pending = roots.map { (file: $0.file, reportPath: $0.reportPath, depth: 0) }
        while let (file, reportPath, depth) = pending.popLast() {
            let leftover = GitWorktreeForkError.validationFailed(
                reason: .sourceAdministrationReference, relativePath: reportPath)
            guard visited.insert(file.path).inserted, try exists(file, otherwise: leftover) else {
                continue
            }
            guard depth <= WorktreeForkConfigurationIncludes.maximumDepth else {
                throw leftover
            }
            let entries: [WorktreeForkConfigurationEntry]
            do {
                entries = try WorktreeForkConfigurationFile.ownEntries(in: file, reportPath: reportPath)
            } catch {
                throw WorktreeForkDatalessGuardedRead.isDatalessRefusal(error) ? error : leftover
            }
            for entry in entries {
                if let condition = WorktreeForkGitDirectoryCondition.parse(includeName: entry.name),
                    let location = condition.location(includedFrom: file, homeDirectory: plan.homeDirectory),
                    !WorktreeForkDestinationOwnership.isDestinationOwned(location.literal, plan: plan),
                    relocation.namesRelocatedSource(location.literal)
                {
                    throw leftover
                }
                guard WorktreeForkConfigurationIncludes.pathForm(name: entry.name, value: entry.value) != nil else {
                    continue
                }
                let target = WorktreeForkConfigurationIncludes.target(
                    of: entry.value, includedFrom: file, homeDirectory: plan.homeDirectory)
                if !WorktreeForkDestinationOwnership.isDestinationOwned(target, plan: plan),
                    relocation.namesRelocatedSource(target)
                {
                    throw leftover
                }
                // External includes are walked too: they are never edited, so a leftover there is a leak.
                if WorktreeForkConfigurationIncludes.isInclude(entry.name) {
                    pending.append(
                        (
                            target, WorktreeForkDestinationOwnership.reportLocation(of: target, plan: plan),
                            depth + 1
                        ))
                }
            }
        }
    }

    /// A configuration file reached in the source closure, with the report path of the file whose reference
    /// reached it (nil for a repository's own configuration, which no reference requires).
    private struct ReachedFile {
        let copy: WorktreeForkConfigurationCopy
        let referencedBy: String?
        let depth: Int
    }

    private func validateRequiredCounterparts(_ roots: [WorktreeForkConfigurationCopy]) throws(GitWorktreeForkError) {
        let mapping = WorktreeForkConfigurationRelocationMapping(plan: plan, relocation: relocation)
        var requiredSources: [String: URL] = [:]
        var visited = Set<String>()
        var pending = roots.map { ReachedFile(copy: $0, referencedBy: nil, depth: 0) }
        while let reached = pending.popLast() {
            let copy = reached.copy
            let unusable = GitWorktreeForkError.validationFailed(
                reason: .nestedRepositoryUnusable, relativePath: reached.referencedBy ?? copy.reportPath)
            // A repository without this file (no config.worktree) has nothing to require. A source file that
            // cannot even be looked up is unverifiable, never absent.
            guard visited.insert(copy.source.path).inserted, try exists(copy.source, otherwise: unusable) else {
                continue
            }
            // The unchanged source decides what is required; a source configuration that cannot be read is a
            // failure, never a skip.
            let sourceEntries = try orderedEntries(of: copy.source, reportPath: copy.reportPath, otherwise: unusable)
            if reached.referencedBy != nil {
                // An included file the fork owns: the source's entries in order, repeats kept, with exactly the
                // authorized relocations.
                guard reached.depth <= WorktreeForkConfigurationIncludes.maximumDepth else {
                    throw unusable
                }
                let destinationEntries = try orderedEntries(
                    of: copy.destination, reportPath: copy.reportPath, otherwise: unusable)
                let expected: [WorktreeForkConfigurationEntry]
                do {
                    expected = try mapping.expectedEntries(of: sourceEntries, in: copy)
                } catch {
                    throw unusable
                }
                guard destinationEntries == expected else {
                    throw unusable
                }
            }
            for entry in sourceEntries {
                guard WorktreeForkConfigurationIncludes.pathForm(name: entry.name, value: entry.value) != nil else {
                    continue
                }
                let source = WorktreeForkConfigurationIncludes.target(
                    of: entry.value, includedFrom: copy.source, homeDirectory: plan.homeDirectory)
                guard case .relocated(let destination) = relocation.counterpart(of: source),
                    WorktreeForkDestinationOwnership.isDestinationOwned(destination, plan: plan)
                else {
                    continue
                }
                let isInclude = WorktreeForkConfigurationIncludes.isInclude(entry.name)
                if let match = relocation.administrationMatch(of: source) {
                    try requireCounterpart(
                        of: source, at: destination, match: match, comparesBytes: !isInclude,
                        requiredSources: &requiredSources, reportPath: copy.reportPath)
                }
                if isInclude, try exists(source, otherwise: unusable) {
                    pending.append(
                        ReachedFile(
                            copy: WorktreeForkConfigurationCopy(
                                source: source, destination: destination,
                                reportPath: WorktreeForkDestinationOwnership.reportLocation(
                                    of: destination, plan: plan)),
                            referencedBy: copy.reportPath, depth: reached.depth + 1))
                }
            }
        }
    }

    /// Whether `file` exists; any lookup failure other than absence is `otherwise`.
    private func exists(_ file: URL, otherwise failure: GitWorktreeForkError) throws(GitWorktreeForkError) -> Bool {
        switch WorktreeForkDescriptors.existence(file) {
        case .success(let exists):
            return exists
        case .failure:
            throw failure
        }
    }

    /// A dataless file fails as itself; any other read failure is `otherwise`.
    private func orderedEntries(
        of file: URL,
        reportPath: String,
        otherwise failure: GitWorktreeForkError
    ) throws(GitWorktreeForkError) -> [WorktreeForkConfigurationEntry] {
        do {
            return try WorktreeForkConfigurationFile.orderedEntries(in: file, reportPath: reportPath)
        } catch {
            throw WorktreeForkDatalessGuardedRead.isDatalessRefusal(error) ? error : failure
        }
    }

    /// One reference into relocated administration: `destination` must stand for `source` and nothing else.
    private func requireCounterpart(
        of source: URL,
        at destination: URL,
        match: WorktreeForkSourcePathRelocation.AdministrationMatch,
        comparesBytes: Bool,
        requiredSources: inout [String: URL],
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let unusable = GitWorktreeForkError.validationFailed(
            reason: .nestedRepositoryUnusable, relativePath: reportPath)
        if let required = requiredSources[destination.path] {
            if required != source {
                let agree = try WorktreeForkPrivateAdministrationCounterparts.sourcesAgree(
                    required, source, relocation: relocation, reportPath: reportPath)
                guard agree else {
                    throw unusable
                }
            }
        } else {
            requiredSources[destination.path] = source
        }
        // Files re-homing writes itself (HEAD, worktree configuration) legitimately differ from their source.
        let writtenByRehoming = WorktreeForkPrivateAdministrationCounterparts.filesWrittenByRehoming.contains(
            match.remainder)
        switch (try exists(source, otherwise: unusable), try exists(destination, otherwise: unusable)) {
        case (true, false):
            throw unusable
        case (false, true) where !writtenByRehoming:
            // Git finds nothing in the source but would read a stand-in in the destination.
            throw unusable
        case (true, true) where comparesBytes && !writtenByRehoming:
            guard case .success(let sourceInfo) = WorktreeForkDescriptors.lstatPath(source) else {
                throw unusable
            }
            guard sourceInfo.st_mode & S_IFMT == S_IFREG else {
                return
            }
            let equivalent = try WorktreeForkFileEquivalence.isEquivalent(
                .init(root: match.sourceAdministration, remainder: match.remainder),
                .init(root: match.destinationAdministration, remainder: match.remainder),
                reportPath: reportPath)
            guard equivalent else {
                throw unusable
            }
        default:
            return
        }
    }
}
