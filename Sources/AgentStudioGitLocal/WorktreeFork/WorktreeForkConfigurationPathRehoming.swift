import AgentStudioGitContracts
import Foundation

/// One configuration file the fork owns a copy of, paired with the source file it was copied from, so a
/// relative include in the copy can be resolved the way Git resolved it in the source.
struct WorktreeForkConfigurationCopy: Sendable {
    let source: URL
    let destination: URL
    let reportPath: String

    /// A repository's own configuration files: shared `config` from its common administration and
    /// worktree-scoped `config.worktree` from its private administration.
    static func repositoryFiles(
        sourceCommonDirectory: URL,
        sourceGitDirectory: URL,
        destinationAdministration: URL,
        reportPath: String
    ) -> [Self] {
        [
            Self(
                source: sourceCommonDirectory.appending(path: "config"),
                destination: destinationAdministration.appending(path: "config"),
                reportPath: "\(reportPath)/config"),
            Self(
                source: sourceGitDirectory.appending(path: "config.worktree"),
                destination: destinationAdministration.appending(path: "config.worktree"),
                reportPath: "\(reportPath)/config.worktree"),
        ]
    }
}

/// Git's include rules, shared by the re-homer and the validator.
enum WorktreeForkConfigurationIncludes {
    /// Git refuses configuration nested deeper than this many includes.
    static let maximumDepth = 10

    /// `include.path` and every `includeIf.<condition>.path`, as libgit2 names them.
    static func isInclude(_ name: String) -> Bool {
        name == "include.path" || (name.hasPrefix("includeif.") && name.hasSuffix(".path"))
    }

    /// How Git reads a configuration value as a path, or nil when it is not one. Any value starting with `/`
    /// is absolute (a diff driver's regex is never a path); an include value may also be `~/`-relative to
    /// the home directory or relative to the file holding it. The re-homer, the external walk, and the
    /// validator all classify through here.
    enum PathForm: Equatable, Sendable {
        case absolute
        case homeRelative
        case fileRelative
    }

    static func pathForm(name: String, value: String) -> PathForm? {
        guard !WorktreeForkConfigurationPatternKeys.holdsPattern(name) else {
            return nil
        }
        if value.hasPrefix("/") {
            return .absolute
        }
        guard isInclude(name) else {
            return nil
        }
        return value.hasPrefix("~/") ? .homeRelative : .fileRelative
    }

    /// The canonical file a path value names, resolved as Git does: `~/` against `homeDirectory`, a relative
    /// path against the directory of the file that holds it.
    static func target(of value: String, includedFrom file: URL, homeDirectory: URL) -> URL {
        let path: String
        if value.hasPrefix("~/") {
            path = homeDirectory.appending(path: String(value.dropFirst(2))).path
        } else if value.hasPrefix("/") {
            path = value
        } else {
            path = file.deletingLastPathComponent().appending(path: value).path
        }
        return WorktreeForkSourcePathRelocation.canonicalized(absolutePath: path)
    }
}

/// Keys whose values Git reads as regular expressions, not paths, so a value that happens to start with `/`
/// must not be relocated or validated as one: a diff driver's `xfuncname`, `funcname`, and `wordRegex`
/// (Git's `userdiff_config`). The re-homer and the validator both consult this one list.
enum WorktreeForkConfigurationPatternKeys {
    private static let diffDriverPatternVariables: Set<String> = ["xfuncname", "funcname", "wordregex"]

    static func holdsPattern(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.first?.lowercased() == "diff", let variable = parts.last else {
            return false
        }
        return diffDriverPatternVariables.contains(variable.lowercased())
    }
}

/// Re-aims the absolute paths that a repository's configuration records, across its whole include closure,
/// at their destination counterparts. Every reached file the fork owns a copy of (inside the destination
/// tree or the fork's own administration) is edited. A reached file the fork does not own (outside the
/// source, or in the shared repository) is never edited: it is read, with its own includes, and a value or
/// `gitdir` condition there naming a relocated source location refuses the fork, because the destination
/// would keep reading source state through it.
struct WorktreeForkConfigurationPathRehomer: Sendable {
    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation
    let lockTracker: WorktreeForkLockTracker

    private var mapping: WorktreeForkConfigurationRelocationMapping {
        WorktreeForkConfigurationRelocationMapping(plan: plan, relocation: relocation)
    }

