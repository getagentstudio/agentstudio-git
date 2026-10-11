import Foundation

/// Decides whether an attribute input is directly covered by a worktree subtree observation.
struct GitWorktreeAttributeProbe: Sendable {
    static let live = Self { path in
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        return pathURL.resolvingSymlinksInPath() == pathURL
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil
    }

    let isDirect: @Sendable (String) -> Bool
}
