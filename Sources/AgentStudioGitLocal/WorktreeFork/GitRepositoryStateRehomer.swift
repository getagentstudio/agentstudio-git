import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Where one re-homed Git node now lives.
struct WorktreeForkRehomedNode: Sendable {
    let node: WorktreeForkGitNode
    let destinationWorktree: URL
    let destinationAdministration: URL
}

/// Re-homed nodes plus every administration tree cloned for them. The trees' directory metadata is
/// reproduced only after the last administration write (re-homing and index builds) has landed.
struct WorktreeForkRehomeOutcome: Sendable {
    var nodes: [WorktreeForkRehomedNode] = []
    var administrationTrees: [WorktreeForkClonedAdministrationTree] = []
    /// Destination-root-relative paths of ordinary worktree files whose bytes re-homing replaced (copied Git
    /// directories and configuration include files). Their clone no longer matches captured `HEAD`, so clean
    /// adoption must hash them instead of trusting the clone's stat. A re-homed node's own administration and
    /// gitfile are omitted: Git never tracks a `.git` path, so no index holds them.
    var rewrittenWorktreePaths: Set<String> = []
    /// Ownership or setuid/setgid normalization of private administration files cloned on demand.
    var normalizedEntries: [GitWorktreeMaterializationNormalizedEntry] = []

    /// Child trees (nested submodule administration, created later) are finalized before their parents.
    func finalizeAdministrationDirectories() throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry]
    {
        var normalized = normalizedEntries
        for tree in administrationTrees.reversed() {
            normalized += try tree.finalizeDirectories()
        }
        return normalized
    }
}

/// Gives every initialized nested Git node destination-owned administration: submodules beneath the fork's
/// own `$GIT_DIR/modules/...` (as Git lays out a linked worktree's submodules), independent repositories as
/// embedded `.git` directories, and every object alternate a destination-owned CoW mirror. No administrative
/// pointer is copied as final; each is rewritten for the destination. Git directories copied with ordinary
/// content keep their own copy, with every pointer into the source re-aimed at the destination.
struct GitRepositoryStateRehomer: Sendable {
    let plan: WorktreeForkPlan
    let cancellation: WorktreeForkCancellation
    let lockTracker: WorktreeForkLockTracker

    init(
        plan: WorktreeForkPlan,
        cancellation: WorktreeForkCancellation,
        lockTracker: WorktreeForkLockTracker = WorktreeForkLockTracker()
    ) {
        self.plan = plan
        self.cancellation = cancellation
        self.lockTracker = lockTracker
    }

    var rootAdministration: URL {
        plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
    }

    func rehome(journal: inout WorktreeForkRollbackJournal) throws(GitWorktreeForkError) -> WorktreeForkRehomeOutcome {
        let topology = plan.gitTopology
        if let rootSparse = topology.rootSparse {
            try writeSparseState(rootSparse, administration: rootAdministration, reportPath: ".")
        }
        var outcome = WorktreeForkRehomeOutcome()
        let mirrorByStore = try mirrorObjectStores(
            topology.mirroredObjectStores, journal: &journal, trees: &outcome.administrationTrees)
        var administrationByNode: [String: URL] = [:]
        for node in topology.nodes {
            try cancellation.throwIfCancelled()
            let destinationWorktree = plan.destinationRoot.appending(path: node.relativePath)
            let administration = destinationAdministration(for: node, administrationByNode: administrationByNode)
            try requireBeneath(administration, reportPath: "\(node.relativePath)/.git")
            administrationByNode[node.relativePath] = administration
            if case .submodule = node.kind {
                journal.record(
                    .nestedAdministration(
                        path: administration,
                        reportLocation: String(administration.path.dropFirst(plan.commonDirectory.path.count + 1)),
                        identity: nil
                    ))
            }
            let tree = try rehome(
                node, worktree: destinationWorktree, administration: administration, mirrorByStore: mirrorByStore
            ) { identity in
                journal.confirmNestedAdministration(at: administration, identity: identity)
            }
            outcome.administrationTrees.append(tree)
            outcome.nodes.append(
                WorktreeForkRehomedNode(
                    node: node, destinationWorktree: destinationWorktree, destinationAdministration: administration))
        }
        let relocation = WorktreeForkSourcePathRelocation(plan: plan, administrationByNode: administrationByNode)
        var rewrittenFiles: [URL] = []
        for copied in topology.copiedGitDirectories {
            try cancellation.throwIfCancelled()
            rewrittenFiles += try rehomeCopiedPointers(copied, relocation: relocation, mirrorByStore: mirrorByStore)
        }
        try cancellation.throwIfCancelled()
        var counterparts = WorktreeForkPrivateAdministrationCounterparts(plan: plan, relocation: relocation)
        rewrittenFiles += try WorktreeForkConfigurationPathRehomer(
            plan: plan, relocation: relocation, lockTracker: lockTracker
        )
        .rehome(Self.configurationRoots(plan: plan, nodes: outcome.nodes), counterparts: &counterparts)
        outcome.administrationTrees += counterparts.administrationTrees
        outcome.normalizedEntries += counterparts.normalizedEntries
        outcome.rewrittenWorktreePaths = Set(
            rewrittenFiles.compactMap {
                WorktreeForkAdministrativeSymlinks.relativeComponents(of: $0, beneath: plan.destinationRoot)
            })
        return outcome
    }

