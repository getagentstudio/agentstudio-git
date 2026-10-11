import AgentStudioGitContracts
import CLibGit2Local
import CryptoKit
import Darwin
import Foundation

struct LibGit2LargeFileStore: Sendable {
    private static let objectOpenFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    private static let cloneFlags = UInt32(CLONE_NOFOLLOW | CLONE_ACL)
    private static let hashBufferByteCount = 1_048_576
    private let faults: LibGit2LargeFileStoreFaultInjector

    init(faults: LibGit2LargeFileStoreFaultInjector = LibGit2LargeFileStoreFaultInjector()) {
        self.faults = faults
    }

    func storageRoot(repository: OpaquePointer, commonDirectory: URL) -> Result<URL, LargeFileStoreFailure> {
        var configuration: OpaquePointer?
        let configurationResult = git_repository_config_snapshot(&configuration, repository)
        guard configurationResult >= 0, let configuration else {
            return .failure(LargeFileStoreFailure(reason: .readFailed(errno: Self.readErrorNumber())))
        }
        defer { git_config_free(configuration) }

        var storagePathBuffer = git_buf(ptr: nil, reserved: 0, size: 0)
        defer { git_buf_dispose(&storagePathBuffer) }
        let storagePathResult = "lfs.storage".withCString {
            git_config_get_path(&storagePathBuffer, configuration, $0)
        }
        if storagePathResult == GIT_ENOTFOUND.rawValue {
            return .success(commonDirectory.appending(path: "lfs/objects").standardizedFileURL)
        }
        guard storagePathResult >= 0, let storagePathPointer = storagePathBuffer.ptr else {
            return .failure(LargeFileStoreFailure(reason: .readFailed(errno: Self.readErrorNumber())))
        }

        let configuredPath = String(cString: storagePathPointer)
        guard !configuredPath.isEmpty else {
            return .success(commonDirectory.appending(path: "lfs/objects").standardizedFileURL)
        }
        let configuredRoot =
            configuredPath.hasPrefix("/")
            ? URL(fileURLWithPath: configuredPath, isDirectory: true)
            : commonDirectory.appending(path: configuredPath)
        return .success(configuredRoot.appending(path: "objects").standardizedFileURL)
    }

