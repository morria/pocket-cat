// The main rig screen: frequency, mode, band, meters, power, tuner,
// split/clarifier/VFO row, RX-chain drawer, and hold-to-talk PTT.

import CATBridgeKit
import FT891Kit
import SwiftUI

struct OperateView: View {
    @Environment(RigController.self) private var rig
    @State private var showingSettings = false
    @State private var showingMemories = false
    @State private var powerEditing: Double?
    @State private var passband = PassbandController()

    private var isTransmitting: Bool { rig.state?.isTransmitting ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                FrequencyDisplay()
                ModeStrip()
                BandBar()

                // Fixed-height slot: keying changes what this says,
                // never where anything below it sits.
                MeterPanel(isTransmitting: isTransmitting || rig.isTuning,
                           passband: passband)
                    .padding(.horizontal)

                powerRow
                utilityRow
                PassbandStrip(passband: passband)
                RXControlsDrawer()
            }
            .padding(.vertical)
        }
        // PTT is docked outside the scroll: the one safety-critical
        // control never scrolls away and never moves under the thumb.
        .safeAreaInset(edge: .bottom) {
            PTTButton()
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(.bar)
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
                Task { await rig.startTuneCycle() }
            } label: {
                Label(rig.isTuning ? "Tuning…" : "Tune",
                      systemImage: "aqi.medium")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(rig.isTuning ? .orange : nil)
            .disabled(rig.isTuning || isTransmitting)
            .accessibilityHint("Transmits a carrier while the tuner "
                               + "matches the antenna")

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
            .disabled(isTransmitting)

            Button {
                Task { await rig.swapVFOs() }
            } label: {
                Label("A⇄B", systemImage: "rectangle.2.swap")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isTransmitting)
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
                    ModeChip(title: FT891Mode.title(mode),
                             selected: rig.state?.mode == mode) {
                        Task { await rig.setMode(mode) }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

/// A mode button. Selection is carried by fill *and* weight, not colour
/// alone, and the target meets the 44 pt minimum.
private struct ModeChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if selected {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .font(.footnote.weight(selected ? .bold : .regular))
        .tint(selected ? .accentColor : .secondary)
        .frame(minHeight: 44)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Hold to transmit. Deliberate by design: a drag/press gesture that keys
/// only while held, with loud visual state. The library's failsafe and
/// watchdog back this up.
struct PTTButton: View {
    @Environment(RigController.self) private var rig
    @State private var pressed = false
    @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 56

    private var isTransmitting: Bool { rig.state?.isTransmitting ?? false }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .padding(.vertical, 4)
            .background(
                isTransmitting ? Color.red
                               : Color.accentColor.opacity(pressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .padding(.horizontal)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: .infinity,
                                maximumDistance: .infinity) {
                // Never fires: the press has no maximum duration.
            } onPressingChanged: { isPressing in
                pressed = isPressing
                Task {
                    if isPressing {
                        await rig.pressPTT()
                    } else {
                        await rig.releasePTT()
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .heavy),
                             trigger: isTransmitting)
            .accessibilityLabel(
                isTransmitting ? "Transmitting" : "Push to talk")
            .accessibilityHint("Double-tap and hold to transmit")
    }

    /// Separates "the gesture fired" from "the radio confirmed".
    private var title: String {
        if isTransmitting { return "ON AIR" }
        return pressed ? "Keying…" : "Hold to Talk"
    }
}
