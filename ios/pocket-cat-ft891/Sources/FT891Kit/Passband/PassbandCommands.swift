// Passband CAT wrappers: IS / SH(+NA) / BP / CO / BC, formats per
// yaesu-cat-ft891.md "Passband commands" (researched from Hamlib,
// hardware verification pending — docs/passband.md §8 phase 5).
//
// Writers clamp and snap rather than throw (§3): a drag hands us raw
// values, and the strip must never turn one into a rejected write.

import CATBridgeCore

/// Everything the strip draws, read in one call (docs/passband.md §3).
/// Optional fields are nil when the mode doesn't support the control.
public struct PassbandState: Equatable, Sendable {
    public var mode: OperatingMode
    public var shiftHz: Int?
    public var widthIndex: Int?
    public var widthHz: Int?         // resolved through PassbandTables
    public var narrow: Bool?         // NA
    public var notchEnabled: Bool?
    public var notchHz: Int?
    public var contourEnabled: Bool?
    public var contourHz: Int?
    public var autoNotchEnabled: Bool?

    public init(mode: OperatingMode) {
        self.mode = mode
    }
}

extension TransceiverSession {
    // MARK: - Reply plumbing (mirrors FT891Commands)

    private func passbandRead(_ wire: String, prefix: String) async throws
        -> Substring {
        guard let reply = try await rawCommand(wire, expectsReply: true,
                                               isIdempotent: true),
              reply.hasPrefix(prefix), reply.hasSuffix(";") else {
            throw FT891Error.malformedReply(command: wire, reply: "")
        }
        return reply.dropFirst(prefix.count).dropLast()
    }

    // MARK: - One-call state read

    /// Populates the whole strip. Per-control reads that the radio rejects
    /// (mode-dependent) surface as nil rather than failing the batch.
    public func readPassband(mode: OperatingMode) async
        -> PassbandState {
        var state = PassbandState(mode: mode)
        state.autoNotchEnabled = try? await readAutoNotch()
        guard PassbandTables.supportsPassband(mode) else { return state }

        state.shiftHz = try? await readIFShift()
        state.narrow = try? await readNarrow()
        if let index = try? await readWidthIndex() {
            state.widthIndex = index
            state.widthHz = PassbandTables.family(for: mode)?
                .widthHz(at: index)
        }
        state.notchEnabled = try? await readNotchEnabled()
        state.notchHz = try? await readNotchHz()
        state.contourEnabled = try? await readContourEnabled()
        state.contourHz = try? await readContourHz()
        return state
    }

    // MARK: - IF shift (IS)

    public func readIFShift() async throws -> Int {
        // IS0 <on:1> <sign+4 digits> ;
        let body = try await passbandRead("IS0;", prefix: "IS0")
        guard body.count == 6, let hz = Int(body.dropFirst()) else {
            throw FT891Error.malformedReply(command: "IS0;",
                                            reply: String(body))
        }
        return hz
    }

    /// Clamped to ±1200, snapped to 20 Hz (panel granularity; CAT rounding
    /// is a bench item — snapping ourselves keeps readback stable either
    /// way).
    public func setIFShift(hz: Int) async throws {
        let step = PassbandTables.shiftStepHz
        let snapped = (hz.clamped(to: PassbandTables.shiftRangeHz) + (hz < 0
                        ? -step / 2 : step / 2)) / step * step
        let wire = String(format: "IS0%d%+05d;", snapped == 0 ? 0 : 1,
                          snapped)
        _ = try await rawCommand(wire, expectsReply: false)
    }

    // MARK: - Width (SH, NA first)

    public func readWidthIndex() async throws -> Int {
        // FT-891 replies with the extra "on" digit: SH0 <on:1> <nn> ;
        // Tolerate the 2-digit form too until hardware confirms.
        let body = try await passbandRead("SH0;", prefix: "SH0")
        guard body.count == 2 || body.count == 3,
              let index = Int(body.suffix(2)) else {
            throw FT891Error.malformedReply(command: "SH0;",
                                            reply: String(body))
        }
        return index
    }

