import Foundation

/// Where a source path lives after the fork. The longest matching source location decides:
///
/// - the private administration of the source worktree (when it is linked) moves to the fork's private
///   administration, and each nested node's administration (common and private) moves to its re-homed
///   administration;
/// - the rest of the source repository's common directory is shared, not moved: the fork is a linked worktree
///   of that same repository. That covers shared files (objects, refs, configuration) and the private
///   administration of any other worktree the fork does not capture, which the fork sees exactly as the source
///   does;
/// - the source tree moves to the destination tree, except beneath a `.git` entry that none of the above owns.
///
/// So a path inside relocated administration never takes the plain tree substitution (the fork's own `.git`
/// is a gitfile, not the source's administration directory).
struct WorktreeForkSourcePathRelocation: Sendable {
    enum Counterpart: Equatable, Sendable {
        /// Outside every relocated location: the path keeps its target.
        case outsideSource
        /// In the source repository's shared common directory: the fork names the same path.
        case sharedRepository
        case relocated(URL)
        /// Beneath a source `.git` entry that no re-homed administration owns. Nothing was copied there, so
        /// there is no destination counterpart to name.
        case unmapped
    }

    private enum Disposition: Sendable {
        case sourceTree(URL)
        case administration(URL)
        case sharedRepository
    }

    private struct Relocation: Sendable {
        let source: URL
        let disposition: Disposition
        /// A worktree's private administration (its own `HEAD`, index, and private files), as opposed to a
        /// repository's common administration. Only a few private files are written for the destination, so
        /// anything else a value names there must be cloned on demand.
        var isPrivateAdministration = false
    }

    /// A source path inside relocated administration, split at that administration.
    struct AdministrationMatch: Equatable, Sendable {
        let sourceAdministration: URL
        let destinationAdministration: URL
        /// `/`-separated path beneath both administrations; never empty.
        let remainder: String
        /// A worktree's private administration rather than a repository's common administration.
        var isPrivate = true
    }

    private let relocations: [Relocation]

    init(plan: WorktreeForkPlan, administrationByNode: [String: URL]) {
        var relocations = [
            Relocation(source: plan.sourceRoot, disposition: .sourceTree(plan.destinationRoot)),
            Relocation(source: plan.commonDirectory, disposition: .sharedRepository),
        ]
        if plan.sourceGitDirectory != plan.commonDirectory {
            let forkAdministration = plan.commonDirectory.appending(path: "worktrees").appending(
                path: plan.worktreeName)
            relocations.append(
                Relocation(
                    source: plan.sourceGitDirectory, disposition: .administration(forkAdministration),
                    isPrivateAdministration: true))
        }
        for node in plan.gitTopology.nodes {
            guard let administration = administrationByNode[node.relativePath] else {
                continue
            }
            // A nested linked worktree of the source repository shares its common directory; only its
            // private administration is the node's own.
            for sourceAdministration in Set([node.sourceCommonDirectory, node.sourceGitDirectory])
            where sourceAdministration != plan.commonDirectory {
                relocations.append(
                    Relocation(
                        source: sourceAdministration, disposition: .administration(administration),
                        isPrivateAdministration: sourceAdministration == node.sourceGitDirectory
                            && node.sourceGitDirectory != node.sourceCommonDirectory))
            }
        }
        self.relocations = relocations
    }

    /// `path` must be canonical (see `canonicalized(absolutePath:)`).
    func counterpart(of path: URL) -> Counterpart {
        guard let match = longestMatch(of: path) else {
            return .outsideSource
        }
        let destination: URL
        switch match.relocation.disposition {
        case .sharedRepository:
            return .sharedRepository
        case .sourceTree(let destinationRoot):
            if match.remainder.split(separator: "/").dropLast().contains(".git") {
                return .unmapped
            }
            destination = destinationRoot
        case .administration(let administration):
            destination = administration
        }
        return .relocated(match.remainder.isEmpty ? destination : destination.appending(path: match.remainder))
    }

    /// The private administration `path` lies beneath when that is the location deciding its counterpart.
    /// `path` must be canonical.
    func privateAdministrationMatch(of path: URL) -> AdministrationMatch? {
        administrationMatch(of: path).flatMap { $0.isPrivate ? $0 : nil }
    }

    /// The administration, common or private, `path` lies beneath when that is the location deciding its
    /// counterpart. `path` must be canonical.
    func administrationMatch(of path: URL) -> AdministrationMatch? {
        guard let match = longestMatch(of: path), !match.remainder.isEmpty,
            case .administration(let destinationAdministration) = match.relocation.disposition
        else {
            return nil
        }
        return AdministrationMatch(
            sourceAdministration: match.relocation.source, destinationAdministration: destinationAdministration,
            remainder: match.remainder, isPrivate: match.relocation.isPrivateAdministration)
    }

    private func longestMatch(of path: URL) -> (relocation: Relocation, remainder: String)? {
        relocations
            .compactMap { relocation -> (relocation: Relocation, remainder: String)? in
                WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: relocation.source)
                    .map { (relocation, $0) }
            }
            .max { $0.relocation.source.pathComponents.count < $1.relocation.source.pathComponents.count }
    }

    /// True when some relocated location lies strictly beneath `path`, so a pattern matching below `path` could
    /// reach locations that relocate differently.
    func hasRelocation(strictlyBeneath path: URL) -> Bool {
        relocations.contains { relocation in
            WorktreeForkAdministrativeSymlinks.relativeComponents(of: relocation.source, beneath: path)
                .map { !$0.isEmpty } ?? false
        }
    }

    /// Canonical form of an absolute path whose tail may not exist (a missing include, a store created on
    /// demand): the deepest existing ancestor is resolved and the rest appended, so `/var/...` and
    /// `/private/var/...` compare equal.
    static func canonicalized(absolutePath: String) -> URL {
        var existing = URL(fileURLWithPath: absolutePath).standardizedFileURL
        var missing: [String] = []
        while case .failure = WorktreeForkDescriptors.realpathURL(existing), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(existing) else {
            return URL(fileURLWithPath: absolutePath).standardizedFileURL
        }
        return missing.reduce(canonical) { $0.appending(path: $1) }
    }
}