    func openStorageRoot(at path: URL) -> Result<Int32, LargeFileStoreFailure> {
        let canonicalRoot: URL
        switch WorktreeForkDescriptors.realpathURL(path) {
        case .success(let resolvedPath):
            canonicalRoot = resolvedPath
        case .failure(let failure):
            return .failure(LargeFileStoreFailure(reason: Self.storeOpenFailure(failure.code)))
        }
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: canonicalRoot) {
        case .success(let descriptor):
            return .success(descriptor)
        case .failure(let failure):
            return .failure(LargeFileStoreFailure(reason: Self.storeOpenFailure(failure.code)))
        }
    }

    func openObject(
        for pointer: LargeFilePointer,
        storageRootDescriptor: Int32
    ) -> Result<Int32, LargeFileStoreFailure> {
        let objectSHA256 = pointer.payloadSHA256
        let objectRelativePath = "\(objectSHA256.prefix(2))/\(objectSHA256.dropFirst(2).prefix(2))"
        let objectParentDescriptor: Int32
        switch WorktreeForkDescriptors.openDirectory(
            beneath: storageRootDescriptor,
            relativePath: objectRelativePath
        ) {
        case .success(let descriptor):
            objectParentDescriptor = descriptor
        case .failure(let failure):
            return .failure(LargeFileStoreFailure(reason: Self.storeOpenFailure(failure.code)))
        }
        defer { close(objectParentDescriptor) }

        let objectDescriptor = objectSHA256.withCString {
            openat(objectParentDescriptor, $0, Self.objectOpenFlags)
        }
        guard objectDescriptor >= 0 else {
            return .failure(LargeFileStoreFailure(reason: Self.storeOpenFailure(errno)))
        }
        var closeObjectDescriptor = true
        defer {
            if closeObjectDescriptor {
                close(objectDescriptor)
            }
        }

        guard case .success(let objectInfo) = WorktreeForkDescriptors.statDescriptor(objectDescriptor) else {
            return .failure(LargeFileStoreFailure(reason: .readFailed(errno: Self.readErrorNumber())))
        }
        guard WorktreeForkEntryKind(mode: objectInfo.st_mode) == .regularFile,
            objectInfo.st_size == off_t(pointer.payloadByteCount)
        else {
            return .failure(LargeFileStoreFailure(reason: .objectMismatch))
        }
        guard objectInfo.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .failure(LargeFileStoreFailure(reason: .readFailed(errno: EIO)))
        }

        closeObjectDescriptor = false
        return .success(objectDescriptor)
    }

    func materialize(
        request: LargeFileStoreMaterializationRequest,
        storageRootDescriptor: Int32,
        worktreeRootDescriptor: Int32
    ) -> Result<LargeFileStoreMaterialization, LargeFileStoreFailure> {
        let objectDescriptor: Int32
        switch openObject(for: request.pointer, storageRootDescriptor: storageRootDescriptor) {
        case .success(let descriptor):
            objectDescriptor = descriptor
        case .failure(let reason):
            return .failure(reason)
        }
        defer { close(objectDescriptor) }

        let (destinationParentPath, destinationName) = WorktreeForkDescriptors.splitParent(request.path)
        let destinationParentDescriptor: Int32
        switch WorktreeForkDescriptors.openDirectory(
            beneath: worktreeRootDescriptor,
            relativePath: destinationParentPath
        ) {
        case .success(let descriptor):
            destinationParentDescriptor = descriptor
        case .failure(let failure):
            return .failure(LargeFileStoreFailure(reason: .writeFailed(errno: failure.code)))
        }
        defer { close(destinationParentDescriptor) }

        let temporaryName = faults.temporaryName() ?? ".agentstudio-lfs-fill-\(UUID().uuidString)"
        let (temporaryParentPath, _) = WorktreeForkDescriptors.splitParent(request.path)
        let residuePath = temporaryParentPath.isEmpty ? temporaryName : "\(temporaryParentPath)/\(temporaryName)"
        var temporaryExists = false
        var temporaryIdentity: WorktreeForkEntryIdentity?

        faults.beforeClone(parentDescriptor: destinationParentDescriptor, name: temporaryName)
        let cloneResult: Int32
        if let injectedCloneError = faults.cloneError() {
            errno = injectedCloneError
            cloneResult = -1
        } else {
            cloneResult = temporaryName.withCString {
                fclonefileat(objectDescriptor, destinationParentDescriptor, $0, Self.cloneFlags)
            }
        }
        if cloneResult == 0 {
            temporaryExists = true
            temporaryIdentity = temporaryEntryIdentity(named: temporaryName, in: destinationParentDescriptor)
            faults.afterTemporaryAcquired(parentDescriptor: destinationParentDescriptor, name: temporaryName)
        } else {
            let cloneErrorNumber = errno
            if cloneErrorNumber != ENOTSUP, cloneErrorNumber != EXDEV {
                return .failure(LargeFileStoreFailure(reason: .writeFailed(errno: cloneErrorNumber)))
            }
            if let failure = copyObject(
                objectDescriptor,
                to: temporaryName,
                in: destinationParentDescriptor,
                expectedSize: request.pointer.payloadByteCount,
                temporaryExists: &temporaryExists,
                temporaryIdentity: &temporaryIdentity
            ) {
                let residue =
                    cleanupTemporary(
                        named: temporaryName,
                        in: destinationParentDescriptor,
                        wasCreated: temporaryExists,
                        identity: temporaryIdentity
                    ) ? nil : residuePath
                return .failure(LargeFileStoreFailure(reason: failure.reason, residuePath: residue))
            }
            faults.afterTemporaryAcquired(parentDescriptor: destinationParentDescriptor, name: temporaryName)
        }

        let materialization = verifyTemporaryAndReplace(
            request: request,
            temporaryName: temporaryName,
            destinationName: destinationName,
            destinationParentDescriptor: destinationParentDescriptor,
            temporaryIdentity: &temporaryIdentity
        )
        switch materialization {
        case .success(true):
            return .success(LargeFileStoreMaterialization(didMaterialize: true, residuePath: nil))
        case .success(false):
            let residue =
                cleanupTemporary(
                    named: temporaryName,
                    in: destinationParentDescriptor,
                    wasCreated: temporaryExists,
                    identity: temporaryIdentity
                ) ? nil : residuePath
            return .success(LargeFileStoreMaterialization(didMaterialize: false, residuePath: residue))
        case .failure(let failure):
            let residue =
                cleanupTemporary(
                    named: temporaryName,
                    in: destinationParentDescriptor,
                    wasCreated: temporaryExists,
                    identity: temporaryIdentity
                ) ? nil : residuePath
            return .failure(LargeFileStoreFailure(reason: failure.reason, residuePath: residue))
        }
    }

    private func verifyTemporaryAndReplace(
        request: LargeFileStoreMaterializationRequest,
        temporaryName: String,
        destinationName: String,
        destinationParentDescriptor: Int32,
        temporaryIdentity: inout WorktreeForkEntryIdentity?
    ) -> Result<Bool, LargeFileStoreFailure> {
        let temporaryDescriptor = temporaryName.withCString {
            openat(destinationParentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard temporaryDescriptor >= 0 else {
            return .failure(LargeFileStoreFailure(reason: .writeFailed(errno: errno)))
        }
        defer { close(temporaryDescriptor) }

        guard case .success(let temporaryInfo) = WorktreeForkDescriptors.statDescriptor(temporaryDescriptor) else {
            return .failure(LargeFileStoreFailure(reason: .readFailed(errno: Self.readErrorNumber())))
        }
        temporaryIdentity = WorktreeForkEntryIdentity(temporaryInfo)
        guard WorktreeForkEntryKind(mode: temporaryInfo.st_mode) == .regularFile,
            temporaryInfo.st_size == off_t(request.pointer.payloadByteCount)
        else {
            return .failure(LargeFileStoreFailure(reason: .objectMismatch))
        }
        let actualSHA256: String
        switch sha256(temporaryDescriptor) {
        case .success(let value):
            actualSHA256 = value
        case .failure(let failure):
            return .failure(failure)
        }
        guard actualSHA256 == request.pointer.payloadSHA256 else {
            return .failure(LargeFileStoreFailure(reason: .objectMismatch))
        }
        guard fchmod(temporaryDescriptor, mode_t(request.indexMode & 0o777)) == 0 else {
            return .failure(LargeFileStoreFailure(reason: .writeFailed(errno: errno)))
        }
        guard
            destinationStillContainsPointer(
                request.pointerData,
                path: destinationName,
                parentDescriptor: destinationParentDescriptor,
                expectedIdentity: request.expectedPointerIdentity
            )
        else {
            return .success(false)
        }
        let renameResult = temporaryName.withCString { temporaryPointer in
            destinationName.withCString { destinationPointer in
                renameat(destinationParentDescriptor, temporaryPointer, destinationParentDescriptor, destinationPointer)
            }
        }
        guard renameResult == 0 else {
            return .failure(LargeFileStoreFailure(reason: .writeFailed(errno: errno)))
        }
        return .success(true)
    }

    private func temporaryEntryIdentity(named name: String, in parentDescriptor: Int32) -> WorktreeForkEntryIdentity? {
        let descriptor = name.withCString { openat(parentDescriptor, $0, Self.objectOpenFlags) }
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        guard case .success(let info) = WorktreeForkDescriptors.statDescriptor(descriptor) else {
            return nil
        }
        return WorktreeForkEntryIdentity(info)
    }

    private func cleanupTemporary(
        named name: String,
        in parentDescriptor: Int32,
        wasCreated: Bool,
        identity expectedIdentity: WorktreeForkEntryIdentity?
    ) -> Bool {
        guard wasCreated else {
            return true
        }
        let descriptor = name.withCString { openat(parentDescriptor, $0, Self.objectOpenFlags) }
        guard descriptor >= 0 else {
            return errno == ENOENT || errno == ENOTDIR || errno == ELOOP
        }
        defer { close(descriptor) }
        guard let expectedIdentity,
            case .success(let info) = WorktreeForkDescriptors.statDescriptor(descriptor)
        else {
            return false
        }
        guard WorktreeForkEntryIdentity(info) == expectedIdentity else {
            return true
        }
        let unlinkResult = name.withCString { unlinkat(parentDescriptor, $0, 0) }
        return unlinkResult == 0 || errno == ENOENT
    }

    private func copyObject(
        _ sourceDescriptor: Int32,
        to temporaryName: String,
        in destinationParentDescriptor: Int32,
        expectedSize: Int,
        temporaryExists: inout Bool,
        temporaryIdentity: inout WorktreeForkEntryIdentity?
    ) -> LargeFileStoreFailure? {
        let destinationDescriptor = temporaryName.withCString {
            openat(
                destinationParentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard destinationDescriptor >= 0 else {
            return LargeFileStoreFailure(reason: .writeFailed(errno: errno))
        }
        temporaryExists = true
        defer { close(destinationDescriptor) }

        var destinationInfo = Darwin.stat()
        guard fstat(destinationDescriptor, &destinationInfo) == 0 else {
            return LargeFileStoreFailure(reason: .readFailed(errno: Self.readErrorNumber()))
        }
        temporaryIdentity = WorktreeForkEntryIdentity(destinationInfo)

        var copiedByteCount = 0
        var buffer = [UInt8](repeating: 0, count: Self.hashBufferByteCount)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if readCount == 0 {
                break
            }
            guard readCount > 0 else {
                if errno == EINTR {
                    continue
                }
                return LargeFileStoreFailure(reason: .readFailed(errno: errno))
            }
            copiedByteCount += readCount
            guard copiedByteCount <= expectedSize else {
                return LargeFileStoreFailure(reason: .objectMismatch)
            }
            var bytesWritten = 0
            while bytesWritten < readCount {
                let writeCount = buffer.withUnsafeBytes { bytes in
                    write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: bytesWritten),
                        readCount - bytesWritten
                    )
                }
                if writeCount < 0, errno == EINTR {
                    continue
                }
                guard writeCount > 0 else {
                    return LargeFileStoreFailure(reason: .writeFailed(errno: writeCount == 0 ? EIO : errno))
                }
                bytesWritten += writeCount
            }
        }
        guard copiedByteCount == expectedSize else {
            return LargeFileStoreFailure(reason: .objectMismatch)
        }
        return nil
    }

    private func sha256(_ descriptor: Int32) -> Result<String, LargeFileStoreFailure> {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            return .failure(LargeFileStoreFailure(reason: .readFailed(errno: errno)))
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.hashBufferByteCount)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if readCount == 0 {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return .success(digest)
            }
            guard readCount > 0 else {
                if errno == EINTR {
                    continue
                }
                return .failure(LargeFileStoreFailure(reason: .readFailed(errno: errno)))
            }
            hasher.update(data: Data(buffer.prefix(readCount)))
        }
    }

    private func destinationStillContainsPointer(
        _ pointerData: Data,
        path: String,
        parentDescriptor: Int32,
        expectedIdentity: WorktreeForkEntryIdentity
    ) -> Bool {
        let descriptor = path.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        guard case .success(let info) = WorktreeForkDescriptors.statDescriptor(descriptor),
            WorktreeForkEntryKind(mode: info.st_mode) == .regularFile,
            WorktreeForkEntryIdentity(info) == expectedIdentity,
            info.st_size == off_t(pointerData.count)
        else {
            return false
        }
        let readResult = Self.readExactly(pointerData.count, from: descriptor)
        guard case .success(let contents) = readResult else {
            return false
        }
        return contents == pointerData
    }

    static func readExactly(_ byteCount: Int, from descriptor: Int32) -> Result<Data, LargeFileStoreFailure> {
        var contents = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let readCount = contents.withUnsafeMutableBytes { bytes in
                pread(descriptor, bytes.baseAddress?.advanced(by: offset), byteCount - offset, off_t(offset))
            }
            if readCount == 0 {
                return .failure(LargeFileStoreFailure(reason: .readFailed(errno: EIO)))
            }
            guard readCount > 0 else {
                if errno == EINTR {
                    continue
                }
                return .failure(LargeFileStoreFailure(reason: .readFailed(errno: errno)))
            }
            offset += readCount
        }
        return .success(contents)
    }

    private static func storeOpenFailure(_ errorNumber: Int32) -> GitLargeFileFillMissReason {
        if errorNumber == ENOENT || errorNumber == ENOTDIR {
            return .objectAbsent
        }
        if errorNumber == ELOOP {
            return .objectMismatch
        }
        return .readFailed(errno: errorNumber)
    }

    private static func readErrorNumber() -> Int32 {
        errno == 0 ? EIO : errno
    }
}

