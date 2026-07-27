// Meter rendering: S-meter in RX, SWR/ALC/PO cluster in TX. Values are the
// radio's raw 0–255 units; S-unit mapping uses the community calibration
// (S9 ≈ 120) until bench calibration replaces it.

import FT891Kit
import SwiftUI

struct SMeterView: View {
    let raw: Int?

    var body: some View {
        VStack(spacing: 4) {
            MeterBar(fraction: fraction, tint: .green)
            HStack {
                Text("S")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sLabel)
                    .font(.caption.monospacedDigit().weight(.medium))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Signal strength")
        .accessibilityValue(sLabel)
    }

    private var fraction: Double {
        Double(min(raw ?? 0, 255)) / 255
    }

    private var sLabel: String {
        guard let raw, raw > 0 else { return "—" }
        if raw <= 120 {
            return "S\(max(1, raw * 9 / 120))"
        }
        let overDB = (raw - 120) * 60 / 135 // ≈ up to +60 dB
        return "S9+\(overDB)"
    }
}

struct TXMeterCluster: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        VStack(spacing: 8) {
            LabeledMeter(label: "PO", raw: rig.poMeter, tint: .blue)
            LabeledMeter(label: "SWR", raw: rig.swrMeter,
                         tint: swrTint(rig.swrMeter))
            LabeledMeter(label: "ALC", raw: rig.alcMeter, tint: .orange)
        }
    }

    private func swrTint(_ raw: Int?) -> Color {
        guard let raw else { return .gray }
        return raw > 96 ? .red : (raw > 64 ? .yellow : .green)
    }
}

struct LabeledMeter: View {
    let label: String
    let raw: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .frame(width: 34, alignment: .leading)
                .foregroundStyle(.secondary)
            MeterBar(fraction: Double(min(raw ?? 0, 255)) / 255, tint: tint)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(raw.map(String.init) ?? "no reading")
    }
}

/// Segmented bar with a peak-hold tick.
struct MeterBar: View {
    let fraction: Double
    let tint: Color

    @State private var peak: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(6, geometry.size.width * fraction))
                if peak > 0.02 {
                    Rectangle()
                        .fill(tint)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * peak)
                }
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.12), value: fraction)
        .onChange(of: fraction) { _, new in
            if new >= peak {
                peak = new
            } else {
                withAnimation(.easeOut(duration: 1.2)) { peak = new }
            }
        }
    }
}
