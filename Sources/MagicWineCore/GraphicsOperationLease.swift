import Darwin
import Foundation

// Launch intent closes the fresh-metadata → spawn gap. The separate lifetime
// lease lets setup stop running Wine before waiting for every old process to exit.
final class GraphicsOperationLease: @unchecked Sendable {
    enum Kind: String { case launch, lifetime }
    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { release() }
    static func acquire(paths: ApplicationPaths, bottleID: UUID, kind: Kind,
                        exclusive: Bool, timeout: Duration = .seconds(30)) async throws -> GraphicsOperationLease {
        try Task.checkCancellation()
        let storage = try paths.bottlesDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard storage.isDirectory == true, storage.isSymbolicLink != true else {
            throw MagicWineError.unsafeFilesystem("The bottle storage directory must be an ordinary directory, not a symbolic link.")
        }
        let directory = paths.bottlesDirectory.appendingPathComponent(".graphics-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
            throw MagicWineError.unsafeFilesystem("The bottle graphics lock directory must be an ordinary directory, not a symbolic link.")
        }
        let file = directory.appendingPathComponent("\(bottleID.uuidString)-\(kind.rawValue).lock")
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw MagicWineError.setup("Cannot open the graphics operation lock: \(String(cString: strerror(errno)))")
        }
        let lease = GraphicsOperationLease(descriptor: descriptor)
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1 else {
                throw MagicWineError.unsafeFilesystem("The graphics operation lock must be a regular file without hard links.")
            }
            guard try await AdvisoryFileLock.acquire(descriptor, exclusive: exclusive, timeout: timeout) else {
                // An exclusive lifetime lease waits for running Windows programs; every
                // other wait is for another launch or configuration.
                if kind == .lifetime && exclusive {
                    throw MagicWineError.busy("Windows programs are still running in this bottle; no graphics files were changed by this operation.", reason: .programsRunning)
                }
                throw MagicWineError.busy("Another MagicWine process is still launching or configuring this bottle; no graphics files were changed by this operation.", reason: .operationInProgress)
            }
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}
