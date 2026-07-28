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
    @State private var showingSettings = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Form {
                statusSection
                Section {
                    if settings.wsprIsConfigured {
                        LabeledContent("Callsign", value: settings.callsign)
                        LabeledContent("Grid",
                                       value: Maidenhead.square(settings.grid))
                        Button("Edit in Settings", systemImage: "gear") {
                            showingSettings = true
                        }
                    } else {
                        // One row, not a banner plus the empty values it is
                        // complaining about — and it goes where it points.
                        Button {
                            showingSettings = true
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Set your callsign and grid")
                                    Text("Required before the beacon can "
                                         + "transmit")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName:
                                        "person.crop.circle.badge.exclamationmark")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Picker("Power", selection: $settings.wsprPowerDBm) {
                        ForEach(Self.powerLevels, id: \.self) { dbm in
                            Text(Self.powerLabel(dbm)).tag(dbm)
                        }
                    }
                } header: {
                    Text("Station")
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
                    Text(startBlockedReason
                         ?? "The radio transmits unattended until you stop "
                            + "it. Check the antenna and power first.")
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
        .sheet(isPresented: $showingSettings) { AppSettingsView() }
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

    private var canStart: Bool { startBlockedReason == nil }

    /// Why Start is unavailable — a disabled button with no explanation is
    /// a dead end.
    private var startBlockedReason: String? {
        if rig.session == nil {
            return "Connect to a bridge first — the beacon needs a radio."
        }
        if settings.callsign.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Set your callsign in Settings."
        }
        if !Maidenhead.isValid(settings.grid) {
            return settings.grid.isEmpty
                ? "Set your grid in Settings, or use your current location."
                : "“\(settings.grid)” isn't a Maidenhead locator — expected "
                  + "something like IO91 or IO91wm."
        }
        if !settings.wsprIsConfigured {
            return "That callsign can't be encoded into a WSPR message."
        }
        return nil
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