struct LargeFileStoreMaterializationRequest: Sendable {
    let pointer: LargeFilePointer
    let pointerData: Data
    let expectedPointerIdentity: WorktreeForkEntryIdentity
    let indexMode: UInt32
    let path: String
}

struct LargeFileStoreFailure: Error, Sendable {
    let reason: GitLargeFileFillMissReason
    let residuePath: String?

    init(reason: GitLargeFileFillMissReason, residuePath: String? = nil) {
        self.reason = reason
        self.residuePath = residuePath
    }
}

struct LargeFileStoreMaterialization: Sendable {
    let didMaterialize: Bool
    let residuePath: String?
}

struct LibGit2LargeFileStoreFaultInjector: Sendable {
    private let temporaryNameValue: String?
    private let cloneErrorValue: Int32?
    private let beforeCloneHandler: @Sendable (Int32, String) -> Void
    private let afterTemporaryAcquiredHandler: @Sendable (Int32, String) -> Void

    init(
        temporaryName: String? = nil,
        cloneError: Int32? = nil,
        beforeClone: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
        afterTemporaryAcquired: @escaping @Sendable (Int32, String) -> Void = { _, _ in }
    ) {
        temporaryNameValue = temporaryName
        cloneErrorValue = cloneError
        beforeCloneHandler = beforeClone
        afterTemporaryAcquiredHandler = afterTemporaryAcquired
    }

    func temporaryName() -> String? {
        temporaryNameValue
    }

    func cloneError() -> Int32? {
        cloneErrorValue
    }

    func beforeClone(parentDescriptor: Int32, name: String) {
        beforeCloneHandler(parentDescriptor, name)
    }

    func afterTemporaryAcquired(parentDescriptor: Int32, name: String) {
        afterTemporaryAcquiredHandler(parentDescriptor, name)
    }
}
