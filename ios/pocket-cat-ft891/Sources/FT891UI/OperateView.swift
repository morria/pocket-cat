// The main rig screen: frequency, mode, band, meters, power, tuner,
// split/clarifier/VFO row, RX-chain drawer, and hold-to-talk PTT.

import CATBridgeKit
import FT891Kit
import SwiftUI

struct OperateView: View {
    @Environment(RigController.self) private var rig
    @State private var showingTuneConfirm = false
    @State private var showingSettings = false
    @State private var showingMemories = false
    @State private var powerEditing: Double?

    private var isTransmitting: Bool { rig.state?.isTransmitting ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                FrequencyDisplay()
                ModeStrip()
                BandBar()

                if isTransmitting || rig.isTuning {
                    TXMeterCluster()
                        .padding(.horizontal)
                } else {
                    SMeterView(raw: rig.state?.sMeter)
                        .padding(.horizontal)
                }

                powerRow
                utilityRow
                RXControlsDrawer()
                PTTButton()
                    .padding(.top, 4)
            }
            .padding(.vertical)
        }
        .navigationTitle("FT-891")
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
                    Button("App Settings…", systemImage: "gear") {
                        showingSettings = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingSettings) { AppSettingsView() }
        .sheet(isPresented: $showingMemories) { MemoriesView() }
        .overlay {
            if isTransmitting {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.red.opacity(0.8), lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .task { await rig.refreshSecondaryState() }
    }

    private var powerRow: some View {
        VStack(spacing: 2) {
            HStack {
                Label("RF Power", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(powerEditing ?? (rig.state?.power ?? 100))) W")
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            Slider(
                value: Binding(
                    get: {
                        powerEditing ?? (rig.state?.power ?? 100)
                    },
                    set: { powerEditing = $0 }
                ),
                in: 5...100, step: 1
            ) { editing in
                if !editing, let watts = powerEditing {
                    powerEditing = nil
                    Task { await rig.setPower(watts: Int(watts)) }
                }
            }
            .accessibilityLabel("RF power")
            .accessibilityValue("\(Int(rig.state?.power ?? 0)) watts")
        }
        .padding(.horizontal)
    }

    private var utilityRow: some View {
        HStack(spacing: 10) {
            Button {
                showingTuneConfirm = true
            } label: {
                Label(rig.isTuning ? "Tuning…" : "Tune",
                      systemImage: "aqi.medium")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(rig.isTuning ? .orange : nil)
            .disabled(rig.isTuning)
            .confirmationDialog(
                "Start antenna tune cycle?",
                isPresented: $showingTuneConfirm,
                titleVisibility: .visible
            ) {
                Button("Tune (Transmits a Carrier)", role: .destructive) {
                    Task { await rig.startTuneCycle() }
                }
            } message: {
                Text("The radio will transmit while the tuner matches. "
                     + "Make sure an antenna or dummy load is connected. "
                     + "Requires menu 16-15 Tuner Type to be set.")
            }

            Button {
                Task {
                    await rig.setSplit(
                        rig.splitState == .off ? .on : .off)
                }
            } label: {
                Label("Split", systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(rig.splitState == .off ? nil : .blue)

            Button {
                Task { await rig.swapVFOs() }
            } label: {
                Label("A⇄B", systemImage: "rectangle.2.swap")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .font(.callout)
        .padding(.horizontal)
    }
}

struct ModeStrip: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FT891Mode.all, id: \.self) { mode in
                    let selected = rig.state?.mode == mode
                    Button(FT891Mode.title(mode)) {
                        Task { await rig.setMode(mode) }
                    }
                    .font(.footnote.weight(selected ? .bold : .regular))
                    .buttonStyle(.bordered)
                    .tint(selected ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Hold to transmit. Deliberate by design: a drag/press gesture that keys
/// only while held, with loud visual state. The library's failsafe and
/// watchdog back this up.
struct PTTButton: View {
    @Environment(RigController.self) private var rig
    @State private var pressed = false

    private var isTransmitting: Bool { rig.state?.isTransmitting ?? false }

    var body: some View {
        Text(isTransmitting ? "ON AIR" : "Hold to Talk")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                isTransmitting ? Color.red : Color.accentColor,
                in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        Task { await rig.pressPTT() }
                    }
                    .onEnded { _ in
                        pressed = false
                        Task { await rig.releasePTT() }
                    }
            )
            .sensoryFeedback(.impact(weight: .heavy),
                             trigger: isTransmitting)
            .accessibilityLabel(
                isTransmitting ? "Transmitting" : "Push to talk")
            .accessibilityHint("Double-tap and hold to transmit")
    }
}
