// The MM/ML Menu Manager client: discovery-reply parsing (pure) and the
// full protocol against the simulator through the real session.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite struct MenuDiscoveryParsingTests {
    @Test func parsesScalarNode() {
        let node = QMXMenuClient.parseDiscovery(
            reply: "MM3|2|Threshold S;", index: 1, parent: nil)
        #expect(node?.kind == .number)
        #expect(node?.meta == 2)
        #expect(node?.name == "Threshold S")
        #expect(node?.wirePath == ["Threshold S"])
    }

    @Test func parsesGridPageWithColumnCount() {
        let node = QMXMenuClient.parseDiscovery(
            reply: "MM0|0|Band config.[16];", index: 12, parent: nil)
        #expect(node?.kind == .submenu)
        #expect(node?.columns == 16)
        #expect(node?.name == "Band config.")
    }

    @Test func numericNamesAreIndexAddressed() {
        // "Choose filters" rows are named 50/100/… — the manual requires
        // numeric paths for those, so wirePath must use the index.
        let parent = QMXMenuClient.parseDiscovery(
            reply: "MM0|0|Choose filters;", index: 10, parent: nil)!
        let row = QMXMenuClient.parseDiscovery(
            reply: "MM7|6|50;", index: 0, parent: parent)
        #expect(row?.name == "50")
        #expect(row?.wirePath == ["Choose filters", "0"])
        #expect(row?.displayPath == ["Choose filters", "50"])
    }

    @Test func malformedRepliesReturnNil() {
        for bad in ["MM3|2;", "XX3|2|Name;", "MMa|b|Name;", "MM3|2|Name"] {
            #expect(QMXMenuClient.parseDiscovery(
                reply: bad, index: 0, parent: nil) == nil, "\(bad)")
        }
    }
}

@Suite("Menu client ↔ QMX simulator")
struct MenuClientSimTests {
    func makeClient() async throws
        -> (QMXMenuClient, TransceiverSession, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (QMXMenuClient(session: session), session, transport)
    }

    @Test func discoversRootAndChildren() async throws {
        let (client, session, _) = try await makeClient()
        let roots = try await client.children()
        #expect(roots.map(\.name).contains("Audio"))
        #expect(roots.map(\.name).contains("Band config."))
        let audio = roots.first { $0.name == "Audio" }!
        let audioChildren = try await client.children(of: audio)
        #expect(audioChildren.map(\.name)
            == ["AGC settings", "Sidetone volume", "Sidetone frequency"])
        await session.disconnect()
    }

    @Test func getSetRoundTripByName() async throws {
        let (client, session, transport) = try await makeClient()
        let roots = try await client.children()
        let audio = roots.first { $0.name == "Audio" }!
        let agc = try await client.children(of: audio)
            .first { $0.name == "AGC settings" }!
        let threshold = try await client.children(of: agc)
            .first { $0.name == "Threshold S" }!

        #expect(try await client.value(of: threshold) == "4")
        try await client.setValue("7", of: threshold)
        #expect(try await client.value(of: threshold) == "7")
        // The sim's tree really changed (MM sets persist on a real QMX).
        let rig = await transport.rigState
        #expect(rig.menuRoot[0].children[0].children[1].values == ["7"])
        await session.disconnect()
    }

    @Test func listOptionsViaML() async throws {
        let (client, session, _) = try await makeClient()
        let roots = try await client.children()
        let cw = roots.first { $0.name == "CW" }!
        let keyer = try await client.children(of: cw)
            .first { $0.name == "CW Keyer" }!
        let mode = try await client.children(of: keyer)
            .first { $0.name == "Keyer mode" }!
        #expect(mode.kind == .list)
        let options = try await client.listOptions(for: mode)
        #expect(options == ["Straight", "IAMBIC A", "IAMBIC B", "Ultimatic"])
        try await client.setValue("IAMBIC B", of: mode)
        #expect(try await client.value(of: mode) == "IAMBIC B")
        await session.disconnect()
    }

    @Test func numericRowsReadViaIndexPath() async throws {
        let (client, session, _) = try await makeClient()
        let roots = try await client.children()
        let cw = roots.first { $0.name == "CW" }!
        let filters = try await client.children(of: cw)
            .first { $0.name == "Choose filters" }!
        let rows = try await client.children(of: filters)
        #expect(rows.map(\.name) == ["50", "100", "200", "300"])
        #expect(rows[0].wirePath.last == "0") // index-addressed
        #expect(try await client.value(of: rows[3]) == "DISABLED")
        try await client.setValue("ENABLED", of: rows[3])
        #expect(try await client.value(of: rows[3]) == "ENABLED")
        await session.disconnect()
    }

    @Test func gridCellsAddressColumns() async throws {
        let (client, session, _) = try await makeClient()
        let roots = try await client.children()
        let band = roots.first { $0.name == "Band config." }!
        #expect(band.columns == 3)
        let rows = try await client.children(of: band)
        let gain = rows.first { $0.name == "RF gain (dB)" }!
        #expect(try await client.value(of: gain, column: 2) == "74")
        try await client.setValue("63", of: gain, column: 2)
        #expect(try await client.value(of: gain, column: 2) == "63")
        #expect(try await client.value(of: gain, column: 0) == "54")
        await session.disconnect()
    }

    @Test func invalidListValueRejected() async throws {
        let (client, session, _) = try await makeClient()
        let roots = try await client.children()
        let audio = roots.first { $0.name == "Audio" }!
        let agc = try await client.children(of: audio)
            .first { $0.name == "AGC settings" }!
        let enable = try await client.children(of: agc)
            .first { $0.name == "AGC enable" }!
        // The sim ignores invalid list writes ("?;" with no in-flight
        // command is dropped) — read-back shows the value survived.
        try await client.setValue("MAYBE", of: enable)
        #expect(try await client.value(of: enable) == "ENABLED")
        await session.disconnect()
    }

    @Test func snapshotCoversEveryLeafIncludingGridCells() async throws {
        let (client, session, _) = try await makeClient()
        let leaves = try await client.snapshotTree()
        let keys = Set(leaves.map(\.key))
        #expect(keys.contains("Audio|AGC settings|Threshold S"))
        #expect(keys.contains("CW|Choose filters|0"))
        #expect(keys.contains("Band config.|RF gain (dB)[0]"))
        #expect(keys.contains("Band config.|RF gain (dB)[2]"))
        // Actions and submenus are not values.
        #expect(!keys.contains("System config|Factory reset"))
        await session.disconnect()
    }
}
