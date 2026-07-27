// Swift ports of the radio personalities in esp32s3/test/tools/radio_sim.py
// (revision: the version committed alongside this file — the on-device rig
// runs the Python originals, so behavioral drift surfaces there, §9.2).
//
// The IF; layouts here are the ones the dialects parse; both carry the
// bring-up caveat about real-rig field offsets.

import Foundation

// @unchecked Sendable: personalities are confined to the ScriptedTransport
// actor during operation; tests only touch them at quiescent points.
class RadioPersonality: @unchecked Sendable {
    var command = [UInt8]()
    var transmitting = false
    /// The radio's CAT RATE menu setting for UART-bridge radios; nil for
    /// native-USB radios (QMX) where baud is cosmetic. When the bridge's
    /// applied baud mismatches, the radio "hears" garbage → modeled as
    /// silence by the transport.
    var menuBaud: UInt32? = nil
    // Fault injection
    var muted = false
    var stallAfter: Int? = nil
    var garbageNext = false

    var idReply: String { "?;" }

    func respond(to command: String) -> String { "?;" }

    /// Operator turns the physical dial. Returns the unsolicited frame the
    /// radio would push (Auto-Information on), or nil (AI off / no AI).
    func dialTurn(to vfoA: String) -> String? { nil }

    /// Feed bytes; returns the radio's response bytes.
    func feed(_ data: Data) -> Data {
        var out = Data()
        for byte in data {
            command.append(byte)
            if byte == UInt8(ascii: ";") {
                let cmd = String(decoding: command, as: UTF8.self)
                command.removeAll(keepingCapacity: true)
                if muted { continue }
                var reply = respond(to: cmd)
                if garbageNext && !reply.isEmpty {
                    out.append(contentsOf: (0xF0...0xFF).map { UInt8($0) })
                    garbageNext = false
                }
                if let stall = stallAfter {
                    reply = String(reply.prefix(stall))
                    stallAfter = nil
                }
                out.append(contentsOf: reply.utf8)
            } else if command.count > 128 {
                command.removeAll(keepingCapacity: true)
            }
        }
        return out
    }
}

final class Ft891Personality: RadioPersonality {
    var vfoA = "014074000" // 9 digits, Hz
    var mode: Character = "3" // CW
    var aiEnabled = false
    var power = 100
    /// Level/switch settings by wire prefix (value, digit width).
    var settings: [String: (value: Int, digits: Int)] = [
        "AG0": (128, 3), "RG0": (255, 3), "SQ0": (0, 3), "MG": (50, 3),
        "KS": (20, 3), "BI": (0, 1), "NB0": (0, 1), "NR0": (0, 1),
        "PA0": (0, 1), "RA0": (0, 1), "NA0": (0, 1), "SH0": (12, 2),
    ]
    /// EX menu store; unknown numbers answer `?;` like a real rig.
    var menu: [String: String] = ["0301": "5", "0502": "10"]

    override init() {
        super.init()
        menuBaud = 38400
    }

    override var idReply: String { "ID0650;" }

    override func dialTurn(to newVFOA: String) -> String? {
        vfoA = newVFOA
        return aiEnabled ? "FA\(vfoA);" : nil
    }

