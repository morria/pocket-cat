// The WSPR beacon: schedules transmissions on even UTC minutes and clocks
// 162 tones out through `TA`. No audio path — the phone times the symbols
// and the radio makes them.
//
// Timing tolerance is the reason this is possible over BLE at all: a WSPR
// symbol is 682.7 ms, so tens of milliseconds of link jitter are noise.
// Each symbol is pinned to an absolute deadline rather than a sleep, so
// jitter cannot accumulate across the 110.6-second frame.
//
// Safety: transmissions are wrapped in `transmit()`/`receive()` even though
// `TA` does the keying, because the library only recognises the dialect's
// own PTT wire — that wrapping is what arms the bridge's dead-man failsafe
// and starts the PTT watchdog (default 180 s, comfortably longer than one
// frame). Stopping always sends `TA0;` and `RX;`.

import CATBridgeCore
import Foundation
import Observation

/// Standard WSPR dial frequencies (USB dial; tones land 1400–1600 Hz above).
public struct WSPRBand: Identifiable, Sendable, Equatable {
    public let name: String
    public let dialHz: UInt64
    public var id: String { name }

    public static let all: [WSPRBand] = [
        WSPRBand(name: "160 m", dialHz: 1_836_600),
        WSPRBand(name: "80 m", dialHz: 3_568_600),
        WSPRBand(name: "60 m", dialHz: 5_287_200),
        WSPRBand(name: "40 m", dialHz: 7_038_600),
        WSPRBand(name: "30 m", dialHz: 10_138_700),
        WSPRBand(name: "20 m", dialHz: 14_095_600),
        WSPRBand(name: "17 m", dialHz: 18_104_600),
        WSPRBand(name: "15 m", dialHz: 21_094_600),
        WSPRBand(name: "12 m", dialHz: 24_924_600),
        WSPRBand(name: "10 m", dialHz: 28_124_600),
        WSPRBand(name: "6 m", dialHz: 50_293_000),
    ]
}

@MainActor
@Observable
public final class WSPRBeacon {
    public enum Phase: Equatable, Sendable {
        case idle
        case waiting(until: Date)
        case transmitting(symbol: Int)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastTransmission: Date?
    public private(set) var transmissionCount = 0
    public var isRunning: Bool { runTask != nil }

    public var session: TransceiverSession?
    /// Audio tone the first WSPR symbol sits on, above the dial frequency.
    /// 1500 Hz is the middle of the 1400–1600 Hz WSPR window.
    public var baseToneHz: Double = 1_500
    /// One frame every N two-minute slots. 1 transmits every slot, which is
    /// antisocial on a shared band; 3–5 is the usual courtesy.
    public var slotInterval = 3
    /// Symbol period. Overridable so tests need not run for two minutes.
    public var symbolDuration: Duration =
        .microseconds(Int(WSPREncoder.symbolDuration * 1_000_000))
    /// Set the dial to the band's standard frequency before transmitting.
    public var setsDialFrequency = true

    private var runTask: Task<Void, Never>?

    public init(session: TransceiverSession? = nil) {
        self.session = session
    }

    // MARK: - Run loop

    /// Starts beaconing. Returns immediately; progress shows up in `phase`.
    public func start(callsign: String, grid: String, powerDBm: Int,
                      band: WSPRBand) {
        guard runTask == nil else { return }
        let symbols: [UInt8]
        do {
            symbols = try WSPREncoder.symbols(callsign: callsign, grid: grid,
                                              powerDBm: powerDBm)
        } catch {
            phase = .failed(Self.describe(error))
            return
        }
        runTask = Task { [weak self] in
            await self?.run(symbols: symbols, band: band)
        }
    }

    /// Stops after unkeying. Safe to call at any point in a frame.
    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await forceUnkey()
        phase = .idle
    }

    private func run(symbols: [UInt8], band: WSPRBand) async {
        defer { runTask = nil }
        var slotsUntilTransmit = 0
        while !Task.isCancelled {
            let start = Self.nextSlotStart(after: Date())
            phase = .waiting(until: start)
            do {
                try await Task.sleep(for: .seconds(
                    max(0, start.timeIntervalSinceNow)))
            } catch { return } // cancelled while waiting

            if slotsUntilTransmit > 0 {
                slotsUntilTransmit -= 1
                continue
            }
            slotsUntilTransmit = max(0, slotInterval - 1)

            await transmitOneFrame(symbols: symbols, band: band, start: start)
            if case .failed = phase { return }
        }
    }

    /// One 162-symbol frame. Every symbol is pinned to `start + i × period`.
    func transmitOneFrame(symbols: [UInt8], band: WSPRBand,
                          start: Date) async {
        guard let session else {
            phase = .failed("Not connected")
            return
        }
        do {
            if setsDialFrequency {
                try await session.setFrequency(Frequency(hz: band.dialHz))
            }
            try await session.setMode(QMXMode.digi.operatingMode)
            // Arms the failsafe and the PTT watchdog; TA alone would not,
            // because the library only knows the dialect's PTT wire.
            try await session.transmit()

            let period = TimeInterval(symbolDuration.components.seconds)
                + TimeInterval(symbolDuration.components.attoseconds) / 1e18
            for (index, symbol) in symbols.enumerated() {
                if Task.isCancelled { break }
                phase = .transmitting(symbol: index)
                let tone = WSPREncoder.toneHz(forSymbol: symbol,
                                              baseHz: baseToneHz)
                try await session.setDigiTone(hz: tone)
                let deadline = start.addingTimeInterval(Double(index + 1)
                                                        * period)
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    try await Task.sleep(for: .seconds(remaining))
                }
            }
            try await session.endDigiTone()
            try await session.receive()
            transmissionCount += 1
            lastTransmission = Date()
        } catch is CancellationError {
            await forceUnkey()
        } catch {
            await forceUnkey()
            phase = .failed(Self.describe(error))
        }
    }

    /// Unkey on every exit path, including cancellation. Deliberately
    /// ignores errors and uses a detached shielded task so a cancelled
    /// parent cannot stop the radio from being told to stop transmitting.
    private func forceUnkey() async {
        guard let session else { return }
        await Task { @MainActor in
            try? await session.endDigiTone()
            try? await session.receive()
        }.value
    }

    // MARK: - Slot arithmetic

    /// WSPR frames start one second into an even UTC minute.
    public nonisolated static func nextSlotStart(
        after now: Date, calendar: Calendar = .utcCalendar) -> Date {
        let components = calendar.dateComponents([.minute, .second], from: now)
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        // Seconds from the top of this minute to the next valid start.
        var offset: Int
        if minute % 2 == 0 && second < 1 {
            offset = 1 - second
        } else {
            let minutesToNextEven = minute % 2 == 0 ? 2 : 1
            offset = minutesToNextEven * 60 - second + 1
        }
        if offset <= 0 { offset += 120 }
        return now.addingTimeInterval(TimeInterval(offset))
    }

    private static func describe(_ error: Error) -> String {
        if let wspr = error as? WSPRError {
            switch wspr {
            case .invalidCallsign(let call): return "Bad callsign “\(call)”"
            case .invalidGrid(let grid): return "Bad grid “\(grid)”"
            case .invalidPower(let dbm): return "Bad power \(dbm) dBm"
            }
        }
        switch error as? CATBridgeError {
        case .connectionLost, .bondInvalidated: return "Link lost"
        case .usbRadioDisconnected: return "Radio unplugged"
        case .pttInterlock(let why): return why
        default: return "Transmit failed"
        }
    }
}

extension Calendar {
    /// WSPR slots are defined against UTC, never the phone's time zone.
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
}
