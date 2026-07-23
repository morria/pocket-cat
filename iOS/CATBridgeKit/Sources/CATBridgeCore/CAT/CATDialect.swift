// CAT dialect abstraction. The session selects a dialect from the bridge's
// radio_id + the radio's ID; reply; apps never see dialects directly.

public protocol CATDialect: Sendable {
    var radioModel: RadioModel { get }
    /// Exact expected `ID;` reply, e.g. "ID0650;" — doubles as the
    /// baud-probe hit test.
    var idReply: String { get }
    var capabilities: RadioCapabilities { get }

    var pttOn: CATCommand { get }
    var pttOff: CATCommand { get }
    /// Byte string the bridge should emit if the BLE link dies (unkey).
    var failsafeString: String { get }

    var readID: CATCommand { get }
    var readInfo: CATCommand { get }
    var readFrequency: CATCommand { get }
    var readMode: CATCommand { get }
    /// nil when reading PTT state is unsafe/unsupported (Kenwood `TX;` KEYS
    /// the radio — it is a set, never a read).
    var readPTT: CATCommand? { get }
    var readSMeter: CATCommand? { get }

    func setFrequency(_ frequency: Frequency) throws -> CATCommand
    func setMode(_ mode: OperatingMode) throws -> CATCommand
    func keyerText(_ text: String) throws -> CATCommand

    /// Parses a complete `;`-terminated reply to `command`.
    func parse(reply: String, to command: CATCommand) throws -> CATValue
    /// Parses a frame that arrived with no command in flight (Yaesu
    /// Auto-Information, late replies). nil = unrecognized, drop.
    func parseUnsolicited(_ frame: String) -> CATValue?
}

extension CATDialect {
    /// Frames are ASCII and end in ';' — shared sanity check for parsers.
    func requireTerminated(_ frame: String) throws {
        guard frame.hasSuffix(";") else {
            throw CATBridgeError.malformedResponse(frame)
        }
    }
}
