import Foundation

public enum GitHeadKind: String, Codable, CaseIterable, Sendable {
    case branch
    case detached
    case unborn
}

public struct GitHeadSnapshot: Codable, Equatable, Hashable, Sendable {
    public let kind: GitHeadKind
    public let oid: String?
    public let shortName: String?

    public init(kind: GitHeadKind, oid: String?, shortName: String?) {
        self.kind = kind
        self.oid = oid
        self.shortName = shortName
    }
}

public struct GitBranchSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public let upstreamName: String?

    public init(name: String, isCurrent: Bool, upstreamName: String?) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstreamName = upstreamName
    }
}

public struct GitRemoteSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let url: URL
    public let rawURL: String

    public init(name: String, url: URL, rawURL: String) {
        self.name = name
        self.url = url
        self.rawURL = rawURL
    }
}

public enum GitOriginResolution: Codable, Equatable, Hashable, Sendable {
    case awaitingResolution
    case confirmedAbsent
    case resolved(GitRemoteSnapshot)

    private enum CodingKeys: String, CodingKey {
        case state
        case remote
    }

    private enum State: String, Codable {
        case awaitingResolution
        case confirmedAbsent
        case resolved
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        switch state {
        case .awaitingResolution:
            if container.contains(.remote) {
                throw DecodingError.dataCorruptedError(
                    forKey: .remote,
                    in: container,
                    debugDescription: "awaiting origin resolution must not carry a remote payload"
                )
            }
            self = .awaitingResolution
        case .confirmedAbsent:
            if container.contains(.remote) {
                throw DecodingError.dataCorruptedError(
                    forKey: .remote,
                    in: container,
                    debugDescription: "absent origin resolution must not carry a remote payload"
                )
            }
            self = .confirmedAbsent
        case .resolved:
            self = .resolved(try container.decode(GitRemoteSnapshot.self, forKey: .remote))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .awaitingResolution:
            try container.encode(State.awaitingResolution, forKey: .state)
        case .confirmedAbsent:
            try container.encode(State.confirmedAbsent, forKey: .state)
        case .resolved(let remote):
            try container.encode(State.resolved, forKey: .state)
            try container.encode(remote, forKey: .remote)
        }
    }
}

public struct GitStatusFactSummary: Codable, Equatable, Hashable, Sendable {
    public let changedFileCount: Int
    public let stagedFileCount: Int
    public let unstagedFileCount: Int
    public let untrackedFileCount: Int
    public let ignoredFileCount: Int
    public let aheadCount: Int
    public let behindCount: Int
    public let hasUpstream: Bool

    public init(
        changedFileCount: Int,
        stagedFileCount: Int,
        unstagedFileCount: Int,
        untrackedFileCount: Int,
        ignoredFileCount: Int,
        aheadCount: Int,
        behindCount: Int,
        hasUpstream: Bool
    ) {
        self.changedFileCount = changedFileCount
        self.stagedFileCount = stagedFileCount
        self.unstagedFileCount = unstagedFileCount
        self.untrackedFileCount = untrackedFileCount
        self.ignoredFileCount = ignoredFileCount
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.hasUpstream = hasUpstream
    }
}

public enum GitStatusState: String, Codable, CaseIterable, Sendable {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case typeChanged
    case unmerged
}

public struct GitStatusEntry: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let previousPath: String?
    public let indexState: GitStatusState?
    public let worktreeState: GitStatusState?
    public let ignored: Bool
    public let untracked: Bool

    public init(
        path: String,
        previousPath: String?,
        indexState: GitStatusState?,
        worktreeState: GitStatusState?,
        ignored: Bool,
        untracked: Bool
    ) {
        self.path = path
        self.previousPath = previousPath
        self.indexState = indexState
        self.worktreeState = worktreeState
        self.ignored = ignored
        self.untracked = untracked
    }
}

public struct GitStatusOptions: Codable, Equatable, Hashable, Sendable {
    public let includeIgnored: Bool
    public let includeUntracked: Bool

