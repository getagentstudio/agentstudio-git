import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Proves every re-homed Git node is independently usable and that no administrative pointer resolves
/// outside destination-owned state: the destination tree or the fork's own linked-worktree administration.
struct WorktreeForkTopologyValidator: Sendable {
    let plan: WorktreeForkPlan

    private var allowedPrefixes: [String] {
        [
            plan.destinationRoot.path + "/",
            plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName).path + "/",
        ]
    }

    func validate(
        _ rehomed: [WorktreeForkRehomedNode],
        evidenceByNode: [String: WorktreeForkIndexRefreshEvidence]
    ) throws(GitWorktreeForkError) {
        for path in plan.gitTopology.uninitializedSubmodulePaths {
            if case .success = WorktreeForkDescriptors.lstatPath(plan.destinationRoot.appending(path: "\(path)/.git")) {
                throw .validationFailed(reason: .submoduleStateMismatch, relativePath: path)
            }
        }
        for node in rehomed {
            try validateNode(node, evidence: evidenceByNode[node.node.relativePath])
        }
        try validateMirrorSymlinks()
        let relocation = WorktreeForkSourcePathRelocation(
            plan: plan,
            administrationByNode: Dictionary(
                uniqueKeysWithValues: rehomed.map { ($0.node.relativePath, $0.destinationAdministration) })
        )
        for copied in plan.gitTopology.copiedGitDirectories {
            try validateCopiedAlternates(copied, relocation: relocation)
            try validateCopiedRegistrations(copied)
        }
        try WorktreeForkConfigurationPathValidation(plan: plan, relocation: relocation).validate(
            GitRepositoryStateRehomer.configurationRoots(plan: plan, nodes: rehomed))
    }

    /// Every alternate a copied Git directory holds must resolve to destination-owned state (the destination
    /// tree or the fork's own administration, where object mirrors live) or to the source repository's shared
    /// common directory, which the fork itself uses. The one exception is a line that already dangled in the
    /// source, which the re-homer keeps as written.
    private func validateCopiedAlternates(
        _ copied: WorktreeForkCopiedGitDirectory,
        relocation: WorktreeForkSourcePathRelocation
    ) throws(GitWorktreeForkError) {
        let objects = plan.destinationRoot.appending(path: copied.relativePath).appending(path: "objects")
        let danglingInSource = Set(copied.alternates.filter { $0.target == nil }.map(\.line))
        for line in WorktreeForkGitTopologyPlanner.alternateLines(objects) {
            let recorded = line.hasPrefix("/") ? URL(fileURLWithPath: line) : objects.appending(path: line)
            guard case .success(let resolved) = WorktreeForkDescriptors.realpathURL(recorded) else {
                if danglingInSource.contains(line) {
                    continue
                }
                throw .validationFailed(reason: .sourceAdministrationReference, relativePath: copied.relativePath)
            }
            guard
                allowedPrefixes.contains(where: { (resolved.path + "/").hasPrefix($0) })
                    || relocation.counterpart(of: resolved) == .sharedRepository
            else {
                throw .validationFailed(reason: .sourceAdministrationReference, relativePath: copied.relativePath)
            }
        }
    }

    /// Every linked-worktree registration left in a copied Git directory must be one Git accepts: its `gitdir`
    /// names a worktree outside the tree (kept by the outside rule), or a gitfile inside it whose `gitdir:`
    /// line leads back to this registration, the reciprocity Git's `validate_worktree` requires. A
    /// registration Git would already reject in the source is kept as written: the copy is no more broken.
    private func validateCopiedRegistrations(_ copied: WorktreeForkCopiedGitDirectory) throws(GitWorktreeForkError) {
        let destinationWorktrees = plan.destinationRoot.appending(path: copied.relativePath).appending(
            path: "worktrees")
        let sourceWorktrees = plan.sourceRoot.appending(path: copied.relativePath).appending(path: "worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: destinationWorktrees.path)) ?? [] {
            let destination = Self.registrationShape(
                destinationWorktrees.appending(path: name), tree: plan.destinationRoot, sourceRoot: plan.sourceRoot)
            guard destination == .broken else {
                continue
            }
            let source = Self.registrationShape(
                sourceWorktrees.appending(path: name), tree: plan.sourceRoot, sourceRoot: nil)
            guard source == .broken else {
                throw .validationFailed(
                    reason: .worktreeRegistrationInvalid, relativePath: "\(copied.relativePath)/worktrees/\(name)")
            }
        }
    }

    private enum RegistrationShape: Equatable {
        /// Not a registration (no `gitdir` file).
        case absent
        /// Names a worktree outside `tree` and outside the source tree.
        case outside
        /// Names a gitfile inside `tree` that leads back to the registration.
        case reciprocal
        /// Dangles, names the source tree from a destination copy, or names something inside `tree` that does
        /// not lead back.
        case broken
    }

    /// `sourceRoot` is given when classifying a destination copy: a registration naming the source tree there
    /// keeps the copy dependent on the source and is broken, never outside.
    private static func registrationShape(_ registration: URL, tree: URL, sourceRoot: URL?) -> RegistrationShape {
        guard let text = try? String(contentsOf: registration.appending(path: "gitdir"), encoding: .utf8) else {
            return .absent
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recorded = line.hasPrefix("/") ? URL(fileURLWithPath: line) : registration.appending(path: line)
        guard case .success(let gitfile) = WorktreeForkDescriptors.realpathURL(recorded),
            case .success(let canonicalTree) = WorktreeForkDescriptors.realpathURL(tree)
        else {
            return .broken
        }
        guard WorktreeForkAdministrativeSymlinks.relativeComponents(of: gitfile, beneath: canonicalTree) != nil else {
            if let sourceRoot,
                WorktreeForkAdministrativeSymlinks.relativeComponents(of: gitfile, beneath: sourceRoot) != nil
            {
                return .broken
            }
            return .outside
        }
        guard let gitfileText = try? String(contentsOf: gitfile, encoding: .utf8), gitfileText.hasPrefix("gitdir: ")
        else {
            return .broken
        }
        let pointer = gitfileText.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let back =
            pointer.hasPrefix("/")
            ? URL(fileURLWithPath: pointer) : gitfile.deletingLastPathComponent().appending(path: pointer)
        guard case .success(let resolvedBack) = WorktreeForkDescriptors.realpathURL(back),
            case .success(let canonicalRegistration) = WorktreeForkDescriptors.realpathURL(registration),
            resolvedBack.path == canonicalRegistration.path
        else {
            return .broken
        }
        return .reciprocal
    }

    /// Every symlink inside a destination-owned object mirror must resolve inside that same mirror.
    private func validateMirrorSymlinks() throws(GitWorktreeForkError) {
        let mirrorsRoot = plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
            .appending(path: "agentstudio-object-mirrors")
        let mirrors = (try? FileManager.default.contentsOfDirectory(atPath: mirrorsRoot.path)) ?? []
        for mirrorName in mirrors {
            let mirror = mirrorsRoot.appending(path: mirrorName)
            for (_, link) in WorktreeForkAdministrativeSymlinks.symlinks(beneath: mirror, skipping: { _ in false }) {
                guard case .success(let target) = WorktreeForkDescriptors.realpathURL(link),
                    case .success(let canonicalMirror) = WorktreeForkDescriptors.realpathURL(mirror),
                    WorktreeForkAdministrativeSymlinks.relativeComponents(of: target, beneath: canonicalMirror) != nil
                else {
                    throw .validationFailed(reason: .sourceAdministrationReference, relativePath: nil)
                }
            }
        }
    }

    private func validateNode(
        _ rehomed: WorktreeForkRehomedNode,
        evidence: WorktreeForkIndexRefreshEvidence?
    ) throws(GitWorktreeForkError) {
        let reportPath = rehomed.node.relativePath
        let unusable = GitWorktreeForkError.validationFailed(
            reason: .nestedRepositoryUnusable, relativePath: reportPath)
        let repository: OpaquePointer
        do throws(GitWorktreeForkError) {
            repository = try WorktreeForkGitHandles.openWorktree(rehomed.destinationWorktree)
        } catch {
            throw unusable
        }
        defer { git_repository_free(repository) }
        guard let workdir = git_repository_workdir(repository), let gitDirectory = git_repository_path(repository),
            let commonDirectory = git_repository_commondir(repository),
            canonicalPath(String(cString: workdir)) == canonicalPath(rehomed.destinationWorktree.path),
            canonicalPath(String(cString: gitDirectory)) == canonicalPath(rehomed.destinationAdministration.path)
        else {
            throw unusable
        }
        try validateHead(rehomed.node, repository: repository)
        var pointers = [String(cString: gitDirectory), String(cString: commonDirectory)]
        pointers += configuredWorktree(repository, administration: rehomed.destinationAdministration)
        pointers +=
            (try? GitRepositoryStateRehomer.directAlternates(
                rehomed.destinationAdministration.appending(path: "objects"), reportPath
            ).map(\.path)) ?? []
        pointers += WorktreeForkAdministrativeSymlinks.symlinks(
            beneath: rehomed.destinationAdministration, skipping: { _ in false }
        ).map { $0.1.path }
        for pointer in pointers {
            // Every pointer must resolve; a dangling link is never accepted by its own location.
            guard let resolved = canonicalPath(pointer).map({ $0 + "/" }),
                allowedPrefixes.contains(where: { resolved.hasPrefix($0) })
            else {
                throw .validationFailed(reason: .sourceAdministrationReference, relativePath: reportPath)
            }
        }
        try WorktreeForkIndexValidation.validate(
            worktreePath: rehomed.destinationWorktree,
            treeOID: rehomed.node.capturedHead?.treeOID,
            expectedSkipWorktree: rehomed.node.sparse?.skipWorktreePaths ?? [],
            evidence: evidence ?? WorktreeForkIndexRefreshEvidence(unrefreshedPaths: [], adoptedPaths: []),
            reportPrefix: reportPath
        )
    }

    private func validateHead(
        _ node: WorktreeForkGitNode,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) {
        let mismatch = GitWorktreeForkError.validationFailed(reason: .headMismatch, relativePath: node.relativePath)
        var headOID = git_oid()
        let resolved = git_reference_name_to_id(&headOID, repository, "HEAD") >= 0
        guard resolved == (node.capturedHead != nil) else {
            throw mismatch
        }
        if let capturedHead = node.capturedHead, oidString(&headOID) != capturedHead.commitOID {
            throw mismatch
        }
        guard let headReferenceName = node.headReferenceName else {
            return
        }
        var head: OpaquePointer?
        guard git_reference_lookup(&head, repository, "HEAD") >= 0, let head else {
            throw mismatch
        }
        defer { git_reference_free(head) }
        guard let target = git_reference_symbolic_target(head), String(cString: target) == headReferenceName else {
            throw mismatch
        }
    }

    private func configuredWorktree(_ repository: OpaquePointer, administration: URL) -> [String] {
        var configuration: OpaquePointer?
        guard git_repository_config_snapshot(&configuration, repository) >= 0, let configuration else {
            return []
        }
        defer { git_config_free(configuration) }
        var value: UnsafePointer<CChar>?
        guard git_config_get_string(&value, configuration, "core.worktree") >= 0, let value else {
            return []
        }
        let configured = String(cString: value)
        return [configured.hasPrefix("/") ? configured : administration.appending(path: configured).path]
    }

    private func canonicalPath(_ path: String) -> String? {
        guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(URL(fileURLWithPath: path)) else {
            return nil
        }
        return canonical.path
    }
}
