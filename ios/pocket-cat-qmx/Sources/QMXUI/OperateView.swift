// Main rig screen: frequency, the QMX's four modes + sideband, RIT,
// split, keyer speed, meters, and PTT.

import CATBridgeKit
import QMXKit
import SwiftUI

struct OperateView: View {
    @Environment(RigController.self) private var rig
    @State private var transmitting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FrequencyDisplay()
                modeStrip
                MeterCluster()
                controlsGrid
                pttButton
            }
            .padding()
        }
        .navigationTitle("QMX")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionStatusButton() }
        }
        .task { await rig.refreshSecondaryState() }
    }

    // MARK: - Mode + sideband

    private var modeStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(QMXMode.allCases) { mode in
                    Button(mode.title) {
                        Task { await rig.setMode(mode) }
                    }
                    .buttonStyle(.bordered)
                    .tint(rig.currentMode == mode ? .accentColor : .secondary)
                }
            }
            Picker("Sideband", selection: Binding(
                get: { rig.sideband },
                set: { new in Task { await rig.setSideband(new) } }
            )) {
                ForEach(Sideband.allCases, id: \.self) { sideband in
                    Text(sideband.rawValue).tag(sideband)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
    }

    // MARK: - RIT / split / keyer

    private var controlsGrid: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("RIT", isOn: Binding(
                    get: { rig.ritEnabled },
                    set: { on in Task { await rig.setRIT(enabled: on) } }
                ))
                .toggleStyle(.button)
                if rig.ritEnabled {
                    HStack(spacing: 4) {
                        Button("−10") { Task { await rig.nudgeRIT(by: -10) } }
                        Text("\(rig.ritOffset >= 0 ? "+" : "")\(rig.ritOffset) Hz")
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 76)
                        Button("+10") { Task { await rig.nudgeRIT(by: 10) } }
                        Button {
                            Task { await rig.clearRIT() }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.callout)
                }
                Spacer()
                Toggle("Split", isOn: Binding(
                    get: { rig.splitEnabled },
                    set: { on in Task { await rig.setSplit(on) } }
                ))
                .toggleStyle(.button)
            }
            HStack {
                Text("Keyer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "\(rig.keyerSpeed ?? 0) WPM",
                    value: Binding(
                        get: { rig.keyerSpeed ?? 20 },
                        set: { wpm in
                            Task { await rig.setKeyerSpeed(wpm) }
                        }
                    ),
                    in: 4...60
                )
                .font(.callout.monospacedDigit())
                Spacer()
                if let vfoB = rig.vfoB {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("VFO B")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(vfoB.description)
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - PTT

    private var pttButton: some View {
        Button {
            transmitting.toggle()
            Task {
                if transmitting {
                    await rig.pressPTT()
                } else {
                    await rig.releasePTT()
                }
            }
        } label: {
            Label(transmitting ? "Receive" : "Transmit",
                  systemImage: transmitting
                    ? "antenna.radiowaves.left.and.right.circle.fill"
                    : "antenna.radiowaves.left.and.right.circle")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(transmitting ? .red : .accentColor)
        .onChange(of: rig.state?.isTransmitting ?? false) { _, isTX in
            // Watchdog/failsafe can unkey behind our back — follow it.
            transmitting = isTX
        }
        .accessibilityHint("Keys the transmitter. The bridge failsafe "
                           + "unkeys automatically if the link drops.")
    }
}
