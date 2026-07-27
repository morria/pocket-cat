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
    /// nil when the radio has no RF power control — callers must also check
    /// `.rfPowerControl` in `capabilities`.
    var readPower: CATCommand? { get }
    /// Valid watts for `setPower(watts:)`; nil when power is uncontrollable.
    var powerRange: ClosedRange<Int>? { get }

    /// Turn the radio's unsolicited state pushes on/off (Yaesu
    /// Auto-Information). nil when the dialect has no such mechanism —
    /// callers must also check `.autoInformation` in `capabilities`.
    var enableAutoInformation: CATCommand? { get }
    var disableAutoInformation: CATCommand? { get }

    func setFrequency(_ frequency: Frequency) throws -> CATCommand
    func setMode(_ mode: OperatingMode) throws -> CATCommand
    func keyerText(_ text: String) throws -> CATCommand
    func setPower(watts: Int) throws -> CATCommand

    /// nil when the dialect has no wire command for `setting` on this radio.
    func readSetting(_ setting: RigSetting) -> CATCommand?
    func setSetting(_ setting: RigSetting, to value: Int) throws -> CATCommand
    /// Valid values for `setting`; nil when unsupported.
    func settingRange(_ setting: RigSetting) -> ClosedRange<Int>?

    /// Menu-item access (Yaesu `EX`) — gate on `.menuAccess` in
    /// `capabilities`. `number` is the radio's documented menu number as a
    /// digit string; values are the raw digit strings from the radio's CAT
    /// reference, deliberately untyped (menu tables are hundreds of entries
    /// and firmware-specific).
    func readMenu(number: String) throws -> CATCommand
    func setMenu(number: String, value: String) throws -> CATCommand

    /// Parses a complete `;`-terminated reply to `command`.
    func parse(reply: String, to command: CATCommand) throws -> CATValue
    /// Parses a frame that arrived with no command in flight (Yaesu
    /// Auto-Information, late replies). nil = unrecognized, drop.
    func parseUnsolicited(_ frame: String) -> CATValue?
}

extension CATDialect {
    /// Default: no auto-information mechanism.
    public var enableAutoInformation: CATCommand? { nil }
    public var disableAutoInformation: CATCommand? { nil }

    /// Defaults: no RF power control, no settings, no menu access.
    public var readPower: CATCommand? { nil }
    public var powerRange: ClosedRange<Int>? { nil }
    public func setPower(watts: Int) throws -> CATCommand {
        throw CATBridgeError.unsupportedCapability(.rfPowerControl)
    }

    public func readSetting(_ setting: RigSetting) -> CATCommand? { nil }
    public func setSetting(_ setting: RigSetting,
                           to value: Int) throws -> CATCommand {
        throw CATBridgeError.unsupportedSetting(setting)
    }
    public func settingRange(_ setting: RigSetting) -> ClosedRange<Int>? {
        nil
    }

    public func readMenu(number: String) throws -> CATCommand {
        throw CATBridgeError.unsupportedCapability(.menuAccess)
    }
    public func setMenu(number: String, value: String) throws -> CATCommand {
        throw CATBridgeError.unsupportedCapability(.menuAccess)
    }

    /// Frames are ASCII and end in ';' — shared sanity check for parsers.
    func requireTerminated(_ frame: String) throws {
        guard frame.hasSuffix(";") else {
            throw CATBridgeError.malformedResponse(frame)
        }
    }
}
