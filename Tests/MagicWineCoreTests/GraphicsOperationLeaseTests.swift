import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct GraphicsOperationLeaseTests {
    private func paths() throws -> ApplicationPaths {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        return paths
    }

    @Test func sharedLaunchesExcludeBackendMutationUntilEveryLeaseCloses() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        let first = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: false)
        let second = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: false)
        defer { first.release(); second.release() }
        first.release()
        do {
            let unexpected = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch,
                                                                       exclusive: true, timeout: .milliseconds(20))
            unexpected.release()
            Issue.record("Backend mutation acquired a gate still held by a launch.")
        } catch {
            #expect(error is MagicWineError)
        }
        second.release()
        let mutation = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: true)
        defer { mutation.release() }
        do {
            let unexpected = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch,
                                                                       exclusive: false, timeout: .milliseconds(20))
            unexpected.release()
            Issue.record("A launch crossed an active backend mutation.")
        } catch {
            #expect(error is MagicWineError)
        }
    }

    @Test func cancelledWaitDoesNotLeakGateOrBlockAnotherBottle() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        let mutation = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: true)
        defer { mutation.release() }
        let waiting = Task { try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: false) }
        let other = try await GraphicsOperationLease.acquire(paths: paths, bottleID: UUID(), kind: .launch, exclusive: true)
        other.release()
        waiting.cancel()
        do {
            let unexpected = try await waiting.value
            unexpected.release()
            Issue.record("A cancelled launch acquired the held graphics gate.")
        } catch { #expect(error is CancellationError) }
        mutation.release()
        let next = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: true)
        defer { next.release() }
        do {
            let unexpected = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch,
                                                                       exclusive: false, timeout: .milliseconds(20))
            unexpected.release()
            Issue.record("Cancellation released a later owner's exclusive gate.")
        } catch { #expect(error is MagicWineError) }
    }

    @Test func lifetimeLeaseBlocksReplacementAfterLaunchHandoff() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        let launch = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: false)
        let running = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .lifetime, exclusive: false)
        defer { launch.release(); running.release() }
        launch.release()
        let setup = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: true)
        defer { setup.release() }
        do {
            let unexpected = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .lifetime,
                                                                       exclusive: true, timeout: .milliseconds(20))
            unexpected.release()
            Issue.record("DLL replacement crossed a still-running Wine process.")
        } catch { #expect(error is MagicWineError) }
        running.release()
        let stopped = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .lifetime, exclusive: true)
        defer { stopped.release() }
        do {
            let unexpected = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .lifetime,
                                                                       exclusive: false, timeout: .milliseconds(20))
            unexpected.release()
            Issue.record("An old process reacquired a lifetime gate during replacement.")
        } catch { #expect(error is MagicWineError) }
    }

    @Test func lockSymlinkAndHardLinkCannotAdoptAnExternalFile() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let locks = paths.bottlesDirectory.appendingPathComponent(".graphics-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: false)
        let original = Data("unrelated data".utf8)
        let external = paths.root.appendingPathComponent("keep.txt")
        try original.write(to: external)
        for hardLink in [false, true] {
            let id = UUID()
            let file = locks.appendingPathComponent("\(id.uuidString)-launch.lock")
            if hardLink { try FileManager.default.linkItem(at: external, to: file) }
            else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external) }
            do {
                let unexpected = try await GraphicsOperationLease.acquire(paths: paths, bottleID: id, kind: .launch, exclusive: true)
                unexpected.release()
                Issue.record("An external file was adopted as a graphics lock.")
            } catch { #expect(error is MagicWineError) }
            #expect(try Data(contentsOf: external) == original)
        }
    }
}