    /// The configuration files each re-homed node and each copied Git directory owns in the destination,
    /// paired with their source files; the starting points of every include closure.
    static func configurationRoots(
        plan: WorktreeForkPlan,
        nodes: [WorktreeForkRehomedNode]
    ) -> [WorktreeForkConfigurationCopy] {
        let nodeFiles = nodes.flatMap { rehomed in
            WorktreeForkConfigurationCopy.repositoryFiles(
                sourceCommonDirectory: rehomed.node.sourceCommonDirectory,
                sourceGitDirectory: rehomed.node.sourceGitDirectory,
                destinationAdministration: rehomed.destinationAdministration,
                reportPath: "\(rehomed.node.relativePath)/.git")
        }
        let copiedFiles = plan.gitTopology.copiedGitDirectories.flatMap { copied in
            WorktreeForkConfigurationCopy.repositoryFiles(
                sourceCommonDirectory: plan.sourceRoot.appending(path: copied.relativePath),
                sourceGitDirectory: plan.sourceRoot.appending(path: copied.relativePath),
                destinationAdministration: plan.destinationRoot.appending(path: copied.relativePath),
                reportPath: copied.relativePath)
        }
        return nodeFiles + copiedFiles
    }

    /// Rewrites each pointer in a copied Git directory's alternates and linked-worktree registrations that
    /// does not already lead, from the copy, to its destination counterpart. An alternate outside every
    /// relocated location leads to its destination-owned mirror; a registration outside keeps its target. A
    /// pointer that already leads where it should (a relative path inside the tree) keeps its bytes, so
    /// tracked fixtures stay clean. Returns the files it rewrote.
    private func rehomeCopiedPointers(
        _ copied: WorktreeForkCopiedGitDirectory,
        relocation: WorktreeForkSourcePathRelocation,
        mirrorByStore: [URL: URL]
    ) throws(GitWorktreeForkError) -> [URL] {
        var rewritten: [URL] = []
        let gitDirectory = plan.destinationRoot.appending(path: copied.relativePath)
        let alternatesPath = WorktreeForkAdministrationCloner.alternatesRelativePath
        let objects = gitDirectory.appending(path: "objects")
        let alternatesReportPath = "\(copied.relativePath)/\(alternatesPath)"
        var alternateLines: [String] = []
        for pointer in copied.alternates {
            alternateLines.append(
                try destinationLine(
                    for: pointer, resolvingFrom: objects, relocation: relocation, outsideMirrors: mirrorByStore,
                    reportPath: alternatesReportPath))
        }
        let sourceGitDirectory = plan.sourceRoot.appending(path: copied.relativePath)
        if alternateLines != copied.alternates.map(\.line) {
            let alternatesFile = gitDirectory.appending(path: alternatesPath)
            try writeText(
                alternateLines.joined(separator: "\n") + "\n",
                to: alternatesFile,
                metadataFrom: sourceGitDirectory.appending(path: alternatesPath),
                reportPath: alternatesReportPath
            )
            rewritten.append(alternatesFile)
        }
        for (registrationPath, pointer) in copied.worktreeRegistrations.sorted(by: { $0.key < $1.key }) {
            let registrationDirectory = WorktreeForkDescriptors.splitParent(registrationPath).parent
            let registration = gitDirectory.appending(path: registrationDirectory)
            let reportPath = "\(copied.relativePath)/\(registrationPath)"
            let line = try destinationLine(
                for: pointer, resolvingFrom: registration, relocation: relocation, outsideMirrors: nil,
                reportPath: reportPath)
            if line != pointer.line {
                let registrationFile = gitDirectory.appending(path: registrationPath)
                try writeText(
                    line + "\n",
                    to: registrationFile,
                    metadataFrom: sourceGitDirectory.appending(path: registrationPath),
                    reportPath: reportPath
                )
                rewritten.append(registrationFile)
            }
        }
        return rewritten
    }

