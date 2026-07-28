// WSPR beacon control. The phone encodes the message and clocks 162 tones
// out through the radio; there is no audio path involved.

import CATBridgeKit
import QMXKit
import SwiftUI

struct WSPRView: View {
    @Environment(RigController.self) private var rig
    @Bindable private var settings = AppSettings.shared
    @State private var beacon = WSPRBeacon()
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Form {
                statusSection
                if !settings.wsprIsConfigured {
                    Section {
                        Label("Set your callsign and grid in Settings.",
                              systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("Callsign",
                                   value: settings.callsign.isEmpty
                                        ? "—" : settings.callsign)
                    LabeledContent("Grid",
                                   value: settings.grid.isEmpty
                                        ? "—" : Maidenhead.square(settings.grid))
                    Picker("Power", selection: $settings.wsprPowerDBm) {
                        ForEach(Self.powerLevels, id: \.self) { dbm in
                            Text(Self.powerLabel(dbm)).tag(dbm)
                        }
                    }
                } header: {
                    Text("Station")
                } footer: {
                    Text("Callsign and grid live in Settings — they're "
                         + "shared with the CW templates.")
                }

                Section {
                    Picker("Band", selection: $settings.wsprBandName) {
                        ForEach(WSPRBand.all) { band in
                            Text(band.name).tag(band.name)
                        }
                    }
                    LabeledContent("Dial", value: dialText)
                    Picker("Transmit", selection: $settings.wsprSlotInterval) {
                        Text("Every slot").tag(1)
                        Text("Every 2nd slot").tag(2)
                        Text("Every 3rd slot").tag(3)
                        Text("Every 5th slot").tag(5)
                        Text("Every 10th slot").tag(10)
                    }
                } header: {
                    Text("Transmission")
                } footer: {
                    Text("Frames start on even UTC minutes and run for "
                         + "110.6 seconds. Transmitting every slot hogs the "
                         + "band — every third is the usual courtesy.")
                }

                Section {
                    if beacon.isRunning {
                        Button("Stop Beacon", role: .destructive) {
                            Task { await beacon.stop() }
                        }
                    } else {
                        Button("Start Beacon", action: start)
                            .disabled(!canStart)
                    }
                } footer: {
                    Text(canStart
                         ? "The radio transmits unattended until you stop "
                           + "it. Check the antenna and power first."
                         : "Enter a callsign and a four-character grid, and "
                           + "connect to a radio.")
                }
            }
        .navigationTitle("WSPR")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionStatusButton() }
        }
        .onReceive(tick) { now = $0 }
        .task {
            beacon.session = rig.session
            beacon.slotInterval = settings.wsprSlotInterval
        }
        .onChange(of: settings.wsprSlotInterval) {
            beacon.slotInterval = settings.wsprSlotInterval
        }
        .onChange(of: rig.connectionPhase) { beacon.session = rig.session }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            switch beacon.phase {
            case .idle:
                Label("Idle", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            case .waiting(let until):
                let seconds = max(0, Int(until.timeIntervalSince(now)))
                Label("Next frame in \(seconds) s",
                      systemImage: "clock")
            case .transmitting(let symbol):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Transmitting \(symbol + 1) / "
                          + "\(WSPREncoder.symbolCount)",
                          systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.red)
                    ProgressView(value: Double(symbol + 1),
                                 total: Double(WSPREncoder.symbolCount))
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if beacon.transmissionCount > 0 {
                LabeledContent("Frames sent",
                               value: "\(beacon.transmissionCount)")
            }
        }
    }

    // MARK: - Helpers

    private static let powerLevels = [0, 3, 7, 10, 13, 17, 20, 23, 27, 30,
                                      33, 37, 40]

    private static func powerLabel(_ dbm: Int) -> String {
        let watts = pow(10.0, Double(dbm - 30) / 10.0)
        let formatted = watts < 1
            ? String(format: "%.3g W", watts)
            : String(format: "%.0f W", watts)
        return "\(dbm) dBm · \(formatted)"
    }

    private var dialText: String {
        let hz = settings.wsprBand.dialHz
        return String(format: "%.6f MHz", Double(hz) / 1_000_000)
    }

    private var canStart: Bool {
        rig.session != nil && settings.wsprIsConfigured
    }

    private func start() {
        beacon.session = rig.session
        beacon.start(callsign: settings.callsign,
                     grid: Maidenhead.square(settings.grid),
                     powerDBm: settings.wsprPowerDBm,
                     band: settings.wsprBand)
    }
}

#Preview {
    NavigationStack { WSPRView() }.environment(RigController())
}
