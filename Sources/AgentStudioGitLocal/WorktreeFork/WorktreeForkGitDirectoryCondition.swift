import Foundation

/// The path pattern of an `[includeIf "gitdir:<pattern>"]` or `gitdir/i:` section, decomposed the way Git
/// reads it, so a condition naming relocated administration can follow it like a path value does.
struct WorktreeForkGitDirectoryCondition: Equatable, Sendable {
    /// Where an absolute pattern points: its literal leading directories, then the glob components Git
    /// matches beneath them.
    struct Location: Equatable, Sendable {
        let literal: URL
        let globTail: [String]
        /// Git reads a trailing `/` as `/**`.
        let trailingSlash: Bool

        var matchesBeneathLiteral: Bool {
            !globTail.isEmpty || trailingSlash
        }
    }

    /// `gitdir:` or `gitdir/i:`.
    let prefix: String
    let pattern: String

    private static let prefixes = ["gitdir:", "gitdir/i:"]
    private static let globCharacters = Set("*?[\\")

    /// The condition of an `includeif.<condition>.path` entry, as libgit2 names it, when it is a gitdir one.
    /// `onbranch:` and `hasconfig:` conditions name no path.
    static func parse(includeName name: String) -> Self? {
        guard name.hasPrefix("includeif."), name.hasSuffix(".path") else {
            return nil
        }
        let condition = String(name.dropFirst("includeif.".count).dropLast(".path".count))
        guard let prefix = prefixes.first(where: { condition.hasPrefix($0) }) else {
            return nil
        }
        return Self(prefix: prefix, pattern: String(condition.dropFirst(prefix.count)))
    }

    /// The pattern's location, resolved as Git does: `~/` against the home directory and `./` against the
    /// directory of the file holding the condition. Nil for any other relative pattern, which Git prefixes
    /// with `**/` so it can match anywhere; that names no location to relocate.
    func location(includedFrom file: URL, homeDirectory: URL) -> Location? {
        let expanded: String
        if pattern.hasPrefix("~/") {
            expanded = homeDirectory.path + "/" + pattern.dropFirst(2)
        } else if pattern.hasPrefix("./") {
            expanded = file.deletingLastPathComponent().path + "/" + pattern.dropFirst(2)
        } else if pattern.hasPrefix("/") {
            expanded = pattern
        } else {
            return nil
        }
        let components = expanded.split(separator: "/").map(String.init)
        let literalCount =
            components.firstIndex { component in component.contains { Self.globCharacters.contains($0) } }
            ?? components.count
        let literalPath = "/" + components[..<literalCount].joined(separator: "/")
        return Location(
            literal: WorktreeForkSourcePathRelocation.canonicalized(absolutePath: literalPath),
            globTail: Array(components[literalCount...]),
            trailingSlash: expanded.hasSuffix("/")
        )
    }

    /// The `includeIf` subsection as written: the prefix and the pattern.
    var subsection: String {
        prefix + pattern
    }

    /// This condition's subsection with `pattern` in place of the current one.
    func subsection(withPattern pattern: String) -> String {
        prefix + pattern
    }

    /// `literal` followed by the glob tail and trailing slash of `location`.
    static func pattern(literal: String, following location: Location) -> String {
        ([literal] + location.globTail).joined(separator: "/") + (location.trailingSlash ? "/" : "")
    }
}