    /// The text that leads from the copy to the pointer's destination counterpart. A target outside every
    /// relocated location leads to its mirror when `outsideMirrors` is given, otherwise to itself; a target in
    /// the shared repository leads to itself. The recorded
    /// text is kept when it already resolves there from the copy; a counterpart that is unmapped, unmirrored,
    /// or missing would leave the copy dangling or source-dependent, so it fails.
    private func destinationLine(
        for pointer: WorktreeForkCopiedPointer,
        resolvingFrom base: URL,
        relocation: WorktreeForkSourcePathRelocation,
        outsideMirrors: [URL: URL]?,
        reportPath: String
    ) throws(GitWorktreeForkError) -> String {
        guard let target = pointer.target else {
            return pointer.line
        }
        let unresolvable = GitWorktreeForkError.entryFailed(
            relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        let wanted: URL
        switch relocation.counterpart(of: target) {
        case .outsideSource:
            guard let outsideMirrors else {
                wanted = target
                break
            }
            guard let mirror = outsideMirrors[target] else {
                throw unresolvable
            }
            wanted = mirror
        case .sharedRepository:
            wanted = target
        case .relocated(let destination):
            wanted = destination
        case .unmapped:
            throw unresolvable
        }
        let recorded =
            pointer.line.hasPrefix("/") ? URL(fileURLWithPath: pointer.line) : base.appending(path: pointer.line)
        if case .success(let resolved) = WorktreeForkDescriptors.realpathURL(recorded), resolved.path == wanted.path {
            return pointer.line
        }
        guard case .success = WorktreeForkDescriptors.realpathURL(wanted) else {
            throw unresolvable
        }
        return wanted.path
    }

    /// Defense in depth behind the planner's name rule: destination administration must sit beneath the
    /// fork's own administration or the destination tree, compared by path components, never by prefix.
    private func requireBeneath(_ administration: URL, reportPath: String) throws(GitWorktreeForkError) {
        let components = administration.pathComponents
        let isBeneath = [rootAdministration, plan.destinationRoot].contains { root in
            let rootComponents = root.pathComponents
            return components.count > rootComponents.count
                && Array(components.prefix(rootComponents.count)) == rootComponents
        }
        guard isBeneath, !components.contains(".."), !components.contains(".") else {
            throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
    }

    private func destinationAdministration(
        for node: WorktreeForkGitNode,
        administrationByNode: [String: URL]
    ) -> URL {
        switch node.kind {
        case .submodule(let name):
            let parentAdministration =
                node.parentRelativePath.flatMap { administrationByNode[$0] } ?? rootAdministration
            return parentAdministration.appending(path: "modules").appending(path: name)
        case .embeddedRepository, .flattenedRepository:
            return plan.destinationRoot.appending(path: node.relativePath).appending(path: ".git")
        }
    }

    private func rehome(
        _ node: WorktreeForkGitNode,
        worktree: URL,
        administration: URL,
        mirrorByStore: [URL: URL],
        created: (WorktreeForkEntryIdentity) -> Void
    ) throws(GitWorktreeForkError) -> WorktreeForkClonedAdministrationTree {
        let reportPath = "\(node.relativePath)/.git"
        var cloner = WorktreeForkAdministrationCloner(reportPath: reportPath)
        cloner.symlinkTargets = try symlinkTargets(node, administration: administration, mirrorByStore: mirrorByStore)
        let tree = try cloner.cloneTree(from: node.sourceCommonDirectory, to: administration, created: created)
        if node.sourceGitDirectory != node.sourceCommonDirectory {
            try overlayPrivateAdministration(node, administration: administration, reportPath: reportPath)
        }
        // The cloned HEAD is the common repository's; a linked worktree's own HEAD is its private one.
        try writeText(
            headContents(node),
            to: administration.appending(path: "HEAD"),
            metadataFrom: node.sourceGitDirectory.appending(path: "HEAD"),
            reportPath: reportPath
        )
        try writeAlternates(node, administration: administration, mirrorByStore: mirrorByStore, reportPath: reportPath)

        var configurationEdits: [WorktreeForkConfigurationEdit] = [.setBool("core.bare", false)]
        switch node.kind {
        case .submodule:
            configurationEdits.append(
                .setString("core.worktree", WorktreeForkRelativePath.from(administration, to: worktree)))
        case .embeddedRepository, .flattenedRepository:
            configurationEdits.append(.delete("core.worktree"))
        }
        if node.sparse != nil {
            configurationEdits.append(.setBool("index.sparse", false))
        }
        try WorktreeForkConfigurationFile.apply(
            configurationEdits,
            to: administration.appending(path: "config"),
            reportPath: reportPath,
            lockTracker: lockTracker
        )
        if case .submodule = node.kind {
            let pointer = "gitdir: \(WorktreeForkRelativePath.from(worktree, to: administration))\n"
            try writeText(
                pointer,
                to: worktree.appending(path: ".git"),
                metadataFrom: plan.sourceRoot.appending(path: node.relativePath).appending(path: ".git"),
                reportPath: reportPath
            )
        }
        if let sparse = node.sparse {
            try writeSparseState(sparse, administration: administration, reportPath: reportPath)
        }
        try sanitizeWorktreeConfiguration(in: administration, reportPath: reportPath)
        return tree
    }

    /// Destination link text for each classified administrative symlink: internal links point at the
    /// destination copy of their target, external stores at their destination-owned mirror.
    private func symlinkTargets(
        _ node: WorktreeForkGitNode,
        administration: URL,
        mirrorByStore: [URL: URL]
    ) throws(GitWorktreeForkError) -> [String: String] {
        var targets: [String: String] = [:]
        for (relativePath, symlink) in node.administrativeSymlinks {
            switch symlink {
            case .internalTarget(let relativeTarget):
                let linkDirectory = administration.appending(path: relativePath).deletingLastPathComponent()
                targets[relativePath] = WorktreeForkRelativePath.from(
                    linkDirectory, to: administration.appending(path: relativeTarget))
            case .externalStore(let store):
                guard let mirror = mirrorByStore[store] else {
                    throw .entryFailed(
                        relativePath: "\(node.relativePath)/.git", reason: .unresolvableGitAdministration,
                        errorNumber: nil)
                }
                targets[relativePath] = mirror.path
            }
        }
        return targets
    }

    /// A gitfile-reached node keeps its worktree-private identity (`HEAD` is rewritten from the plan) and
    /// worktree configuration; its common administration was cloned above.
    private func overlayPrivateAdministration(
        _ node: WorktreeForkGitNode,
        administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        // The cloned common directory's config.worktree belongs to that repository's main worktree, not
        // to this one; only the node's own worktree-private configuration may carry over.
        let destinationConfiguration = administration.appending(path: "config.worktree")
        if case .success = WorktreeForkDescriptors.lstatPath(destinationConfiguration),
            (try? FileManager.default.removeItem(at: destinationConfiguration)) == nil
        {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: nil)
        }
        let privateConfiguration = node.sourceGitDirectory.appending(path: "config.worktree")
        if let contents = try? Data(contentsOf: privateConfiguration) {
            try writeData(
                contents, to: destinationConfiguration, metadataFrom: privateConfiguration, reportPath: reportPath)
        }
    }

    /// A worktree-scoped `core.worktree` (Git moves the main worktree's there when worktree config is
    /// enabled) or `core.bare` would point the destination at the source; neither is ever carried over.
    private func sanitizeWorktreeConfiguration(
        in administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let configuration = administration.appending(path: "config.worktree")
        guard case .success = WorktreeForkDescriptors.lstatPath(configuration) else {
            return
        }
        try WorktreeForkConfigurationFile.apply(
            [.delete("core.worktree"), .delete("core.bare")], to: configuration, reportPath: reportPath,
            lockTracker: lockTracker)
    }

    private func headContents(_ node: WorktreeForkGitNode) -> String {
        if let headReferenceName = node.headReferenceName {
            return "ref: \(headReferenceName)\n"
        }
        return "\(node.capturedHead?.commitOID ?? "")\n"
    }

    private func writeAlternates(
        _ node: WorktreeForkGitNode,
        administration: URL,
        mirrorByStore: [URL: URL],
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let direct = try Self.directAlternates(node.sourceCommonDirectory.appending(path: "objects"), reportPath)
        guard !direct.isEmpty else {
            return
        }
        let lines = direct.compactMap { mirrorByStore[$0]?.path }
        guard lines.count == direct.count else {
            throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        let alternatesPath = WorktreeForkAdministrationCloner.alternatesRelativePath
        try writeText(
            lines.joined(separator: "\n") + "\n",
            to: administration.appending(path: alternatesPath),
            metadataFrom: node.sourceCommonDirectory.appending(path: alternatesPath),
            reportPath: reportPath
        )
    }

    /// Mirrors each borrowed object store once, beneath the fork's own administration, and points each
    /// mirror's own alternates at the corresponding mirrors so the closure never leaves destination state.
    private func mirrorObjectStores(
        _ stores: [URL],
        journal: inout WorktreeForkRollbackJournal,
        trees: inout [WorktreeForkClonedAdministrationTree]
    ) throws(GitWorktreeForkError) -> [URL: URL] {
        var mirrorByStore: [URL: URL] = [:]
        for (index, store) in stores.enumerated() {
            let mirror = rootAdministration.appending(path: "agentstudio-object-mirrors").appending(path: "\(index)")
            let location = "worktrees/\(plan.worktreeName)/agentstudio-object-mirrors/\(index)"
            journal.record(.nestedAdministration(path: mirror, reportLocation: location, identity: nil))
            var cloner = WorktreeForkAdministrationCloner(reportPath: location)
            cloner.symlinkTargets = plan.gitTopology.mirroredStoreSymlinks[store] ?? [:]
            let tree = try cloner.cloneTree(from: store, to: mirror) { identity in
                journal.confirmNestedAdministration(at: mirror, identity: identity)
            }
            trees.append(tree)
            mirrorByStore[store] = mirror
        }
        for store in stores {
            guard let mirror = mirrorByStore[store] else {
                continue
            }
            let direct = try Self.directAlternates(store, "")
            if !direct.isEmpty {
                let lines = direct.compactMap { mirrorByStore[$0]?.path }.joined(separator: "\n")
                try writeText(
                    lines + "\n",
                    to: mirror.appending(path: "info/alternates"),
                    metadataFrom: store.appending(path: "info/alternates"),
                    reportPath: "."
                )
            }
        }
        return mirrorByStore
    }

    private func writeSparseState(
        _ sparse: WorktreeForkSparsePlan,
        administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        // The destination copy may be absent (fresh fork administration) or removed (a flattened node's
        // overlay), so the source files are the metadata templates.
        try writeData(
            sparse.patternFile,
            to: administration.appending(path: "info/sparse-checkout"),
            metadataFrom: sparse.sourceGitDirectory.appending(path: "info/sparse-checkout"),
            reportPath: reportPath
        )
        guard let worktreeConfiguration = sparse.worktreeConfiguration else {
            return
        }
        let destination = administration.appending(path: "config.worktree")
        try writeData(
            worktreeConfiguration,
            to: destination,
            metadataFrom: sparse.sourceGitDirectory.appending(path: "config.worktree"),
            reportPath: reportPath
        )
        try WorktreeForkConfigurationFile.apply(
            [.setBool("index.sparse", false), .delete("core.worktree"), .delete("core.bare")],
            to: destination,
            reportPath: reportPath,
            lockTracker: lockTracker
        )
    }

    static func directAlternates(_ objectsDirectory: URL, _ reportPath: String) throws(GitWorktreeForkError) -> [URL] {
        try WorktreeForkGitTopologyPlanner.alternateLines(objectsDirectory).map { line throws(GitWorktreeForkError) in
            let candidate = line.hasPrefix("/") ? URL(fileURLWithPath: line) : objectsDirectory.appending(path: line)
            guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(candidate) else {
                throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
            }
            return canonical
        }
    }

    private func writeText(
        _ text: String,
        to url: URL,
        metadataFrom template: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        try writeData(Data(text.utf8), to: url, metadataFrom: template, reportPath: reportPath)
    }

    /// Replaces `url` with `data` on a fresh same-directory inode renamed into place, carrying the metadata of
    /// `template`, the source file `url` stands for (see `WorktreeForkMetadataPreservingRewrite`).
    private func writeData(
        _ data: Data,
        to url: URL,
        metadataFrom template: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .entryFailed(
                relativePath: reportPath, reason: .entryCreationFailed, errorNumber: Self.errorNumber(of: error))
        }
        try WorktreeForkMetadataPreservingRewrite.rewrite(
            url, metadataFrom: .sourceCounterpart(template), reportPath: reportPath
        ) { () throws(GitWorktreeForkError) in
            let temporary = directory.appending(path: ".\(url.lastPathComponent).agentstudio-\(UUID().uuidString).tmp")
            try Self.writeNewFile(data, at: temporary, reportPath: reportPath)
            guard rename(temporary.path, url.path) == 0 else {
                let failure = errno
                _ = unlink(temporary.path)
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
    }

    /// Creates `temporary` with mode 0644 holding `data`; removes it again on failure.
    private static func writeNewFile(_ data: Data, at temporary: URL, reportPath: String) throws(GitWorktreeForkError) {
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count, failure == nil {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno != EINTR { failure = errno }
                } else {
                    offset += written
                }
            }
        }
        if failure == nil, fchmod(descriptor, 0o644) != 0 { failure = errno }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if let failure {
            _ = unlink(temporary.path)
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
        }
    }

    private static func errorNumber(of error: Error) -> Int32? {
        ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) }
    }
}
