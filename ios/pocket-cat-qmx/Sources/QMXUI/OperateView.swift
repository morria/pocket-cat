// Main rig screen: frequency, the QMX's four modes + sideband, RIT,
// split, keyer speed, meters, and PTT.

import CATBridgeKit
import QMXKit
import SwiftUI

struct OperateView: View {
    @Environment(RigController.self) private var rig
    @State private var transmitting = false
    @State private var showingMemories = false
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FrequencyDisplay()
                modeStrip
                BandBar()
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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Memories…", systemImage: "bookmark") {
                        showingMemories = true
                    }
                    Button("Settings…", systemImage: "gear") {
                        showingSettings = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingMemories) { MemoriesView() }
        .sheet(isPresented: $showingSettings) { AppSettingsView() }
        .overlay {
            if rig.state?.isTransmitting ?? false {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.red.opacity(0.8), lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .task { await rig.refreshSecondaryState() }
    }

    // MARK: - Mode

    private var modeStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(QMXMode.Family.allCases) { family in
                    ModeChip(title: family.title,
                             selected: rig.currentMode?.family == family,
                             enabled: rig.currentMode != nil) {
                        Task { await rig.setModeFamily(family) }
                    }
                }

                ModeChip(title: "REV",
                         selected: rig.currentMode?.isReversed == true,
                         enabled: rig.currentMode != nil,
                         tint: .orange) {
                    Task {
                        await rig.setReversed(
                            !(rig.currentMode?.isReversed ?? false))
                    }
                }
                .accessibilityLabel("Reverse")
                .accessibilityValue(rig.currentMode?.isReversed == true
                                    ? "On" : "Off")
            }

            // REV (MD) and sideband (Q1) both invert. Saying so, and saying
            // what the combination currently amounts to, is the only way
            // two inverters in one screen are comprehensible.
            HStack(spacing: 6) {
                Picker("Sideband", selection: Binding(
                    get: { rig.sideband },
                    set: { new in Task { await rig.setSideband(new) } }
                )) {
                    ForEach(Sideband.allCases, id: \.self) { sideband in
                        Text(sideband.rawValue).tag(sideband)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .disabled(rig.session == nil)
            }

            Text(inversionExplainer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// Both controls invert the same thing at different layers, so two
    /// inversions cancel. Spell out the net result rather than leaving the
    /// operator to discover it on the air.
    private var inversionExplainer: String {
        guard let mode = rig.currentMode else {
            return "Reading mode from the radio…"
        }
        let reversed = mode.isReversed
        let lsb = rig.sideband == .lsb
        switch (reversed, lsb) {
        case (false, false):
            return "\(mode.title) · normal tone sense"
        case (true, false), (false, true):
            return "\(mode.title) · inverted — mark and space are swapped"
        case (true, true):
            return "\(mode.title) · REV and LSB both invert, so they "
                 + "cancel — this is the same as CW/DIGI on USB"
        }
    }

    // MARK: - VFO, RIT, keyer

    private var controlsGrid: some View {
        VStack(spacing: 14) {
            vfoRow
            Divider()
            ritRow
            Divider()
            keyerRow
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Split isn't an on/off state next to A and B — it is one of the three
    /// things the VFO selector can be, which is exactly how the radio
    /// models it (`FR` 0/1/2).
    private var vfoRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("VFO")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let vfoB = rig.vfoB {
                    Text("B  \(vfoB.description)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Picker("VFO", selection: Binding(
                get: { rig.vfoMode },
                set: { new in Task { await rig.setVFOMode(new) } }
            )) {
                Text("A").tag(VFOMode.vfoA)
                Text("B").tag(VFOMode.vfoB)
                Text("Split").tag(VFOMode.split)
            }
            .pickerStyle(.segmented)
            .disabled(rig.session == nil)
            Text(rig.vfoMode == .split
                 ? "Receive on A, transmit on B."
                 : "Receive and transmit on VFO \(rig.vfoMode == .vfoB ? "B" : "A").")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var ritRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("RIT", isOn: Binding(
                    get: { rig.ritEnabled },
                    set: { on in Task { await rig.setRIT(enabled: on) } }
                ))
                .toggleStyle(.button)
                .disabled(rig.session == nil)

                Spacer()

                // Fixed-width readout and icon buttons: "−10" wrapped to two
                // lines when the row got tight.
                Text("\(rig.ritOffset >= 0 ? "+" : "−")\(abs(rig.ritOffset)) Hz")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 84, alignment: .trailing)
                    .foregroundStyle(rig.ritEnabled ? .primary : .secondary)

                HStack(spacing: 0) {
                    Button { Task { await rig.nudgeRIT(by: -10) } } label: {
                        Image(systemName: "minus").frame(width: 44, height: 34)
                    }
                    .accessibilityLabel("RIT down 10 hertz")
                    Divider().frame(height: 20)
                    Button { Task { await rig.nudgeRIT(by: 10) } } label: {
                        Image(systemName: "plus").frame(width: 44, height: 34)
                    }
                    .accessibilityLabel("RIT up 10 hertz")
                }
                .buttonStyle(.bordered)
                .disabled(!rig.ritEnabled)

                Button { Task { await rig.clearRIT() } } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(!rig.ritEnabled || rig.ritOffset == 0)
                .accessibilityLabel("Clear RIT")
            }
            Text("Receiver Incremental Tuning — nudges the receive "
                 + "frequency while transmit stays put. For a station "
                 + "drifting or slightly off your frequency.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var keyerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Keyer speed")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(rig.keyerSpeed ?? 20) WPM")
                    .font(.callout.monospacedDigit())
                Stepper("Keyer speed", value: Binding(
                    get: { rig.keyerSpeed ?? 20 },
                    set: { wpm in Task { await rig.setKeyerSpeed(wpm) } }
                ), in: 4...60)
                .labelsHidden()
                .disabled(rig.session == nil)
            }
            Text("How fast the radio sends the CW you type.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

/// Selection carried by fill and weight, not colour alone, at a 44 pt
/// target. Disabled until the radio's mode is known — an unlit row of
/// chips shouldn't look like "no mode exists".
private struct ModeChip: View {
    let title: String
    let selected: Bool
    var enabled: Bool = true
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Group {
            if selected {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
        .font(.callout.weight(selected ? .semibold : .regular))
        .tint(selected ? tint : .secondary)
        .frame(minHeight: 44)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