    override func respond(to cmd: String) -> String {
        switch cmd {
        case "ID;": return idReply
        case "FA;": return "FA\(vfoA);"
        case "MD0;": return "MD0\(mode);"
        case "IF;":
            // IF | mem(3) | freq(9) | clar(5) | rx(1) | tx(1) | mode(1) | …
            return "IF001\(vfoA)+000000\(mode)000000;"
        case "TX;": return transmitting ? "TX1;" : "TX0;"
        case "TX1;": transmitting = true; return ""
        case "TX0;": transmitting = false; return ""
        case "SM0;": return "SM0100;"
        case "AI;": return aiEnabled ? "AI1;" : "AI0;"
        case "AI1;": aiEnabled = true; return ""
        case "AI0;": aiEnabled = false; return ""
        case "PC;": return String(format: "PC%03d;", power)
        default:
            if cmd.hasPrefix("FA"), cmd.count == 12 {
                let digits = String(Array(cmd)[2...10])
                if digits.allSatisfy(\.isNumber) {
                    vfoA = digits
                    return ""
                }
            }
            if cmd.hasPrefix("MD0"), cmd.count == 5 {
                mode = Array(cmd)[3]
                return ""
            }
            if cmd.hasPrefix("KY") { return "" }
            if cmd.hasPrefix("PC"), cmd.count == 6,
               let watts = Int(String(Array(cmd)[2...4])) {
                power = watts
                return ""
            }
            if cmd.hasPrefix("EX"), cmd.count >= 7 {
                let body = String(cmd.dropFirst(2).dropLast())
                let number = String(body.prefix(4))
                guard number.count == 4, number.allSatisfy(\.isNumber) else {
                    return "?;"
                }
                let value = String(body.dropFirst(4))
                if value.isEmpty { // read
                    guard let v = menu[number] else { return "?;" }
                    return "EX\(number)\(v);"
                }
                guard value.allSatisfy(\.isNumber) else { return "?;" }
                menu[number] = value
                return ""
            }
            // Settings: longest prefix first so "NA0" never matches "NA".
            for (prefix, entry) in settings.sorted(
                by: { $0.key.count > $1.key.count }) {
                if cmd == "\(prefix);" {
                    return String(
                        format: "%@%0\(entry.digits)d;", prefix, entry.value)
                }
                if cmd.hasPrefix(prefix), cmd.hasSuffix(";"),
                   let value = Int(cmd.dropFirst(prefix.count).dropLast()) {
                    settings[prefix] = (value, entry.digits)
                    return ""
                }
            }
            return "?;"
        }
    }
}

final class Ftx1Personality: RadioPersonality {
    var vfoA = "014074000"

    override init() {
        super.init()
        menuBaud = 38400
    }

    override var idReply: String { "ID0800;" }

    override func respond(to cmd: String) -> String {
        switch cmd {
        case "ID;": return idReply
        case "FA;": return "FA\(vfoA);"
        case "IF;": return "IF001\(vfoA)+0000003000000;"
        case "TX;": return transmitting ? "TX1;" : "TX0;"
        case "TX1;": transmitting = true; return ""
        case "TX0;": transmitting = false; return ""
        case "PC;": return "PC010;" // FTX-1 field head: 10 W class
        default: return "?;"
        }
    }
}

final class QmxPersonality: RadioPersonality {
    var vfoA = "00014074000" // 11 digits, Hz (Kenwood)
    var mode: Character = "3"
    var power = 5
    var keyerSpeed = 20
    var sMeter = 5

    override var idReply: String { "ID020;" }

    override func respond(to cmd: String) -> String {
        switch cmd {
        case "ID;": return idReply
        case "FA;": return "FA\(vfoA);"
        case "MD;": return "MD\(mode);"
        case "IF;":
            // IF | freq(11) | sp(5) | rit(5) | flags(5) | tx(1) | mode(1) | …
            let tx = transmitting ? "1" : "0"
            return "IF\(vfoA)     +000000000\(tx)\(mode)0000000 ;"
        case "TX;": transmitting = true; return "" // Kenwood: TX; KEYS
        case "RX;": transmitting = false; return ""
        case "SM0;": return String(format: "SM0%04d;", sMeter) // TS-480 width
        case "PC;": return String(format: "PC%03d;", power)
        case "KS;": return String(format: "KS%03d;", keyerSpeed)
        default:
            if cmd.hasPrefix("FA"), cmd.count == 14 {
                let digits = String(Array(cmd)[2...12])
                if digits.allSatisfy(\.isNumber) {
                    vfoA = digits
                    return ""
                }
            }
            if cmd.hasPrefix("MD"), cmd.count == 4 {
                mode = Array(cmd)[2]
                return ""
            }
            if cmd.hasPrefix("PC"), cmd.count == 6,
               let watts = Int(String(Array(cmd)[2...4])) {
                power = min(watts, 5) // QMX: output ceiling, radio clamps
                return ""
            }
            if cmd.hasPrefix("KS"), cmd.count == 6,
               let wpm = Int(String(Array(cmd)[2...4])) {
                keyerSpeed = wpm
                return ""
            }
            if cmd.hasPrefix("KY ") { return "" }
            return "?;"
        }
    }
}
