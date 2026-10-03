import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Captures one Git node's sparse intent from its source administration. The pattern file is the
/// authority; a source index libgit2 can read refines the result with Git's persisted skip-worktree
/// flags, and a sparse-index source (which libgit2 1.9 rejects) falls back to the matcher alone.
enum WorktreeForkSparseCapture {
    static func capture(
        repository: OpaquePointer,
        gitDirectory: URL,
        treeEntries: [String: WorktreeForkTreeEntry]
    ) throws(GitWorktreeForkError) -> WorktreeForkSparsePlan? {
        guard let configuration = configurationSnapshot(repository) else {
            return nil
        }
        defer { git_config_free(configuration) }
        guard booleanSetting(configuration, "core.sparseCheckout") == true else {
            return nil
        }
        let coneMode = booleanSetting(configuration, "core.sparseCheckoutCone") ?? false

        let patternFile = (try? Data(contentsOf: gitDirectory.appending(path: "info/sparse-checkout"))) ?? Data()
        let worktreeConfiguration = try? Data(contentsOf: gitDirectory.appending(path: "config.worktree"))
        let matcher = SparseCheckoutMatcher(
            patternFile: String(bytes: patternFile, encoding: .utf8) ?? "", coneMode: coneMode)
        let persistedFlags = persistedSkipWorktreeFlags(indexPath: gitDirectory.appending(path: "index"))
        // The matcher decides every path the source index cannot vouch for; with an untranslatable pattern
        // it would expose or hide paths the source did not, so fail before mutation instead.
        let matcherDecidesSomePath =
            persistedFlags.map { flags in treeEntries.keys.contains { flags[$0] == nil } } ?? true
        if matcher.hasUntranslatablePatterns, matcherDecidesSomePath {
            throw .entryFailed(
                relativePath: "info/sparse-checkout", reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        let skipWorktreePaths = Set(
            treeEntries.keys.filter { path in
                persistedFlags?[path] ?? !matcher.includes(path)
            })
        return WorktreeForkSparsePlan(
            sourceGitDirectory: gitDirectory,
            patternFile: patternFile,
            worktreeConfiguration: worktreeConfiguration,
            skipWorktreePaths: skipWorktreePaths
        )
    }

    private static func configurationSnapshot(_ repository: OpaquePointer) -> OpaquePointer? {
        var configuration: OpaquePointer?
        guard git_repository_config_snapshot(&configuration, repository) >= 0 else {
            return nil
        }
        return configuration
    }

    static func booleanSetting(_ configuration: OpaquePointer, _ name: String) -> Bool? {
        var value: Int32 = 0
        return git_config_get_bool(&value, configuration, name) >= 0 ? value != 0 : nil
    }

    /// Stage-0 skip-worktree flags from a readable source index; nil when the index is absent or uses an
    /// extension libgit2 cannot read. Stage numbers, conflicts, and stat data are never carried over.
    private static func persistedSkipWorktreeFlags(indexPath: URL) -> [String: Bool]? {
        var index: OpaquePointer?
        let openResult = indexPath.path.withCString { git_index_open(&index, $0) }
        guard openResult >= 0, let index else {
            return nil
        }
        defer { git_index_free(index) }
        var flags: [String: Bool] = [:]
        for position in 0..<git_index_entrycount(index) {
            guard var entry = git_index_get_byindex(index, position)?.pointee, let path = entry.path,
                git_index_entry_stage(&entry) == 0
            else {
                continue
            }
            flags[String(cString: path)] =
                entry.flags_extended & UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue) != 0
        }
        return flags
    }
}
