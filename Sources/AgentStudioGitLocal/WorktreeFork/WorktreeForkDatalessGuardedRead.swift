import AgentStudioGitContracts
import Darwin
import Foundation

/// The one way fork code reads a file's payload after planning: with dataless materialization denied on this
/// thread, and only after a contained no-follow open proves the file is not a dataless placeholder. Strict CoW
/// never authorizes a download; a file that became dataless fails closed. The policy is thread-scoped, so a
/// caller wraps each synchronous read, never an asynchronous span.
enum WorktreeForkDatalessGuardedRead {
    /// Runs `read` under the denial once `file` is shown not to be dataless. A missing file still runs `read`,
    /// which reports absence its own way.
    static func run<Value>(
        _ file: URL,
        reportPath: String,
        _ read: () throws(GitWorktreeForkError) -> Value
    ) throws(GitWorktreeForkError) -> Value {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            let canonical = WorktreeForkSourcePathRelocation.canonicalized(absolutePath: file.path)
            let contained = WorktreeForkFileEquivalence.ContainedFile(
                root: canonical.deletingLastPathComponent(), remainder: canonical.lastPathComponent)
            if let descriptor = try WorktreeForkFileEquivalence.open(contained, reportPath: reportPath) {
                defer { close(descriptor) }
                try rejectDataless(descriptor, reportPath: reportPath)
            }
            return try read()
        }
    }

    /// Fails `.datalessFile` when the open file's payload is not local, classified by the walker's own rule.
    static func rejectDataless(_ descriptor: Int32, reportPath: String) throws(GitWorktreeForkError) {
        guard case .success(let info) = WorktreeForkDescriptors.statDescriptor(descriptor) else {
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: errno)
        }
        if WorktreeForkEntryPolicy.disposition(for: .regularFile, flags: info.st_flags) == .rejectDataless {
            throw .entryFailed(relativePath: reportPath, reason: .datalessFile, errorNumber: nil)
        }
    }

    /// Whether `error` is the dataless refusal, which callers that map read failures must pass through.
    static func isDatalessRefusal(_ error: GitWorktreeForkError) -> Bool {
        if case .entryFailed(_, .datalessFile, _) = error {
            return true
        }
        return false
    }
}
