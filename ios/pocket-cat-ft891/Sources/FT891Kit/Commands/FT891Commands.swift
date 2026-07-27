// The small FT-891 command surface CATBridgeKit leaves untyped, built on
// its raw-CAT escape hatch. All calls serialize through the session actor's
// single-in-flight queue, so these interleave safely with the poller and
// the typed API. Formats per docs/ft891-cat-commands.md.

import CATBridgeCore

extension TransceiverSession {
    // MARK: - Reply plumbing

    /// Read-style raw command: idempotent (safe to retry once) and expects
    /// a reply. Throws on a missing reply rather than returning nil.
    private func rawRead(_ wire: String) async throws -> String {
        guard let reply = try await rawCommand(wire, expectsReply: true,
                                               isIdempotent: true) else {
            throw FT891Error.malformedReply(command: wire, reply: "")
        }
        return reply
    }

    /// Extract the payload between a reply's prefix and trailing `;`.
    private func payload(of reply: String, after prefix: String,
                         command: String) throws -> Substring {
        guard reply.hasPrefix(prefix), reply.hasSuffix(";") else {
            throw FT891Error.malformedReply(command: command, reply: reply)
        }
        return reply.dropFirst(prefix.count).dropLast()
    }

    // MARK: - Antenna tuner (AC)

    public func readTunerState() async throws -> TunerState {
        let reply = try await rawRead("AC;")
        let body = try payload(of: reply, after: "AC00", command: "AC;")
        guard body.count == 1, let digit = body.first?.wholeNumberValue,
              let state = TunerState(rawValue: digit) else {
            throw FT891Error.malformedReply(command: "AC;", reply: reply)
        }
        return state
    }

    public func setTuner(enabled: Bool) async throws {
        _ = try await rawCommand(enabled ? "AC001;" : "AC000;",
                                 expectsReply: false)
    }

    /// Start a tune cycle. **The radio transmits a carrier while tuning**
    /// (and requires menu 16-15 TUNER SELECT to be configured) — the UI
    /// must confirm before calling this.
    public func startTuneCycle() async throws {
        _ = try await rawCommand("AC002;", expectsReply: false)
    }

    // MARK: - Meters (RM)

    /// Raw 0–255 meter reading. Scaling to real units is unpublished;
    /// calibrate empirically (see docs).
    public func readMeter(_ meter: FT891Meter) async throws -> Int {
        let wire = "RM\(meter.rawValue);"
        let reply = try await rawRead(wire)
        let body = try payload(of: reply, after: "RM\(meter.rawValue)",
                               command: wire)
        guard body.count == 3, let value = Int(body) else {
            throw FT891Error.malformedReply(command: wire, reply: reply)
        }
        return value
    }

    // MARK: - VFO-B / band / VFO ops

    public func readVFOB() async throws -> Frequency {
        let reply = try await rawRead("FB;")
        let body = try payload(of: reply, after: "FB", command: "FB;")
        guard body.count == 9, let hz = UInt64(body) else {
            throw FT891Error.malformedReply(command: "FB;", reply: reply)
        }
        return Frequency(hz: hz)
    }

    public func setVFOB(_ frequency: Frequency) async throws {
        guard let digits = frequency.catDigits(width: 9) else {
            throw CATBridgeError.invalidArgument(
                "frequency \(frequency) exceeds 9-digit field")
        }
        _ = try await rawCommand("FB\(digits);", expectsReply: false)
    }

    public func selectBand(_ band: FT891Band) async throws {
        _ = try await rawCommand("BS\(band.rawValue);", expectsReply: false)
    }

    public func copyVFOAToB() async throws {
        _ = try await rawCommand("AB;", expectsReply: false)
    }

    public func copyVFOBToA() async throws {
        _ = try await rawCommand("BA;", expectsReply: false)
    }

    public func swapVFOs() async throws {
        _ = try await rawCommand("SV;", expectsReply: false)
    }

    // MARK: - Split (ST)

    public func readSplit() async throws -> SplitState {
        let reply = try await rawRead("ST;")
        let body = try payload(of: reply, after: "ST", command: "ST;")
        guard body.count == 1, let digit = body.first?.wholeNumberValue,
              let state = SplitState(rawValue: digit) else {
            throw FT891Error.malformedReply(command: "ST;", reply: reply)
        }
        return state
    }

    public func setSplit(_ state: SplitState) async throws {
        _ = try await rawCommand("ST\(state.rawValue);", expectsReply: false)
    }

    // MARK: - Clarifier (CF / RD / RU / RC)

    public func readClarifierEnabled() async throws -> Bool {
        let reply = try await rawRead("CF0;")
        let body = try payload(of: reply, after: "CF0", command: "CF0;")
        guard body.count == 2, let flag = body.first else {
            throw FT891Error.malformedReply(command: "CF0;", reply: reply)
        }
        return flag != "0"
    }

    public func setClarifier(enabled: Bool) async throws {
        _ = try await rawCommand(enabled ? "CF010;" : "CF000;",
                                 expectsReply: false)
    }

    /// Relative clarifier nudge; sign of `hz` picks `RU`/`RD`. The absolute
    /// offset is only readable from `IF` (there is no absolute set).
    public func nudgeClarifier(by hz: Int) async throws {
        guard hz != 0 else { return }
        let magnitude = min(abs(hz), 9999)
        let wire = String(format: "%@%04d;", hz > 0 ? "RU" : "RD", magnitude)
        _ = try await rawCommand(wire, expectsReply: false)
    }

    public func clearClarifier() async throws {
        _ = try await rawCommand("RC;", expectsReply: false)
    }

    // MARK: - Status

    /// True when the operator is inside the front-panel menu (`RS1;`) —
    /// menu writes should pause (EX behavior there is undocumented).
    public func readFrontPanelMenuActive() async throws -> Bool {
        let reply = try await rawRead("RS;")
        let body = try payload(of: reply, after: "RS", command: "RS;")
        guard body.count == 1, let flag = body.first else {
            throw FT891Error.malformedReply(command: "RS;", reply: reply)
        }
        return flag != "0"
    }

    /// Squelch-open busy flag (`BY`).
    public func readBusy() async throws -> Bool {
        let reply = try await rawRead("BY;")
        let body = try payload(of: reply, after: "BY", command: "BY;")
        guard body.count == 2, let flag = body.first else {
            throw FT891Error.malformedReply(command: "BY;", reply: reply)
        }
        return flag != "0"
    }

    // MARK: - Menu items (catalog-typed, signed-safe)

    /// Read a catalog item's engineering value. Signed items route around
    /// CATBridgeKit's digits-only menu API via raw CAT.
    public func readMenuValue(_ item: MenuItem) async throws -> Int {
        if item.isSigned {
            let wire = "EX\(item.exNumber);"
            let reply = try await rawRead(wire)
            let body = try payload(of: reply, after: "EX\(item.exNumber)",
                                   command: wire)
            return try item.decode(String(body))
        }
        return try item.decode(try await readMenuItem(item.exNumber))
    }

    /// Write a catalog item's engineering value (encoded per the catalog).
    public func writeMenuValue(_ item: MenuItem, value: Int) async throws {
        guard item.isWritable && !item.isAction else {
            throw CATBridgeError.invalidArgument(
                "menu \(item.id) is not writable")
        }
        let digits = try item.encode(value)
        if item.isSigned {
            _ = try await rawCommand("EX\(item.exNumber)\(digits);",
                                     expectsReply: false)
        } else {
            try await setMenuItem(item.exNumber, value: digits)
        }
    }
}
