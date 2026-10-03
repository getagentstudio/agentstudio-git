import AgentStudioGitContracts
import Darwin
import Foundation

/// Renames a configuration subsection in place by rewriting only its header lines. Git configuration is
/// last-wins, so moving a section's entries through libgit2 (delete, then set, which appends) would change
/// which value takes effect; libgit2 exposes no in-place section rename. Every entry, comment, and their order
/// stay where they were, and the result is verified by reading the file back through libgit2.
enum WorktreeForkConfigurationSectionRename {
    /// Renames every `[<section> "<oldSubsection>"]` header in `path` to `newSubsection`.
    static func renameSubsection(
        section: String,
        from oldSubsection: String,
        to newSubsection: String,
        in path: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let unresolvable = GitWorktreeForkError.entryFailed(
            relativePath: "\(reportPath): \(section.lowercased()).\(oldSubsection)",
            reason: .unresolvableGitAdministration,
            errorNumber: nil
        )
        let original = try WorktreeForkDatalessGuardedRead.run(path, reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            try? String(contentsOf: path, encoding: .utf8)
        }
        guard let original else {
            throw unresolvable
        }
        let entriesBefore = try WorktreeForkConfigurationFile.ownEntries(in: path, reportPath: reportPath)
        var renamedHeaders = 0
        let lines = original.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let header = SectionHeader(line: String(line)),
                header.section.lowercased() == section.lowercased(),
                header.subsection == oldSubsection
            else {
                return String(line)
            }
            renamedHeaders += 1
            return header.renamed(to: newSubsection)
        }
        guard renamedHeaders > 0 else {
            throw unresolvable
        }
        let renamed = lines.joined(separator: "\n")
        try WorktreeForkMetadataPreservingRewrite.rewrite(path, metadataFrom: .editedFile, reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            try replace(path, with: Data(renamed.utf8), reportPath: reportPath)
        }
        let oldPrefix = "\(section.lowercased()).\(oldSubsection)."
        let expected = entriesBefore.map { entry in
            guard entry.name.hasPrefix(oldPrefix) else {
                return entry
            }
            let variable = entry.name.dropFirst(oldPrefix.count)
            return WorktreeForkConfigurationEntry(
                name: "\(section.lowercased()).\(newSubsection).\(variable)", value: entry.value)
        }
        guard try WorktreeForkConfigurationFile.ownEntries(in: path, reportPath: reportPath) == expected else {
            throw unresolvable
        }
    }

    /// Writes `data` beside `path` and renames it over `path`.
    private static func replace(_ path: URL, with data: Data, reportPath: String) throws(GitWorktreeForkError) {
        let temporary = path.deletingLastPathComponent()
            .appending(path: ".\(path.lastPathComponent).agentstudio-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
        } catch {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: nil)
        }
        guard rename(temporary.path, path.path) == 0 else {
            let failure = errno
            _ = unlink(temporary.path)
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
        }
    }
}

/// One `[section "subsection"]` header line, parsed with Git's quoting: inside the quotes `\"` and `\\` stand
/// for themselves and any other backslash is dropped. Text after the closing `]` (an entry on the same line,
/// a comment) is kept verbatim.
private struct SectionHeader {
    let indentation: Substring
    let section: String
    let subsection: String
    let remainder: Substring

    init?(line: String) {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        var cursor = line[indentation.endIndex...]
        guard cursor.first == "[" else {
            return nil
        }
        cursor = cursor.dropFirst()
        let section = cursor.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        guard !section.isEmpty else {
            return nil
        }
        cursor = cursor[section.endIndex...].drop { $0 == " " || $0 == "\t" }
        guard cursor.first == "\"" else {
            return nil
        }
        cursor = cursor.dropFirst()
        var subsection = ""
        var closed = false
        while let character = cursor.first {
            cursor = cursor.dropFirst()
            if character == "\"" {
                closed = true
                break
            }
            if character == "\\", let escaped = cursor.first {
                subsection.append(escaped)
                cursor = cursor.dropFirst()
            } else {
                subsection.append(character)
            }
        }
        guard closed, cursor.first == "]" else {
            return nil
        }
        self.indentation = indentation
        self.section = String(section)
        self.subsection = subsection
        self.remainder = cursor.dropFirst()
    }

    func renamed(to newSubsection: String) -> String {
        let escaped = newSubsection.reduce(into: "") { text, character in
            if character == "\"" || character == "\\" {
                text.append("\\")
            }
            text.append(character)
        }
        return "\(indentation)[\(section) \"\(escaped)\"]\(remainder)"
    }
}
