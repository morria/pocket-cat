// Capture / diff / apply between the live radio and a QMXProfile.
// Capture walks the radio's OWN menu tree (MM discovery), so a profile
// covers every setting the firmware exposes — including items this app
// has never heard of. Apply writes MM sets (EEPROM-persistent on the QMX)
// one at a time with read-back verification; per-item failures are
// collected, never fatal.

import CATBridgeKit
import Foundation

public enum ProfileEngine {
    // MARK: - Capture

    public static func capture(
        name: String,
        session: TransceiverSession,
        onProgress: (@Sendable (QMXProfileProgress) -> Void)? = nil
    ) async throws -> QMXProfile {
        var profile = QMXProfile(name: name)
        let client = QMXMenuClient(session: session)

        let leaves = try await client.snapshotTree { count, leaf in
            onProgress?(QMXProfileProgress(
                completed: count, total: nil,
                currentItem: leaf.node.name))
        }
        for leaf in leaves {
            profile.menu[leaf.key] = leaf.value
        }

        profile.firmwareVersion = try? await session.readFirmwareVersion()
        profile.operating.vfoAHz =
            (try? await session.readFrequency())?.hertz
        profile.operating.vfoBHz = (try? await session.readVFOB())?.hertz
        if let mode = try? await session.readQMXMode() {
            profile.operating.modeCode = String(mode.rawValue)
        }
        profile.operating.sideband =
            (try? await session.readSideband())?.rawValue
        profile.operating.split = try? await session.readSplit()
        profile.operating.keyerSpeed = try? await session.read(.keyerSpeed)
        return profile
    }

    // MARK: - Diff

    /// Compare a profile against the live radio, in stable key order.
    public static func diff(
        _ profile: QMXProfile,
        session: TransceiverSession,
        onProgress: (@Sendable (QMXProfileProgress) -> Void)? = nil
    ) async throws -> [QMXMenuDiff] {
        let client = QMXMenuClient(session: session)
        let live = try await client.snapshotTree()
        let liveByKey = Dictionary(uniqueKeysWithValues:
            live.map { ($0.key, $0) })

        var out: [QMXMenuDiff] = []
        let entries = profile.menu.sorted { $0.key < $1.key }
        for (index, entry) in entries.enumerated() {
            onProgress?(QMXProfileProgress(
                completed: index + 1, total: entries.count,
                currentItem: entry.key))
            let current = liveByKey[entry.key]?.value
            if current != entry.value {
                out.append(QMXMenuDiff(
                    key: entry.key,
                    displayName: liveByKey[entry.key]?.node.name
                        ?? entry.key,
                    currentValue: current,
                    newValue: entry.value))
            }
        }
        return out
    }

    // MARK: - Apply

    /// Write the given diffs, read back each to confirm, then restore
    /// operating state last (mode → sideband → VFO-B → VFO-A → split →
    /// keyer speed) so the radio lands where the profile was saved.
    public static func apply(
        _ profile: QMXProfile,
        diffs: [QMXMenuDiff],
        session: TransceiverSession,
        onProgress: (@Sendable (QMXProfileProgress) -> Void)? = nil
    ) async -> [QMXApplyResult] {
        let client = QMXMenuClient(session: session)
        var results: [QMXApplyResult] = []
        // The walk gives us nodes to address writes; index once.
        let live = (try? await client.snapshotTree()) ?? []
        let liveByKey = Dictionary(uniqueKeysWithValues:
            live.map { ($0.key, $0) })

        for (index, diff) in diffs.enumerated() {
            onProgress?(QMXProfileProgress(
                completed: index + 1, total: diffs.count,
                currentItem: diff.displayName))
            guard let leaf = liveByKey[diff.key] else {
                results.append(QMXApplyResult(
                    key: diff.key, displayName: diff.displayName,
                    succeeded: false,
                    detail: "not present in this radio's menu"))
                continue
            }
            do {
                try await client.setValue(diff.newValue, of: leaf.node,
                                          column: leaf.column)
                let readback = try await client.value(of: leaf.node,
                                                      column: leaf.column)
                let ok = readback == diff.newValue
                results.append(QMXApplyResult(
                    key: diff.key, displayName: diff.displayName,
                    succeeded: ok,
                    detail: ok ? nil : "radio kept \(readback)"))
            } catch {
                results.append(QMXApplyResult(
                    key: diff.key, displayName: diff.displayName,
                    succeeded: false, detail: String(describing: error)))
            }
        }

        await applyOperating(profile.operating, session: session)
        return results
    }

    private static func applyOperating(
        _ operating: QMXProfile.OperatingState,
        session: TransceiverSession
    ) async {
        if let code = operating.modeCode?.first,
           let mode = QMXMode(rawValue: code) {
            try? await session.setMode(mode.operatingMode)
        }
        if let sideband = operating.sideband
            .flatMap(Sideband.init(rawValue:)) {
            try? await session.setSideband(sideband)
        }
        if let hz = operating.vfoBHz {
            try? await session.setVFOB(Frequency(hz: hz))
        }
        if let hz = operating.vfoAHz {
            try? await session.setFrequency(Frequency(hz: hz))
        }
        if let split = operating.split {
            try? await session.setSplit(split)
        }
        if let wpm = operating.keyerSpeed {
            try? await session.set(.keyerSpeed, to: wpm)
        }
    }
}
