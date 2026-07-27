// Capture / diff / apply between the live radio and RadioProfile files.
// All radio I/O funnels through the TransceiverSession actor, one command
// at a time; progress is reported per item so the UI can show a
// determinate bar (a full sweep is ~170 round trips — seconds at 38400,
// approaching a minute at 4800 baud).

import CATBridgeCore
import Foundation

public struct ProfileProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentItem: String
}

public enum ProfileEngineError: Error, Equatable {
    case frontPanelMenuActive
    case cancelled
}

public enum ProfileEngine {
    /// Read the radio's full configuration. Throws if the operator is in
    /// the front-panel menu (EX behavior there is undocumented).
    public static func capture(
        from session: TransceiverSession,
        name: String,
        savedAt: Date,
        progress: (@Sendable (ProfileProgress) -> Void)? = nil
    ) async throws -> RadioProfile {
        if try await session.readFrontPanelMenuActive() {
            throw ProfileEngineError.frontPanelMenuActive
        }

        var profile = RadioProfile(name: name, savedAt: savedAt)
        let items = MenuCatalog.profileItems
        let versionItems = MenuCatalog.items(in: .version)
        let total = items.count + versionItems.count + 5

        var done = 0
        func step(_ label: String) {
            done += 1
            progress?(ProfileProgress(completed: done, total: total,
                                      currentItem: label))
        }

        // Per-item failures skip rather than abort: one surprise reply
        // format must not cost the user a whole sweep. Skips are recorded
        // in the profile's notes so they're visible and persistent.
        var skipped: [String] = []
        for item in items {
            try Task.checkCancellation()
            do {
                profile.menu[item.id] = try await session.readMenuValue(item)
            } catch is CancellationError {
                throw ProfileEngineError.cancelled
            } catch {
                skipped.append(item.id)
            }
            step(item.friendlyName)
        }
        if !skipped.isEmpty {
            profile.notes = "Not captured (unreadable): "
                + skipped.joined(separator: ", ")
        }
        for item in versionItems {
            try Task.checkCancellation()
            profile.radioFirmware[item.id] =
                (try? await session.readMenuValue(item)) ?? 0
            step(item.friendlyName)
        }

        profile.operating.vfoAHz = try await session.readFrequency().hertz
        step("VFO A")
        profile.operating.vfoBHz = try? await session.readVFOB().hertz
        step("VFO B")
        profile.operating.powerWatts = try? await session.readPower()
        step("RF power")
        profile.operating.split = (try? await session.readSplit())?.rawValue
        step("Split")
        if let mode = try? await currentModeCode(session) {
            profile.operating.modeCode = mode
        }
        step("Mode")
        return profile
    }

    /// Menu items where `profile` differs from the live radio (reads the
    /// radio; ~160 round trips).
    public static func diff(
        _ profile: RadioProfile,
        against session: TransceiverSession,
        progress: (@Sendable (ProfileProgress) -> Void)? = nil
    ) async throws -> [MenuDiff] {
        var diffs: [MenuDiff] = []
        let entries = orderedMenuEntries(profile)
        for (index, (item, newValue)) in entries.enumerated() {
            try Task.checkCancellation()
            progress?(ProfileProgress(completed: index + 1,
                                      total: entries.count,
                                      currentItem: item.friendlyName))
            let current = try? await session.readMenuValue(item)
            if current != newValue {
                diffs.append(MenuDiff(item: item, currentValue: current,
                                      newValue: newValue))
            }
        }
        return diffs
    }

    /// Write `diffs` to the radio in catalog order, re-reading each item to
    /// confirm. Never throws on a per-item failure — failures are collected
    /// so the UI can report exactly what did and didn't take.
    public static func apply(
        diffs: [MenuDiff],
        operating: RadioProfile.OperatingState?,
        to session: TransceiverSession,
        progress: (@Sendable (ProfileProgress) -> Void)? = nil
    ) async throws -> [ApplyResult] {
        if try await session.readFrontPanelMenuActive() {
            throw ProfileEngineError.frontPanelMenuActive
        }

        var results: [ApplyResult] = []
        let total = diffs.count + (operating == nil ? 0 : 1)
        for (index, diff) in diffs.enumerated() {
            try Task.checkCancellation()
            progress?(ProfileProgress(completed: index + 1, total: total,
                                      currentItem: diff.item.friendlyName))
            do {
                try await session.writeMenuValue(diff.item,
                                                 value: diff.newValue)
                let readback = try await session.readMenuValue(diff.item)
                if readback == diff.newValue {
                    results.append(ApplyResult(itemID: diff.item.id,
                                               outcome: .applied))
                } else {
                    results.append(ApplyResult(
                        itemID: diff.item.id,
                        outcome: .failed(
                            "radio kept \(diff.item.label(for: readback))")))
                }
            } catch {
                results.append(ApplyResult(itemID: diff.item.id,
                                           outcome: .failed("\(error)")))
            }
        }

        // Operating state last, so menu-driven behavior (steps, BFO…) is
        // already in place when the dial state lands.
        if let operating {
            progress?(ProfileProgress(completed: total, total: total,
                                      currentItem: "Operating state"))
            let outcome = await applyOperating(operating, to: session)
            results.append(ApplyResult(itemID: "operating", outcome: outcome))
        }
        return results
    }

    private static func applyOperating(
        _ operating: RadioProfile.OperatingState,
        to session: TransceiverSession
    ) async -> ApplyResult.Outcome {
        var failures: [String] = []
        if let code = operating.modeCode,
           let mode = modeForCode(code) {
            do { try await session.setMode(mode) }
            catch { failures.append("mode") }
        }
        if let hz = operating.vfoBHz {
            do { try await session.setVFOB(Frequency(hz: hz)) }
            catch { failures.append("VFO B") }
        }
        if let hz = operating.vfoAHz {
            do { try await session.setFrequency(Frequency(hz: hz)) }
            catch { failures.append("VFO A") }
        }
        if let watts = operating.powerWatts {
            do { try await session.setPower(watts: watts) }
            catch { failures.append("power") }
        }
        if let split = operating.split,
           let state = SplitState(rawValue: split) {
            do { try await session.setSplit(state) }
            catch { failures.append("split") }
        }
        return failures.isEmpty
            ? .applied
            : .failed("could not set: \(failures.joined(separator: ", "))")
    }

    /// Profile menu entries resolved against the catalog, in catalog order.
    /// Unknown ids (newer app wrote the file) are skipped — forward
    /// compatibility.
    public static func orderedMenuEntries(
        _ profile: RadioProfile
    ) -> [(MenuItem, Int)] {
        MenuCatalog.profileItems.compactMap { item in
            profile.menu[item.id].map { (item, $0) }
        }
    }

    private static func currentModeCode(
        _ session: TransceiverSession
    ) async throws -> String? {
        guard let reply = try await session.rawCommand(
            "MD0;", expectsReply: true, isIdempotent: true),
            reply.count == 5 else { return nil }
        return String(Array(reply)[3])
    }

    private static func modeForCode(_ code: String) -> OperatingMode? {
        guard let char = code.first else { return nil }
        return FT891Mode.modeForCode[char]
    }
}
