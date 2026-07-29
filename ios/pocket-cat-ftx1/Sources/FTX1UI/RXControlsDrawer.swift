// Receive-chain controls, all via the library's typed RigSetting API.
// A regular always-visible section (matching the Passband section's
// header treatment) — it was the screen's only collapsed element, which
// read as arbitrary rather than intentional. Values load on appear.

import CATBridgeKit
import FTX1Kit
import SwiftUI

struct RXControlsDrawer: View {
    @Environment(RigController.self) private var rig
    @State private var values: [RigSetting: Double] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Receiver", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            settingSlider("AF Gain", .afGain, range: 0...255)
            settingSlider("RF Gain", .rfGain, range: 0...255)
            settingSlider("Squelch", .squelch, range: 0...100)
            HStack(spacing: 10) {
                settingToggle("NB", .noiseBlanker)
                settingToggle("NR", .noiseReduction)
                settingToggle("ATT", .attenuator)
                // FTX-1 has IPO (0) / AMP (1) only.
                settingToggle("AMP", .preamp)
            }
        }
        .padding(.horizontal)
        .task(id: rig.session == nil) {
            guard rig.session != nil, !loaded else { return }
            loaded = true
            for setting in [RigSetting.afGain, .rfGain, .squelch,
                            .noiseBlanker, .noiseReduction,
                            .attenuator, .preamp] {
                if let value = await rig.readSetting(setting) {
                    values[setting] = Double(value)
                }
            }
        }
    }

    /// IPO / AMP1 / AMP2. `PA0` takes 0...2 on this radio, and the FT-891's
    /// two-state toggle could only ever reach the first two.
    private var preampPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preamp")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Preamp", selection: Binding(
                get: { Int(values[.preamp] ?? 0) },
                set: { (new: Int) in
                    values[.preamp] = Double(new)
                    Task { await rig.setSetting(.preamp, to: new) }
                }
            )) {
                Text("IPO").tag(0)
                Text("AMP1").tag(1)
                Text("AMP2").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    private func settingSlider(_ title: String, _ setting: RigSetting,
                               range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { values[setting] ?? range.lowerBound },
                    set: { values[setting] = $0 }
                ),
                in: range, step: 1
            ) { editing in
                if !editing, let value = values[setting] {
                    Task { await rig.setSetting(setting, to: Int(value)) }
                }
            }
            .accessibilityLabel(title)
        }
    }

    private func settingToggle(_ title: String,
                               _ setting: RigSetting) -> some View {
        let isOn = (values[setting] ?? 0) > 0
        return Button(title) {
            let newValue = isOn ? 0 : 1
            values[setting] = Double(newValue)
            Task { await rig.setSetting(setting, to: newValue) }
        }
        .font(.caption.weight(isOn ? .bold : .regular))
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .secondary)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
    }
}
