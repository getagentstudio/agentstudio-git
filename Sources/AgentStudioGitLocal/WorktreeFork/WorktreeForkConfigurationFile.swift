import AgentStudioGitContracts
import CLibGit2Local
import Foundation

enum WorktreeForkConfigurationEdit: Sendable {
    case setBool(String, Bool)
    case setString(String, String)
    case delete(String)
    /// Replaces every value of a (possibly multi-valued) key that equals `matching` exactly.
    case replaceValue(String, matching: String, with: String)
}

struct WorktreeForkConfigurationEntry: Equatable, Sendable {
    let name: String
    let value: String
}

/// Edits one Git configuration file through libgit2 so its syntax and locking stay Git's.
enum WorktreeForkConfigurationFile {
    /// The configuration files a repository's administration owns: shared, then worktree-scoped.
    static let repositoryFileNames = ["config", "config.worktree"]

    /// Entries written in this file itself, not reached through an include; each distinct name and value once.
    /// The re-homer edits with this list: a value replacement already rewrites every equal value of its key.
    static func ownEntries(
        in path: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) -> [WorktreeForkConfigurationEntry] {
        var distinct: [WorktreeForkConfigurationEntry] = []
        for entry in try orderedEntries(in: path, reportPath: reportPath) where !distinct.contains(entry) {
            distinct.append(entry)
        }
        return distinct
    }

    /// Every entry written in this file itself, in file order with repeats kept: Git's effective value of a key
    /// is its last occurrence, so dropping or reordering a repeat changes behavior. libgit2 still reads the
    /// file's includes, so a file whose includes cycle or nest too deeply fails here. The read is guarded
    /// against dataless payloads.
    static func orderedEntries(
        in path: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) -> [WorktreeForkConfigurationEntry] {
        try WorktreeForkDatalessGuardedRead.run(path, reportPath: reportPath) { () throws(GitWorktreeForkError) in
            try readOrderedEntries(in: path)
        }
    }

    private static func readOrderedEntries(in path: URL) throws(GitWorktreeForkError)
        -> [WorktreeForkConfigurationEntry]
    {
        var configuration: OpaquePointer?
        let openResult = path.path.withCString { git_config_open_ondisk(&configuration, $0) }
        guard openResult >= 0, let configuration else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        defer { git_config_free(configuration) }
        var iterator: OpaquePointer?
        let iteratorResult = git_config_iterator_new(&iterator, configuration)
        guard iteratorResult >= 0, let iterator else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: iteratorResult))
        }
        defer { git_config_iterator_free(iterator) }
        var entries: [WorktreeForkConfigurationEntry] = []
        var entry: UnsafeMutablePointer<git_config_entry>?
        while true {
            let nextResult = git_config_next(&entry, iterator)
            if nextResult == GIT_ITEROVER.rawValue {
                return entries
            }
            guard nextResult >= 0, let current = entry?.pointee else {
                throw .gitFailure(LibGit2ErrorCapture.failure(code: nextResult))
            }
            guard current.include_depth == 0, let name = current.name, let value = current.value else {
                continue
            }
            entries.append(WorktreeForkConfigurationEntry(name: String(cString: name), value: String(cString: value)))
        }
    }

    /// libgit2 commits each edit by renaming a fresh lock file over `path`, so the edit runs as a
    /// metadata-preserving rewrite of the configuration file.
    static func apply(
        _ edits: [WorktreeForkConfigurationEdit],
        to path: URL,
        reportPath: String,
        lockTracker: WorktreeForkLockTracker? = nil
    ) throws(GitWorktreeForkError) {
        try WorktreeForkMetadataPreservingRewrite.rewrite(path, metadataFrom: .editedFile, reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            try WorktreeForkDatalessGuardedRead.run(path, reportPath: reportPath) { () throws(GitWorktreeForkError) in
                try applyThroughLibGit2(edits, to: path, lockTracker: lockTracker)
            }
        }
    }

    private static func applyThroughLibGit2(
        _ edits: [WorktreeForkConfigurationEdit],
        to path: URL,
        lockTracker: WorktreeForkLockTracker?
    ) throws(GitWorktreeForkError) {
        var configuration: OpaquePointer?
        let openResult = path.path.withCString { git_config_open_ondisk(&configuration, $0) }
        guard openResult >= 0, let configuration else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        defer { git_config_free(configuration) }
        let lockFact = GitLockFact(
            path: URL(fileURLWithPath: "\(path.path).lock").standardizedFileURL,
            resource: .config
        )
        for edit in edits {
            lockTracker?.beginAttempt(for: [lockFact])
            errno = 0
            let result: Int32
            switch edit {
            case .setBool(let name, let value):
                result = git_config_set_bool(configuration, name, value ? 1 : 0)
            case .setString(let name, let value):
                result = git_config_set_string(configuration, name, value)
            case .delete(let name):
                let deleteResult = git_config_delete_entry(configuration, name)
                result = deleteResult == GIT_ENOTFOUND.rawValue ? 0 : deleteResult
            case .replaceValue(let name, let matching, let value):
                result = git_config_set_multivar(configuration, name, "^\(Self.escapedPattern(matching))$", value)
            }
            let systemErrorCode = errno
            guard result >= 0 else {
                lockTracker?.recordFailure(for: [lockFact])
                throw .gitFailure(
                    LibGit2ErrorCapture.failure(
                        code: result,
                        lockFacts: [lockFact],
                        systemErrorCode: systemErrorCode
                    ))
            }
        }
    }

    /// `literal` as a regular expression that matches only itself.
    private static func escapedPattern(_ literal: String) -> String {
        let special = Set("\\^$.|?*+()[]{}")
        return literal.reduce(into: "") { pattern, character in
            if special.contains(character) {
                pattern.append("\\")
            }
            pattern.append(character)
        }
    }
}
