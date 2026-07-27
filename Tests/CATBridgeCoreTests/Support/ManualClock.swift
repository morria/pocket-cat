// Deterministic clock for session tests (docs/implementation.md §9.2):
// no sleep-based flakiness — tests advance time explicitly.

import CATBridgeCore
import Foundation

actor ManualClock: BridgeClock {
    private var now: Duration = .zero
    private struct Sleeper {
        let id: UUID
        let due: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var sleepers: [Sleeper] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if duration <= .zero {
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, due: now + duration,
                                        continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelSleeper(id: id) }
        }
    }

    private func cancelSleeper(id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }

    func advance(by duration: Duration) {
        now += duration
        wakeDue()
    }

    private func wakeDue() {
        while let index = sleepers.indices.min(by: {
            sleepers[$0].due < sleepers[$1].due
        }), sleepers[index].due <= now {
            let sleeper = sleepers.remove(at: index)
            sleeper.continuation.resume()
        }
    }

    var pendingSleepers: Int { sleepers.count }
}

extension ManualClock {
    /// Advance simulated time in small steps, yielding generously between
    /// steps so tasks reach their sleep points. Deterministic enough for the
    /// cooperative pool; total = how much simulated time passes.
    func pump(_ total: Duration, step: Duration = .milliseconds(50)) async {
        var remaining = total
        while remaining > .zero {
            for _ in 0..<50 { await Task.yield() }
            let d = remaining < step ? remaining : step
            advance(by: d)
            remaining -= d
        }
        for _ in 0..<50 { await Task.yield() }
    }
}