    public func readNarrow() async throws -> Bool {
        let body = try await passbandRead("NA0;", prefix: "NA0")
        guard body.count == 1, let flag = body.first else {
            throw FT891Error.malformedReply(command: "NA0;",
                                            reply: String(body))
        }
        return flag != "0"
    }

    /// Sets width by table index for the mode. Orders `NA` before `SH`
    /// (the radio requires narrow mode to be correct first).
    public func setWidth(index: Int, mode: OperatingMode) async throws {
        guard let family = PassbandTables.family(for: mode) else {
            throw CATBridgeError.invalidArgument(
                "mode \(mode) has no width table")
        }
        let clamped = index.clamped(
            to: family.indices.lowerBound...(family.indices.upperBound - 1))
        let narrow = family.requiresNarrow(index: clamped)
        _ = try await rawCommand(narrow ? "NA01;" : "NA00;",
                                 expectsReply: false)
        _ = try await rawCommand(String(format: "SH01%02d;", clamped),
                                 expectsReply: false)
    }

    // MARK: - Manual notch (BP)

    public func readNotchEnabled() async throws -> Bool {
        let body = try await passbandRead("BP00;", prefix: "BP00")
        guard body.count == 3, let value = Int(body) else {
            throw FT891Error.malformedReply(command: "BP00;",
                                            reply: String(body))
        }
        return value != 0
    }

    public func readNotchHz() async throws -> Int {
        let body = try await passbandRead("BP01;", prefix: "BP01")
        guard body.count == 3, let tens = Int(body) else {
            throw FT891Error.malformedReply(command: "BP01;",
                                            reply: String(body))
        }
        return tens * 10
    }

    public func setNotch(enabled: Bool) async throws {
        _ = try await rawCommand(enabled ? "BP00001;" : "BP00000;",
                                 expectsReply: false)
    }

    /// Clamped to 10–3200, snapped to the wire's 10 Hz resolution.
    public func setNotch(hz: Int) async throws {
        let tens = (hz.clamped(to: PassbandTables.notchRangeHz) + 5) / 10
        _ = try await rawCommand(String(format: "BP01%03d;",
                                        tens.clamped(to: 1...320)),
                                 expectsReply: false)
    }

    // MARK: - Contour (CO)

    public func readContourEnabled() async throws -> Bool {
        let body = try await passbandRead("CO00;", prefix: "CO00")
        guard body.count == 4, let value = Int(body) else {
            throw FT891Error.malformedReply(command: "CO00;",
                                            reply: String(body))
        }
        return value != 0
    }

    public func readContourHz() async throws -> Int {
        let body = try await passbandRead("CO01;", prefix: "CO01")
        guard body.count == 4, let hz = Int(body) else {
            throw FT891Error.malformedReply(command: "CO01;",
                                            reply: String(body))
        }
        return hz
    }

    public func setContour(enabled: Bool) async throws {
        _ = try await rawCommand(enabled ? "CO000001;" : "CO000000;",
                                 expectsReply: false)
    }

    public func setContour(hz: Int) async throws {
        let clamped = hz.clamped(to: PassbandTables.contourRangeHz)
        _ = try await rawCommand(String(format: "CO01%04d;", clamped),
                                 expectsReply: false)
    }

    // MARK: - Auto notch (BC)

    public func readAutoNotch() async throws -> Bool {
        let body = try await passbandRead("BC0;", prefix: "BC0")
        guard body.count == 1, let flag = body.first else {
            throw FT891Error.malformedReply(command: "BC0;",
                                            reply: String(body))
        }
        return flag != "0"
    }

    public func setAutoNotch(enabled: Bool) async throws {
        _ = try await rawCommand(enabled ? "BC01;" : "BC00;",
                                 expectsReply: false)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
