import Darwin

/// Cross-process `flock` waits that never park a Swift executor thread: nonblocking
/// attempts separated by short, growing async sleeps until a deadline.
enum AdvisoryFileLock {
    /// Returns `false` when `timeout` passed while another descriptor held a conflicting
    /// lock. Cancellation while waiting, or right after acquiring, throws
    /// `CancellationError`; the caller releases `descriptor` either way.
    static func acquire(_ descriptor: Int32, exclusive: Bool, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var delay = Duration.milliseconds(2)
        while true {
            try Task.checkCancellation()
            if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 {
                try Task.checkCancellation()
                return true
            }
            let error = errno
            guard error == EWOULDBLOCK || error == EAGAIN || error == EINTR else {
                throw MagicWineError.setup("Cannot acquire a MagicWine lock: \(String(cString: strerror(error)))")
            }
            let now = ContinuousClock.now
            guard now < deadline else { return false }
            // Most holders are brief metadata transactions, so retry quickly at first.
            try await Task.sleep(for: min(delay, deadline - now))
            delay = min(delay * 2, .milliseconds(100))
        }
    }
}