    /// Returns the destination files it edited. Every relocated value that names a captured private
    /// administration gets its counterpart cloned through `counterparts` before an include there is followed.
    func rehome(
        _ roots: [WorktreeForkConfigurationCopy],
        counterparts: inout WorktreeForkPrivateAdministrationCounterparts
    ) throws(GitWorktreeForkError) -> [URL] {
        var edited: [URL] = []
        var visited = Set<String>()
        var pending = roots.map { (file: PendingFile.owned($0), depth: 0) }
        while let (file, depth) = pending.popLast() {
            let copy: WorktreeForkConfigurationCopy
            switch file {
            case .owned(let owned):
                copy = owned
            case .external(let external, let includedBy):
                guard visited.insert(external.path).inserted,
                    try Self.exists(external, reportPath: includedBy)
                else {
                    continue
                }
                guard depth <= WorktreeForkConfigurationIncludes.maximumDepth else {
                    throw .entryFailed(
                        relativePath: includedBy, reason: .unresolvableGitAdministration, errorNumber: nil)
                }
                pending += try externalIncludes(of: external, includedBy: includedBy).map { ($0, depth + 1) }
                continue
            }
            guard visited.insert(copy.destination.path).inserted,
                try Self.exists(copy.destination, reportPath: copy.reportPath)
            else {
                continue
            }
            let unresolvable = GitWorktreeForkError.entryFailed(
                relativePath: copy.reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
            guard depth <= WorktreeForkConfigurationIncludes.maximumDepth else {
                throw unresolvable
            }
            var edits: [WorktreeForkConfigurationEdit] = []
            // Relocated `includeIf` subsections, old to new, renamed in place before any value edit.
            var renamedSubsections: [String: String] = [:]
            for entry in try Self.ownEntries(of: copy) {
                let valueRelocation = try mapping.valueRelocation(for: entry, in: copy)
                if let relocatedSource = valueRelocation.relocatedSource,
                    let relocatedDestination = valueRelocation.relocatedDestination
                {
                    try counterparts.materializeCounterpart(of: relocatedSource, at: relocatedDestination)
                }
                let value = valueRelocation.replacement
                var name = entry.name
                if let condition = WorktreeForkGitDirectoryCondition.parse(includeName: entry.name),
                    let relocated = try mapping.relocatedConditionSubsection(for: entry, in: copy)
                {
                    renamedSubsections[condition.subsection] = relocated
                    name = "includeif.\(relocated).path"
                }
                if let value {
                    edits.append(.replaceValue(name, matching: entry.value, with: value))
                }
                guard WorktreeForkConfigurationIncludes.isInclude(entry.name) else {
                    continue
                }
                let sourceTarget = WorktreeForkConfigurationIncludes.target(
                    of: entry.value, includedFrom: copy.source, homeDirectory: plan.homeDirectory)
                switch relocation.counterpart(of: sourceTarget) {
                case .relocated(let destinationTarget)
                where WorktreeForkDestinationOwnership.isDestinationOwned(destinationTarget, plan: plan):
                    pending.append(
                        (
                            .owned(
                                WorktreeForkConfigurationCopy(
                                    source: sourceTarget, destination: destinationTarget,
                                    reportPath: WorktreeForkDestinationOwnership.reportLocation(
                                        of: destinationTarget, plan: plan))),
                            depth + 1
                        ))
                case .outsideSource, .sharedRepository:
                    pending.append((.external(sourceTarget, includedBy: copy.reportPath), depth + 1))
                case .relocated, .unmapped:
                    continue
                }
            }
            for (oldSubsection, newSubsection) in renamedSubsections.sorted(by: { $0.key < $1.key }) {
                try WorktreeForkConfigurationSectionRename.renameSubsection(
                    section: "includeIf", from: oldSubsection, to: newSubsection, in: copy.destination,
                    reportPath: copy.reportPath)
            }
            if !edits.isEmpty {
                try WorktreeForkConfigurationFile.apply(
                    edits, to: copy.destination, reportPath: copy.reportPath, lockTracker: lockTracker)
            }
            if !edits.isEmpty || !renamedSubsections.isEmpty {
                edited.append(copy.destination)
            }
        }
        return edited
    }

    /// A reached configuration file and whether the fork owns a copy of it. An external file is read in
    /// place; `includedBy` is the report path of the owned file whose include chain reached it.
    private enum PendingFile {
        case owned(WorktreeForkConfigurationCopy)
        case external(URL, includedBy: String)
    }

    /// Reads one external file read-only and refuses the fork when any path value or `gitdir` condition in
    /// it names a relocated source location; returns its own includes to read next.
    private func externalIncludes(
        of file: URL,
        includedBy: String
    ) throws(GitWorktreeForkError) -> [PendingFile] {
        let entries: [WorktreeForkConfigurationEntry]
        do {
            entries = try WorktreeForkConfigurationFile.ownEntries(in: file, reportPath: includedBy)
        } catch {
            if WorktreeForkDatalessGuardedRead.isDatalessRefusal(error) {
                throw error
            }
            throw .entryFailed(relativePath: includedBy, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        var includes: [PendingFile] = []
        for entry in entries {
            if let condition = WorktreeForkGitDirectoryCondition.parse(includeName: entry.name),
                let location = condition.location(includedFrom: file, homeDirectory: plan.homeDirectory),
                relocation.namesRelocatedSource(location.literal)
            {
                let pattern = WorktreeForkGitDirectoryCondition.pattern(
                    literal: sourceRelative(location.literal), following: location)
                throw .entryFailed(
                    relativePath: "\(includedBy): includeif.\(condition.prefix)\(pattern).path",
                    reason: .unresolvableGitAdministration, errorNumber: nil)
            }
            guard WorktreeForkConfigurationIncludes.pathForm(name: entry.name, value: entry.value) != nil else {
                continue
            }
            let isInclude = WorktreeForkConfigurationIncludes.isInclude(entry.name)
            let target = WorktreeForkConfigurationIncludes.target(
                of: entry.value, includedFrom: file, homeDirectory: plan.homeDirectory)
            if relocation.namesRelocatedSource(target) {
                throw .entryFailed(
                    relativePath: "\(includedBy): \(entry.name) = \(sourceRelative(target))",
                    reason: .unresolvableGitAdministration, errorNumber: nil)
            }
            if isInclude {
                includes.append(.external(target, includedBy: includedBy))
            }
        }
        return includes
    }

    private func sourceRelative(_ path: URL) -> String {
        WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: plan.sourceRoot)
            ?? path.lastPathComponent
    }

    /// Whether a reached file exists. Absence is ordinary (no config.worktree, a missing optional include);
    /// any other lookup failure leaves the closure unverifiable and fails the fork.
    private static func exists(_ file: URL, reportPath: String) throws(GitWorktreeForkError) -> Bool {
        switch WorktreeForkDescriptors.existence(file) {
        case .success(let exists):
            return exists
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }

    private static func ownEntries(
        of copy: WorktreeForkConfigurationCopy
    ) throws(GitWorktreeForkError) -> [WorktreeForkConfigurationEntry] {
        do {
            return try WorktreeForkConfigurationFile.ownEntries(in: copy.destination, reportPath: copy.reportPath)
        } catch {
            if WorktreeForkDatalessGuardedRead.isDatalessRefusal(error) {
                throw error
            }
            // libgit2 refuses a file whose own includes cycle or nest too deeply; Git refuses it too.
            throw .entryFailed(relativePath: copy.reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
    }
}

extension WorktreeForkSourcePathRelocation {
    /// True when `path` is a source location the fork relocates to somewhere else, or one with no counterpart.
    func namesRelocatedSource(_ path: URL) -> Bool {
        switch counterpart(of: path) {
        case .outsideSource, .sharedRepository:
            false
        case .relocated(let destination):
            destination.path != path.path
        case .unmapped:
            true
        }
    }
}

/// The places the fork owns: its destination tree and its own linked-worktree administration.
enum WorktreeForkDestinationOwnership {
    static func isDestinationOwned(_ path: URL, plan: WorktreeForkPlan) -> Bool {
        [plan.destinationRoot, forkAdministration(plan)].contains {
            WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: $0) != nil
        }
    }

    /// Destination-root-relative, or common-directory-relative for the fork's administration.
    static func reportLocation(of path: URL, plan: WorktreeForkPlan) -> String {
        WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: plan.destinationRoot)
            ?? WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: plan.commonDirectory)
            ?? path.lastPathComponent
    }

    private static func forkAdministration(_ plan: WorktreeForkPlan) -> URL {
        plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
    }
}
