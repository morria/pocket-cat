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

    override init() {
        super.init()
        menuBaud = 38400
    }

    override var idReply: String { "ID0650;" }

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
        case "AI;": return "AI0;"
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
        default: return "?;"
        }
    }
}

final class QmxPersonality: RadioPersonality {
    var vfoA = "00014074000" // 11 digits, Hz (Kenwood)
    var mode: Character = "3"

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
            return "?;"
        }
    }
}
