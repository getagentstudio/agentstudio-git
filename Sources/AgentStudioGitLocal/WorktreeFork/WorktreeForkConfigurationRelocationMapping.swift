import AgentStudioGitContracts
import Foundation

/// The relocations re-homing authorizes for one configuration entry, as a pure function of the entry and the
/// source/destination copy holding it. The re-homer applies them; the validator recomputes them from the
/// unchanged source files and compares, so neither trusts the other's outcome.
struct WorktreeForkConfigurationRelocationMapping: Sendable {
    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation

    struct ValueRelocation: Sendable {
        let replacement: String?
        /// The source path the value names and its destination counterpart, when the path relocates.
        let relocatedSource: URL?
        let relocatedDestination: URL?
    }

    /// The new value for an entry (nil to keep it) and, when its path relocates, the source and destination it
    /// stands for. An absolute value is re-aimed at its relocated
    /// counterpart. A relative include is re-aimed only when, read from the copy, it no longer reaches what it
    /// reached from the source. Values outside the source or in the shared repository keep their target; a
    /// source path with no counterpart fails.
    func valueRelocation(
        for entry: WorktreeForkConfigurationEntry,
        in copy: WorktreeForkConfigurationCopy
    ) throws(GitWorktreeForkError) -> ValueRelocation {
        guard let form = WorktreeForkConfigurationIncludes.pathForm(name: entry.name, value: entry.value) else {
            return ValueRelocation(replacement: nil, relocatedSource: nil, relocatedDestination: nil)
        }
        let source = WorktreeForkConfigurationIncludes.target(
            of: entry.value, includedFrom: copy.source, homeDirectory: plan.homeDirectory)
        let wanted: URL
        var relocatedDestination: URL?
        switch relocation.counterpart(of: source) {
        case .outsideSource, .sharedRepository:
            wanted = source
        case .relocated(let destination):
            relocatedDestination = destination
            wanted = destination
        case .unmapped:
            let sourcePath =
                WorktreeForkAdministrativeSymlinks.relativeComponents(of: source, beneath: plan.sourceRoot)
                ?? source.lastPathComponent
            throw .entryFailed(
                relativePath: "\(copy.reportPath): \(entry.name) = \(sourcePath)",
                reason: .unresolvableGitAdministration,
                errorNumber: nil
            )
        }
        let reachedFromCopy =
            form == .absolute
            ? entry.value
            : WorktreeForkConfigurationIncludes.target(
                of: entry.value, includedFrom: copy.destination, homeDirectory: plan.homeDirectory
            ).path
        let keepsText = reachedFromCopy == wanted.path || (form == .absolute && wanted == source)
        return ValueRelocation(
            replacement: keepsText ? nil : wanted.path,
            relocatedSource: relocatedDestination.map { _ in source },
            relocatedDestination: relocatedDestination)
    }

    /// The new subsection for a `gitdir` conditional include whose pattern names a relocated location, or nil
    /// to keep it. Patterns outside the source or in the shared repository keep their target. A glob that could
    /// match beneath a location that relocates differently has no exact counterpart, so it fails.
    func relocatedConditionSubsection(
        for entry: WorktreeForkConfigurationEntry,
        in copy: WorktreeForkConfigurationCopy
    ) throws(GitWorktreeForkError) -> String? {
        guard let condition = WorktreeForkGitDirectoryCondition.parse(includeName: entry.name),
            let source = condition.location(includedFrom: copy.source, homeDirectory: plan.homeDirectory)
        else {
            return nil
        }
        let sourceLiteral =
            WorktreeForkAdministrativeSymlinks.relativeComponents(of: source.literal, beneath: plan.sourceRoot)
            ?? source.literal.lastPathComponent
        let displayedPattern = WorktreeForkGitDirectoryCondition.pattern(literal: sourceLiteral, following: source)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let unresolvable = GitWorktreeForkError.entryFailed(
            relativePath: "\(copy.reportPath): includeif.\(condition.prefix)\(displayedPattern).path",
            reason: .unresolvableGitAdministration,
            errorNumber: nil
        )
        switch relocation.counterpart(of: source.literal) {
        case .outsideSource, .sharedRepository:
            return nil
        case .unmapped:
            throw unresolvable
        case .relocated(let destination):
            if source.matchesBeneathLiteral, relocation.hasRelocation(strictlyBeneath: source.literal) {
                throw unresolvable
            }
            // A `./` pattern that still reaches the counterpart from the copy keeps its text.
            if condition.location(includedFrom: copy.destination, homeDirectory: plan.homeDirectory)?.literal.path
                == destination.path
            {
                return nil
            }
            return condition.subsection(
                withPattern: WorktreeForkGitDirectoryCondition.pattern(literal: destination.path, following: source))
        }
    }

    /// The entries `copy.destination` must hold: the source file's own entries in order, repeats kept, each with
    /// exactly its authorized value and `gitdir` condition relocation applied.
    func expectedEntries(
        of sourceEntries: [WorktreeForkConfigurationEntry],
        in copy: WorktreeForkConfigurationCopy
    ) throws(GitWorktreeForkError) -> [WorktreeForkConfigurationEntry] {
        var expected: [WorktreeForkConfigurationEntry] = []
        for entry in sourceEntries {
            var name = entry.name
            if let subsection = try relocatedConditionSubsection(for: entry, in: copy) {
                name = "includeif.\(subsection).path"
            }
            let value = try valueRelocation(for: entry, in: copy).replacement ?? entry.value
            expected.append(WorktreeForkConfigurationEntry(name: name, value: value))
        }
        return expected
    }
}
