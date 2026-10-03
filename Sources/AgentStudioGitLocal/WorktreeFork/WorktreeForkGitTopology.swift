import Foundation

/// Captured Git structure beneath the source root: every initialized nested Git node, the registered
/// submodules that stay uninitialized, sparse intent, and the object stores that need CoW mirrors.
struct WorktreeForkGitTopology: Sendable {
    let rootSparse: WorktreeForkSparsePlan?
    /// Nil when libgit2 cannot read the root source index (for example a sparse index).
    let rootSourceIndex: WorktreeForkSourceIndexSnapshot?
    /// Parent-before-child.
    let nodes: [WorktreeForkGitNode]
    let uninitializedSubmodulePaths: [String]
    /// Canonical source object directories reachable through nested alternates, deduplicated.
    let mirroredObjectStores: [URL]
    /// Mirror link text for store-internal symlinks, keyed by store then store-relative path.
    let mirroredStoreSymlinks: [URL: [String: String]]
    /// Git directories copied with the ordinary content, whose pointers the re-homer rewrites in the copy.
    let copiedGitDirectories: [WorktreeForkCopiedGitDirectory]
}

/// A Git directory inside ordinary content, such as a bare cache under `.build/repositories` or a separate
/// Git directory. The materializer copies it byte for byte, so each pointer it holds into the source tree
/// would keep the copy dependent on the source until the re-homer points it at the destination instead.
struct WorktreeForkCopiedGitDirectory: Sendable {
    /// Source-root-relative path of the Git directory.
    let relativePath: String
    /// `objects/info/alternates` lines, in order.
    let alternates: [WorktreeForkCopiedPointer]
    /// The `gitdir` file of each linked-worktree registration, keyed by Git-directory-relative path.
    let worktreeRegistrations: [String: WorktreeForkCopiedPointer]
    /// Git-directory-relative `worktrees/<name>` registrations whose linked worktree the fork captured as a
    /// nested node and re-homes as an independent repository. The destination has no gitfile pointing back at
    /// them, so Git would see a broken registration; they are left out of the copy instead of rewritten.
    let retiredRegistrations: [String]

    /// Source-root-relative roots of the retired registrations, which the filesystem plan excludes.
    var retiredRegistrationSubtrees: [String] {
        retiredRegistrations.map { "\(relativePath)/\($0)" }
    }
}

/// One path a copied Git directory records, as written and as Git resolves it.
struct WorktreeForkCopiedPointer: Equatable, Sendable {
    let line: String
    /// Canonical target; nil when the recorded path does not resolve (a stale registration, a broken cache).
    let target: URL?
}

enum WorktreeForkGitNodeKind: Equatable, Sendable {
    /// Registered in its parent's captured tree; administration lives under the parent's `modules/`.
    case submodule(name: String)
    /// Independent repository with an embedded `.git` directory.
    case embeddedRepository
    /// Independent repository reached through a gitfile (linked worktree or absorbed layout); its private
    /// and common administration are flattened into an embedded destination `.git` directory.
    case flattenedRepository
}

struct WorktreeForkGitNode: Sendable {
    /// Worktree-relative directory of the nested working tree.
    let relativePath: String
    /// Nearest enclosing node, or nil when the parent is the fork root.
    let parentRelativePath: String?
    let kind: WorktreeForkGitNodeKind
    /// Worktree-private administration (`$GIT_DIR`).
    let sourceGitDirectory: URL
    let sourceCommonDirectory: URL
    /// Nil for an unborn repository.
    let capturedHead: WorktreeForkCapturedHead?
    /// `refs/heads/...` when `HEAD` is symbolic; nil when detached.
    let headReferenceName: String?
    let sparse: WorktreeForkSparsePlan?
    let sourceIndex: WorktreeForkSourceIndexSnapshot?
    /// Canonical object directories this node's common object store borrows from.
    let alternateObjectStores: [URL]
    /// Symlinks inside the node's common administration, keyed by administration-relative path.
    let administrativeSymlinks: [String: WorktreeForkAdministrativeSymlink]
}

/// Sparse intent for one Git node, captured from its source administration.
struct WorktreeForkSparsePlan: Equatable, Sendable {
    /// Where the pattern file and worktree configuration were read; their metadata templates.
    let sourceGitDirectory: URL
    let patternFile: Data
    /// The node's `config.worktree`, reproduced with sparse-index compression disabled.
    let worktreeConfiguration: Data?
    let skipWorktreePaths: Set<String>
}
