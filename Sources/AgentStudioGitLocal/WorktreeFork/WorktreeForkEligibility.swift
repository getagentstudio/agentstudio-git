import AgentStudioGitContracts
import Darwin
import Foundation

struct WorktreeForkVolumeFacts: Equatable, Sendable {
    let fileSystemTypeName: String
    let deviceID: Int32
    let supportsFileCloning: Bool
    /// iCloud Drive and CloudStorage domains pass every APFS, device, and clone check, so File Provider
    /// management is its own fact (`isUbiquitousItemKey`, nil treated as false).
    let isFileProviderManaged: Bool
}

/// Everything eligibility depends on, gathered before any mutation so the rule itself is a pure function.
struct WorktreeForkEligibilityFacts: Equatable, Sendable {
    let operatingSystemMajorVersion: Int
    let source: WorktreeForkVolumeFacts
    let destinationParent: WorktreeForkVolumeFacts
    /// Nested common directories and object alternates that must receive destination-owned CoW mirrors.
    let mirroredAdministrativeStores: [WorktreeForkVolumeFacts]
}

enum WorktreeForkEligibility {
    static let minimumOperatingSystemMajorVersion = 26
    static let apfsFileSystemTypeName = "apfs"

    static func rejection(for facts: WorktreeForkEligibilityFacts) -> GitWorktreeForkRejectionReason? {
        if let hostRejection = hostRejection(operatingSystemMajorVersion: facts.operatingSystemMajorVersion) {
            return hostRejection
        }
        if facts.source.fileSystemTypeName != apfsFileSystemTypeName {
            return .sourceFilesystemNotAPFS
        }
        if facts.destinationParent.fileSystemTypeName != apfsFileSystemTypeName {
            return .destinationFilesystemNotAPFS
        }
        if facts.source.deviceID != facts.destinationParent.deviceID {
            return .crossDevice
        }
        if !facts.source.supportsFileCloning {
            return .cloneCapabilityUnavailable
        }
        if facts.source.isFileProviderManaged || facts.destinationParent.isFileProviderManaged {
            return .fileProviderManagedLocation
        }
        if facts.mirroredAdministrativeStores.contains(where: { $0.deviceID != facts.source.deviceID }) {
            return .administrativeStoreOnDifferentDevice
        }
        return nil
    }

    static func hostRejection(operatingSystemMajorVersion: Int) -> GitWorktreeForkRejectionReason? {
        operatingSystemMajorVersion < minimumOperatingSystemMajorVersion ? .unsupportedOperatingSystem : nil
    }
}

/// Reads the live host and volume facts eligibility consumes. Tests substitute facts to cover hosts and
/// volumes that cannot be constructed locally (older macOS, second volumes, non-APFS filesystems).
struct WorktreeForkHostFactsProvider: Sendable {
    static let live = Self(
        operatingSystemMajorVersion: { ProcessInfo.processInfo.operatingSystemVersion.majorVersion },
        volumeFacts: { path throws(GitWorktreeForkError) in try liveVolumeFacts(at: path) }
    )

    let operatingSystemMajorVersion: @Sendable () -> Int
    let volumeFacts: @Sendable (URL) throws(GitWorktreeForkError) -> WorktreeForkVolumeFacts
    /// The directory `~/` names in configuration paths. Git expands `~` from `HOME`, so the live value does
    /// too; tests point it at a fixture directory instead of the real home.
    let homeDirectory: @Sendable () -> URL

    init(
        operatingSystemMajorVersion: @escaping @Sendable () -> Int,
        volumeFacts: @escaping @Sendable (URL) throws(GitWorktreeForkError) -> WorktreeForkVolumeFacts,
        homeDirectory: @escaping @Sendable () -> URL = Self.liveHomeDirectory
    ) {
        self.operatingSystemMajorVersion = operatingSystemMajorVersion
        self.volumeFacts = volumeFacts
        self.homeDirectory = homeDirectory
    }

    private static func liveHomeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func liveVolumeFacts(at path: URL) throws(GitWorktreeForkError) -> WorktreeForkVolumeFacts {
        var fileSystem = statfs()
        let statfsResult = path.path.withCString { statfs($0, &fileSystem) }
        guard statfsResult == 0 else {
            throw .entryFailed(relativePath: ".", reason: .unreadableEntry, errorNumber: errno)
        }
        let typeName = withUnsafeBytes(of: fileSystem.f_fstypename) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        let deviceID: Int32
        switch WorktreeForkDescriptors.lstatPath(path) {
        case .success(let info):
            deviceID = info.st_dev
        case .failure(let failure):
            throw .entryFailed(relativePath: ".", reason: .unreadableEntry, errorNumber: failure.code)
        }
        let resourceValues = try? path.resourceValues(forKeys: [.volumeSupportsFileCloningKey, .isUbiquitousItemKey])
        return WorktreeForkVolumeFacts(
            fileSystemTypeName: typeName,
            deviceID: deviceID,
            supportsFileCloning: resourceValues?.volumeSupportsFileCloning ?? false,
            isFileProviderManaged: resourceValues?.isUbiquitousItem ?? false
        )
    }
}
