import Darwin
import Foundation
import Testing
@testable import MagicWineCore

/// The bottle lock (`GraphicsPrefix.withLock`) waits without blocking and gives up.
struct BottleLockTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore

        init() throws {
            paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            store = BottleStore(paths: paths)
        }

        func bottle(_ name: String) async throws -> Bottle {
            try await store.create(name: name, runtime: RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                                                                          version: "wine-11.0"))
        }

        func directory(_ bottle: Bottle) -> URL {
            paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
        }

        func lockFile(_ bottle: Bottle) -> URL {
            paths.bottlesDirectory.appendingPathComponent(".graphics-locks/\(bottle.id.uuidString).lock")
        }

        /// Another descriptor of this process holding the lock; flock conflicts across descriptors.
        func holdLock(_ bottle: Bottle) throws -> Int32 {
            try FileManager.default.createDirectory(at: lockFile(bottle).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let descriptor = open(lockFile(bottle).path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            #expect(descriptor >= 0)
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            return descriptor
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    private static func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func lockHeldByAnotherProcessIsAwaitedWithoutStallingOtherBottles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let busy = try await fixture.bottle("Busy")
        let other = try await fixture.bottle("Other")
        let locked = fixture.paths.root.appendingPathComponent("locked")
        let release = fixture.paths.root.appendingPathComponent("release")
        let released = fixture.paths.root.appendingPathComponent("released")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // Holds the lock until asked to release it (at most 30 seconds).
        holder.arguments = ["-e", """
            use Fcntl qw(:flock);
            open(my $lock, '>>', $ARGV[0]) or die "open: $!";
            flock($lock, LOCK_EX) or die "flock: $!";
            open(my $marker, '>', $ARGV[1]) or die; close($marker);
            for (1..3000) { last if -e $ARGV[2]; select(undef, undef, undef, 0.01); }
            open($marker, '>', $ARGV[3]) or die; close($marker);
            flock($lock, LOCK_UN);
            sleep 5;
            """, fixture.lockFile(busy).path, locked.path, release.path, released.path]
        try FileManager.default.createDirectory(at: fixture.lockFile(busy).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try holder.run()
        defer { holder.terminate() }
        try await Self.waitForFile(locked)

        let waiting = Task { try await fixture.store.current(busy) }
        try await Task.sleep(for: .milliseconds(100))
        // The store actor stays available for other bottles while one bottle's lock is awaited.
        _ = try await fixture.store.current(other)
        #expect(!FileManager.default.fileExists(atPath: released.path))
        try Data().write(to: release)
        let loaded = try await waiting.value
        #expect(loaded.id == busy.id)
        #expect(FileManager.default.fileExists(atPath: released.path))
    }

    @Test func cancellingAWaitNeverRunsTheBodyAndLeavesTheLockUsable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bottle = try await fixture.bottle("Bottle")
        let held = try fixture.holdLock(bottle)
        let ran = ManagedAtomicFlag()
        let waiting = Task {
            try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory(bottle)) { ran.set() }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!ran.value)
        flock(held, LOCK_UN)
        close(held)
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory(bottle), timeout: .seconds(5)) { ran.set() }
        #expect(ran.value)
        // The waiter's descriptor was released: the lock can be taken without waiting.
        let again = try fixture.holdLock(bottle)
        close(again)
    }

    @Test func lockStillHeldAfterTheTimeoutIsBusy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bottle = try await fixture.bottle("Bottle")
        let held = try fixture.holdLock(bottle)
        defer { close(held) }
        do {
            _ = try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory(bottle), timeout: .milliseconds(50)) {
                Issue.record("The body ran while another descriptor held the bottle lock.")
            }
            Issue.record("The bottle lock was acquired while held elsewhere.")
        } catch MagicWineError.busy(_, reason: .operationInProgress, _) {
        }
        flock(held, LOCK_UN)
        let saved = try await fixture.store.setCompatibility(.init(advertiseAVX: true), in: bottle)
        #expect(saved.compatibility.advertiseAVX)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
