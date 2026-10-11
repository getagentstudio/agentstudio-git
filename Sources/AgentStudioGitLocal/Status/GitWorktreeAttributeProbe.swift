import Darwin

enum GitWorktreeAttributeLookup: Sendable {
    case mode(mode_t)
    case failure(Int32)
}

/// Decides whether an attribute input is directly covered by a worktree subtree observation.
struct GitWorktreeAttributeProbe: Sendable {
    static let live = Self { pathPointer in
        var information = Darwin.stat()
        // macOS 14's kernel implements this flag: final links yield link metadata;
        // an intermediate link fails lookup instead of hiding behind an absent leaf.
        let result = fstatat(AT_FDCWD, pathPointer, &information, AT_SYMLINK_NOFOLLOW_ANY)
        return result == 0 ? .mode(information.st_mode) : .failure(errno)
    }

    let lookup: @Sendable (UnsafePointer<CChar>) -> GitWorktreeAttributeLookup

    func isDirect(_ path: UnsafePointer<CChar>) -> Bool {
        switch lookup(path) {
        case .mode(let mode): mode & S_IFMT != S_IFLNK
        case .failure(let errorNumber): errorNumber == ENOENT
        }
    }
}
