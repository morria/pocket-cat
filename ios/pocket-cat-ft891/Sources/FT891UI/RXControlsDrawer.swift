// Receive-chain controls, all via the library's typed RigSetting API.
// A regular always-visible section (matching the Passband section's
// header treatment) — it was the screen's only collapsed element, which
// read as arbitrary rather than intentional. Values load on appear.

import CATBridgeKit
import FT891Kit
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
                // FT-891 has IPO (0) / AMP (1) only.
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
