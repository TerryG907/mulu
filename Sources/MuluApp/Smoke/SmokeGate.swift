import os

/// Makes sure exactly one smoke report is written: the normal run or the watchdog, never both.
enum SmokeGate {
    private static let finished = OSAllocatedUnfairLock(initialState: false)

    /// True for the first caller only.
    static func claim() -> Bool {
        finished.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
