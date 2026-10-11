import AgentStudioGitCInterop
import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2StatusObservationIdentityReader: Sendable {
    private let runtime: LibGit2Runtime
    private let worktreeAttributeProbe: GitWorktreeAttributeProbe

    init(
        runtime: LibGit2Runtime = .shared,
        worktreeAttributeProbe: GitWorktreeAttributeProbe = .live
    ) {
        self.runtime = runtime
        self.worktreeAttributeProbe = worktreeAttributeProbe
    }

    func plan(for worktreePath: URL) throws -> GitStatusObservationPlan {
        try withRepository(at: worktreePath) { repository in
            try plan(repository: repository)
        }
    }

    func plan(repository: OpaquePointer, requiresWorktreeAttributeCoverage: Bool = true) throws
        -> GitStatusObservationPlan
    {
        let worktreePath = try requiredGitURL(git_repository_workdir(repository), label: "work directory")
        let gitDirectory = try requiredGitURL(git_repository_path(repository), label: "Git directory")
        let commonDirectory = try requiredGitURL(git_repository_commondir(repository), label: "common Git directory")
        let indexPath = try GitIndexPathResolver().indexPath(repository: repository)
        var scopes = Set<GitStatusObservationScope>()
        var directScopeCoverage = true

        func observe(_ kind: GitStatusObservationScopeKind, _ path: URL) {
            directScopeCoverage = directScopeCoverage && isDirectObservationPath(path)
            scopes.insert(scope(kind, path))
        }

        observe(.subtree, worktreePath)
        observe(.item, indexPath)
        observe(.item, gitDirectory.appending(path: "HEAD"))
        observe(.item, gitDirectory.appending(path: "config.worktree"))
        observe(.item, gitDirectory.appending(path: "shallow"))
        observe(.subtree, commonDirectory.appending(path: "refs", directoryHint: .isDirectory))
        observe(.item, commonDirectory.appending(path: "packed-refs"))
        observe(.item, commonDirectory.appending(path: "config"))
        observe(.item, commonDirectory.appending(path: "info/exclude"))
        observe(.item, commonDirectory.appending(path: "info/attributes"))

        let configDependencies = try configurationDependencies(repository: repository)
        scopes.formUnion(configDependencies.scopes)

        let gitModulesPath = worktreePath.appending(path: ".gitmodules")
        let hasSubmodules = FileManager.default.fileExists(atPath: gitModulesPath.path)
        if hasSubmodules {
            observe(.item, gitModulesPath)
            observe(.subtree, commonDirectory.appending(path: "modules", directoryHint: .isDirectory))
        }

        let attributeCoverageRequired =
            requiresWorktreeAttributeCoverage && configDependencies.complete && directScopeCoverage
        let directAttributeCoverage =
            attributeCoverageRequired
            ? try hasDirectWorktreeAttributes(repository: repository, worktreePath: worktreePath) : false
        let sortedScopes = scopes.sorted {
            ($0.path.path, $0.kind.rawValue) < ($1.path.path, $1.kind.rawValue)
        }
        let descriptor = sortedScopes.map { "\($0.kind.rawValue):\($0.path.path)" }.joined(separator: "\u{0}")
        let identity = GitStatusObservationIdentity(
            rawValue: Data(descriptor.utf8).base64EncodedString()
        )
        return GitStatusObservationPlan(
            identity: identity,
            scopes: sortedScopes,
            support: configDependencies.complete && directScopeCoverage && directAttributeCoverage
                ? .supported : .unsupported
        )
    }

    private func configurationDependencies(
        repository: OpaquePointer
    ) throws -> (scopes: Set<GitStatusObservationScope>, complete: Bool) {
        var configuration: OpaquePointer?
        let configurationResult = git_repository_config(&configuration, repository)
        guard configurationResult >= 0, let configuration else {
            throw LibGit2ErrorCapture.failure(code: configurationResult)
        }
        defer { git_config_free(configuration) }

        var iterator: OpaquePointer?
        let iteratorResult = git_config_iterator_new(&iterator, configuration)
        guard iteratorResult >= 0, let iterator else {
            throw LibGit2ErrorCapture.failure(code: iteratorResult)
        }
        defer { git_config_iterator_free(iterator) }

        var scopes = Set<GitStatusObservationScope>()
        var complete = true
        // Observe candidates even when absent: creating a higher-precedence file changes Git's inputs.
        for (level, filenames) in [
            (GIT_CONFIG_LEVEL_GLOBAL, [".gitconfig"]),
            (GIT_CONFIG_LEVEL_XDG, ["config", "attributes", "ignore"]),
            (GIT_CONFIG_LEVEL_SYSTEM, ["gitconfig", "gitattributes"]),
        ] {
            var searchPathBuffer = git_buf(ptr: nil, reserved: 0, size: 0)
            defer { git_buf_dispose(&searchPathBuffer) }
            guard agentstudio_git_get_search_path(level, &searchPathBuffer) == 0 else {
                complete = false
                continue
            }
            let searchPath = searchPathBuffer.ptr.map { String(cString: $0) } ?? ""
            for directory in searchPathDirectories(searchPath) {
                guard directory.hasPrefix("/") else {
                    complete = false
                    continue
                }
                for filename in filenames {
                    let candidatePath = URL(fileURLWithPath: directory).appending(path: filename)
                    complete = complete && isDirectObservationPath(candidatePath)
                    scopes.insert(scope(.item, candidatePath))
                }
            }
        }
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let nextResult = git_config_next(&entry, iterator)
            if nextResult == GIT_ITEROVER.rawValue {
                break
            }
            guard nextResult >= 0, let entry else {
                throw LibGit2ErrorCapture.failure(code: nextResult)
            }
            if let namePointer = entry.pointee.name {
                let name = String(cString: namePointer).lowercased()
                if name == "include.path" || (name.hasPrefix("includeif.") && name.hasSuffix(".path")) {
                    // Entry origins cannot enumerate empty, missing, or inactive include targets.
                    // Keep exact reads available without renewing clean authority from incomplete scopes.
                    complete = false
                }
            }
            guard let originPointer = entry.pointee.origin_path else {
                complete = false
                continue
            }
            let originPath = String(cString: originPointer)
            guard originPath.hasPrefix("/") else {
                complete = false
                continue
            }
            let configurationPath = URL(fileURLWithPath: originPath)
            complete = complete && isDirectObservationPath(configurationPath)
            scopes.insert(scope(.item, configurationPath))

        }

        for dependencyKey in ["core.excludesfile", "core.attributesfile"] {
            var dependencyPathBuffer = git_buf(ptr: nil, reserved: 0, size: 0)
            defer { git_buf_dispose(&dependencyPathBuffer) }
            let dependencyResult = dependencyKey.withCString {
                git_config_get_path(&dependencyPathBuffer, configuration, $0)
            }
            if dependencyResult == 0, let pathPointer = dependencyPathBuffer.ptr {
                let dependencyPath = String(cString: pathPointer)
                guard dependencyPath.hasPrefix("/") else {
                    return (scopes, false)
                }
                let configuredDependency = URL(fileURLWithPath: dependencyPath)
                complete = complete && isDirectObservationPath(configuredDependency)
                scopes.insert(scope(.item, configuredDependency))
            } else if dependencyResult != GIT_ENOTFOUND.rawValue {
                complete = false
            }
        }
        return (scopes, complete)
    }

    private func hasDirectWorktreeAttributes(repository: OpaquePointer, worktreePath: URL) throws -> Bool {
        var index: OpaquePointer?
        let indexResult = git_repository_index(&index, repository)
        guard indexResult >= 0, let index else {
            throw LibGit2ErrorCapture.failure(code: indexResult)
        }
        defer { git_index_free(index) }

        // libgit2 reads attributes along each indexed path's ancestors. A subtree
        // watch cannot cover an external symlink target; keep exact reads instead.
        var checkedDirectories = Set<URL>()
        for entryIndex in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, entryIndex), let path = entry.pointee.path else {
                return false
            }
            var directory = worktreePath.appending(path: String(cString: path)).deletingLastPathComponent()
            while checkedDirectories.insert(directory).inserted {
                let attributesPath = directory.appending(path: ".gitattributes")
                if !worktreeAttributeProbe.isDirect(attributesPath.path) {
                    return false
                }
                if directory == worktreePath { break }
                let parentDirectory = directory.deletingLastPathComponent()
                guard parentDirectory != directory else { return false }
                directory = parentDirectory
            }
        }
        return true
    }

    private func scope(_ kind: GitStatusObservationScopeKind, _ path: URL) -> GitStatusObservationScope {
        GitStatusObservationScope(kind: kind, path: canonicalURL(path))
    }

    private func searchPathDirectories(_ searchPath: String) -> [String] {
        var directories: [String] = []
        var directory = ""
        var previousCharacter: Character?
        // Match pinned libgit2's macOS directory-list parsing, including escaped separators.
        for character in searchPath {
            if character == ":", previousCharacter != "\\" {
                if !directory.isEmpty { directories.append(directory) }
                directory = ""
            } else {
                directory.append(character)
            }
            previousCharacter = character
        }
        if !directory.isEmpty { directories.append(directory) }
        return directories
    }

    private func canonicalURL(_ path: URL) -> URL {
        path.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isDirectObservationPath(_ path: URL) -> Bool {
        // Canonical scopes cannot prove that an unobserved alias was not retargeted.
        canonicalURL(path) == path.standardizedFileURL
    }

    private func requiredGitURL(_ pointer: UnsafePointer<CChar>?, label: String) throws -> URL {
        guard let pointer else {
            throw LibGit2ErrorCapture.fallbackFailure(code: -1, message: "libgit2 returned no \(label)")
        }
        return canonicalURL(URL(fileURLWithPath: String(cString: pointer)))
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()
        var repository: OpaquePointer?
        let openResult = path.path.withCString { git_repository_open_ext(&repository, $0, 0, nil) }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }
        return try body(repository)
    }
}
