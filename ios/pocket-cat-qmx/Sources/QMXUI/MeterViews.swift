// Meter cluster: S-meter (dB) while receiving; measured power, SWR, and
// AGC while transmitting. All four are radio-reported (the QMX's PC power
// is a live measurement, not a setting).

import QMXKit
import SwiftUI

struct MeterCluster: View {
    @Environment(RigController.self) private var rig

    private var isTX: Bool { rig.state?.isTransmitting ?? false }

    var body: some View {
        VStack(spacing: 10) {
            if isTX {
                HStack(spacing: 16) {
                    meterTile("PO", value: rig.state?.power.map {
                        String(format: "%.1f W", $0)
                    } ?? "—")
                    meterTile("SWR", value: rig.swr.map {
                        String(format: "%.2f", $0)
                    } ?? "—")
                    meterTile("AGC", value: rig.agcDB.map { "\($0) dB" }
                              ?? "—")
                }
            } else {
                sMeterBar
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var sMeterBar: some View {
        let dB = rig.state?.sMeter ?? 0
        // Rough S-unit mapping: 6 dB per S-unit above the noise floor.
        let sUnits = min(Double(dB) / 6.0, 12)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("S")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(dB) dB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(.green.gradient)
                        .frame(width: geo.size.width
                               * max(0, min(sUnits / 12, 1)))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal meter")
        .accessibilityValue("\(dB) decibels")
    }

    private func meterTile(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }
}
