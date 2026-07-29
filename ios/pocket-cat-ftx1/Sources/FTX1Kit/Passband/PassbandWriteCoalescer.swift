// Latest-wins write coalescing for drag gestures (docs/passband.md §4.3):
// RigController.tune(to:)'s pattern generalised to N parameters. A drag
// may submit at 60 Hz; each parameter sends at most once per interval and
// always ends on the final value. Never builds a CAT backlog.

import Foundation

@MainActor
public final class PassbandWriteCoalescer<Key: Hashable & Sendable> {
    public private(set) var sendCount = 0

    private let interval: Duration
    private let send: (Key, Int) async -> Void
    private var pending: [Key: Int] = [:]
    private var draining: Set<Key> = []

    public init(interval: Duration = .milliseconds(100),
                send: @escaping (Key, Int) async -> Void) {
        self.interval = interval
        self.send = send
    }

    /// Record the newest value; starts a drain for the key if idle.
    public func submit(_ key: Key, value: Int) {
        pending[key] = value
        guard !draining.contains(key) else { return }
        draining.insert(key)
        Task { await drain(key) }
    }

    /// Wait until everything submitted so far has been sent (tests, and
    /// gesture-end reconciliation).
    public func settle() async {
        while !draining.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func drain(_ key: Key) async {
        while let value = pending.removeValue(forKey: key) {
            sendCount += 1
            await send(key, value)
            // Pace: absorb everything that arrives inside the interval so
            // the next send carries only the latest value.
            try? await Task.sleep(for: interval)
        }
        draining.remove(key)
    }
}
