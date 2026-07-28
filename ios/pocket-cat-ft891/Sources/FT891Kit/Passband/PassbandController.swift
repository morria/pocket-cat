// Observable store for the passband strip (docs/passband.md §8 phase 3):
// optimistic state, coalesced writes, drag-aware reconciliation. Owned by
// the Operate screen; all radio I/O goes through the session actor.

import CATBridgeCore
import Foundation
import Observation

@MainActor
@Observable
public final class PassbandController {
    public enum Parameter: Hashable, Sendable {
        case shift
        case width
        case notchHz
        case contourHz
    }

    public private(set) var state: PassbandState?
    /// True between gesture start and end: read-backs are ignored so a
    /// stale read never fights the drag (§4.3).
    public private(set) var isDragging = false

    private var session: TransceiverSession?
    private var coalescer: PassbandWriteCoalescer<Parameter>?
    private var refreshTask: Task<Void, Never>?

    public init() {}

    // MARK: - Wiring

    /// Attach to the live session and load state for the current mode.
    /// Safe to call repeatedly (reconnects, mode changes).
    public func refresh(session: TransceiverSession?,
                        mode: OperatingMode?) {
        self.session = session
        if coalescer == nil, let session {
            coalescer = PassbandWriteCoalescer(interval: .milliseconds(100))
            { [weak self] parameter, value in
                await self?.write(parameter, value: value, via: session)
            }
        }
        guard let session, let mode else {
            state = nil
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let fresh = await session.readPassband(mode: mode)
            guard let self, !Task.isCancelled else { return }
            if !self.isDragging {
                self.state = fresh
            }
        }
    }

    public var supportsPassband: Bool {
        state.map { PassbandTables.supportsPassband($0.mode) } ?? false
    }

    public var widthFamily: PassbandTables.WidthFamily? {
        state.flatMap { PassbandTables.family(for: $0.mode) }
    }

    // MARK: - Drag lifecycle

    public func beginDrag() {
        isDragging = true
    }

    /// Gesture ended: flush the coalescer, then reconcile with a read.
    public func endDrag() {
        isDragging = false
        Task { [weak self] in
            await self?.coalescer?.settle()
            guard let self, let session = self.session,
                  let mode = self.state?.mode else { return }
            self.refresh(session: session, mode: mode)
        }
    }

    // MARK: - Optimistic setters (draw immediately, write coalesced)

    public func setShift(hz: Int) {
        guard supportsPassband else { return }
        let snapped = snap(hz.clamped(to: PassbandTables.shiftRangeHz),
                           step: PassbandTables.shiftStepHz)
        guard state?.shiftHz != snapped else { return }
        state?.shiftHz = snapped
        coalescer?.submit(.shift, value: snapped)
    }

    public func setWidth(index: Int) {
        guard let family = widthFamily else { return }
        let clamped = index.clamped(
            to: family.indices.lowerBound...(family.indices.upperBound - 1))
        guard state?.widthIndex != clamped else { return }
        state?.widthIndex = clamped
        state?.widthHz = family.widthHz(at: clamped)
        state?.narrow = family.requiresNarrow(index: clamped)
        coalescer?.submit(.width, value: clamped)
    }

    public func setNotch(hz: Int) {
        guard supportsPassband else { return }
        let snapped = snap(hz.clamped(to: PassbandTables.notchRangeHz),
                           step: PassbandTables.notchStepHz)
        guard state?.notchHz != snapped else { return }
        state?.notchHz = snapped
        coalescer?.submit(.notchHz, value: snapped)
    }

    /// Tap-to-notch: place and enable in one gesture (§4.2).
    public func placeNotch(hz: Int) {
        guard supportsPassband else { return }
        setNotch(hz: hz)
        setNotchEnabled(true)
    }

    public func setNotchEnabled(_ enabled: Bool) {
        guard supportsPassband, state?.notchEnabled != enabled else {
            return
        }
        state?.notchEnabled = enabled
        Task { [session] in
            try? await session?.setNotch(enabled: enabled)
        }
    }

    public func setContourEnabled(_ enabled: Bool) {
        guard supportsPassband, state?.contourEnabled != enabled else {
            return
        }
        state?.contourEnabled = enabled
        Task { [session] in
            try? await session?.setContour(enabled: enabled)
        }
    }

    public func setContour(hz: Int) {
        guard supportsPassband else { return }
        let clamped = hz.clamped(to: PassbandTables.contourRangeHz)
        guard state?.contourHz != clamped else { return }
        state?.contourHz = clamped
        coalescer?.submit(.contourHz, value: clamped)
    }

    public func setAutoNotch(_ enabled: Bool) {
        guard state?.autoNotchEnabled != enabled else { return }
        state?.autoNotchEnabled = enabled
        Task { [session] in
            try? await session?.setAutoNotch(enabled: enabled)
        }
    }

    // MARK: - Plumbing

    private func write(_ parameter: Parameter, value: Int,
                       via session: TransceiverSession) async {
        switch parameter {
        case .shift:
            try? await session.setIFShift(hz: value)
        case .width:
            if let mode = state?.mode {
                try? await session.setWidth(index: value, mode: mode)
            }
        case .notchHz:
            try? await session.setNotch(hz: value)
        case .contourHz:
            try? await session.setContour(hz: value)
        }
    }

    private func snap(_ value: Int, step: Int) -> Int {
        (value + (value < 0 ? -step / 2 : step / 2)) / step * step
    }
}
