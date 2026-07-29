// The small FTX-1 command surface CATBridgeKit leaves untyped, built on
// its raw-CAT escape hatch. All calls serialize through the session actor's
// single-in-flight queue, so these interleave safely with the poller and
// the typed API. Formats per docs/ftx1-cat-commands.md.

import CATBridgeCore

extension TransceiverSession {
    // MARK: - Reply plumbing

    /// Read-style raw command: idempotent (safe to retry once) and expects
    /// a reply. Throws on a missing reply rather than returning nil.
    private func rawRead(_ wire: String) async throws -> String {
        guard let reply = try await rawCommand(wire, expectsReply: true,
                                               isIdempotent: true) else {
            throw FTX1Error.malformedReply(command: wire, reply: "")
        }
        return reply
    }

    /// Extract the payload between a reply's prefix and trailing `;`.
    private func payload(of reply: String, after prefix: String,
                         command: String) throws -> Substring {
        guard reply.hasPrefix(prefix), reply.hasSuffix(";") else {
            throw FTX1Error.malformedReply(command: command, reply: reply)
        }
        return reply.dropFirst(prefix.count).dropLast()
    }

    // MARK: - Antenna tuner (AC)

    public func readTunerState() async throws -> TunerState {
        let reply = try await rawRead("AC;")
        let body = try payload(of: reply, after: "AC00", command: "AC;")
        guard body.count == 1, let digit = body.first?.wholeNumberValue,
              let state = TunerState(rawValue: digit) else {
            throw FTX1Error.malformedReply(command: "AC;", reply: reply)
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
    public func readMeter(_ meter: FTX1Meter) async throws -> Int {
        let wire = "RM\(meter.rawValue);"
        let reply = try await rawRead(wire)
        let body = try payload(of: reply, after: "RM\(meter.rawValue)",
                               command: wire)
        guard body.count == 3, let value = Int(body) else {
            throw FTX1Error.malformedReply(command: wire, reply: reply)
        }
        return value
    }

    // MARK: - VFO-B / band / VFO ops

    public func readVFOB() async throws -> Frequency {
        let reply = try await rawRead("FB;")
        let body = try payload(of: reply, after: "FB", command: "FB;")
        guard body.count == 9, let hz = UInt64(body) else {
            throw FTX1Error.malformedReply(command: "FB;", reply: reply)
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

    public func selectBand(_ band: FTX1Band) async throws {
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
            throw FTX1Error.malformedReply(command: "ST;", reply: reply)
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
            throw FTX1Error.malformedReply(command: "CF0;", reply: reply)
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
            throw FTX1Error.malformedReply(command: "RS;", reply: reply)
        }
        return flag != "0"
    }

    /// Squelch-open busy flag (`BY`).
    public func readBusy() async throws -> Bool {
        let reply = try await rawRead("BY;")
        let body = try payload(of: reply, after: "BY", command: "BY;")
        guard body.count == 2, let flag = body.first else {
            throw FTX1Error.malformedReply(command: "BY;", reply: reply)
        }
        return flag != "0"
    }

    // MARK: - Menu items (raw, by EX number)
    //
    // No typed catalog here. The FT-891 app ships one for its 159 items,
    // but the FTX-1's numbering differs and this repo has no verified
    // catalog for it (esp32s3/docs/references/yaesu-cat-ftx1.md). Raw
    // access by number is honest; a borrowed catalog would confidently
    // write the wrong setting.

    /// Read a menu item's raw digits, e.g. `"0506"` -> `"3"`.
    public func readMenuDigits(_ exNumber: String) async throws -> String {
        let wire = "EX\(exNumber);"
        let reply = try await rawRead(wire)
        return String(try payload(of: reply, after: "EX\(exNumber)",
                                  command: wire))
    }

    /// Write a menu item's raw digits. Out-of-range values are rejected by
    /// the radio with `?;`, surfacing as `radioRejected`.
    public func writeMenuDigits(_ exNumber: String,
                                digits: String) async throws {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            throw CATBridgeError.invalidArgument("menu value must be digits")
        }
        _ = try await rawCommand("EX\(exNumber)\(digits);",
                                 expectsReply: false)
    }
}