    /// Repo-relative path patterns that scope the status walk to just those paths.
    ///
    /// `nil` (the default) requests a full-worktree status — byte-identical to the
    /// behavior before this option existed. A non-`nil` value maps to libgit2's
    /// `git_status_options.pathspec` with fnmatch-style matching enabled, so entries
    /// are limited to paths matching the patterns. Patterns are repo-relative: a bare
    /// directory such as `"src"` scopes to that subtree recursively, and wildcards use
    /// fnmatch semantics. An empty array is treated as `nil` (no restriction), matching
    /// libgit2's empty-pathspec behavior.
    ///
    /// Rename caveat: status keeps rename detection enabled, but a pathspec that matches
    /// only one side of a rename cannot see the other side. libgit2 then reports the
    /// visible side as a standalone add (target-only match) or delete (source-only match)
    /// rather than a paired rename. Consumers folding scoped deltas must treat a
    /// source-only or target-only entry conservatively; this reader preserves whatever
    /// libgit2 reports and does not attempt to re-pair renames across pathspec limits.
    ///
    /// Pathspecs scope status entries and the entry-derived changed, staged, unstaged,
    /// untracked, and ignored file counts. Line additions/deletions, head, upstream,
    /// sync, and origin facts remain full-worktree values. This hybrid shape lets a
    /// consumer fold scoped entries into a cached full entry set without replacing
    /// repository-wide summary facts with partial totals.
    public let pathspecs: [String]?

    /// Skips submodules when reading status entries and complete-status line counts.
    ///
    /// `false` (the default) preserves the existing submodule behavior. When `true`,
    /// staged and unstaged submodule changes, including the submodule's own dirty
    /// worktree, are not reported. libgit2 still reports pending type changes from
    /// or to a submodule. The complete-status line-count diff also ignores submodules;
    /// standalone `exactLineCountDetail(for:)` reads retain their existing behavior.
    ///
    /// A missing wire key decodes as `false`; the key is omitted when `false` to
    /// preserve the default payload shape.
    public let excludeSubmodules: Bool

    public init(
        includeIgnored: Bool = false,
        includeUntracked: Bool = true,
        pathspecs: [String]? = nil,
        excludeSubmodules: Bool = false
    ) {
        self.includeIgnored = includeIgnored
        self.includeUntracked = includeUntracked
        self.pathspecs = pathspecs
        self.excludeSubmodules = excludeSubmodules
    }

    private enum CodingKeys: String, CodingKey {
        case includeIgnored
        case includeUntracked
        case pathspecs
        case excludeSubmodules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.includeIgnored = try container.decode(Bool.self, forKey: .includeIgnored)
        self.includeUntracked = try container.decode(Bool.self, forKey: .includeUntracked)
        self.pathspecs = try container.decodeIfPresent([String].self, forKey: .pathspecs)
        self.excludeSubmodules = try container.decodeIfPresent(Bool.self, forKey: .excludeSubmodules) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(includeIgnored, forKey: .includeIgnored)
        try container.encode(includeUntracked, forKey: .includeUntracked)
        try container.encodeIfPresent(pathspecs, forKey: .pathspecs)
        if excludeSubmodules {
            try container.encode(excludeSubmodules, forKey: .excludeSubmodules)
        }
    }
}

public struct GitStatusFactsSnapshot: Codable, Equatable, Hashable, Sendable {
    public let repositoryRoot: URL
    public let worktreePath: URL
    public let generatedAtUnixMilliseconds: Int64
    public let head: GitHeadSnapshot
    public let originResolution: GitOriginResolution
    public let summary: GitStatusFactSummary
    public let entries: [GitStatusEntry]

    public init(
        repositoryRoot: URL,
        worktreePath: URL,
        generatedAtUnixMilliseconds: Int64,
        head: GitHeadSnapshot,
        originResolution: GitOriginResolution,
        summary: GitStatusFactSummary,
        entries: [GitStatusEntry]
    ) {
        self.repositoryRoot = repositoryRoot
        self.worktreePath = worktreePath
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.head = head
        self.originResolution = originResolution
        self.summary = summary
        self.entries = entries
    }
}

public struct GitStatusLineCountDetail: Codable, Equatable, Hashable, Sendable {
    public let repositoryRoot: URL
    public let worktreePath: URL
    public let generatedAtUnixMilliseconds: Int64
    public let linesAdded: Int
    public let linesDeleted: Int

    public init(
        repositoryRoot: URL,
        worktreePath: URL,
        generatedAtUnixMilliseconds: Int64,
        linesAdded: Int,
        linesDeleted: Int
    ) {
        self.repositoryRoot = repositoryRoot
        self.worktreePath = worktreePath
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.linesAdded = linesAdded
        self.linesDeleted = linesDeleted
    }
}

public struct GitCompleteStatusSnapshot: Codable, Equatable, Hashable, Sendable {
    public let facts: GitStatusFactsSnapshot
    public let lineCountDetail: GitStatusLineCountDetail

    public init(
        facts: GitStatusFactsSnapshot,
        lineCountDetail: GitStatusLineCountDetail
    ) {
        self.facts = facts
        self.lineCountDetail = lineCountDetail
    }
}
