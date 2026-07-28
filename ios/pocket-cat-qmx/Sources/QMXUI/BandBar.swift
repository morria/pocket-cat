// One-tap band hopping. A chip tunes to the last frequency used on that
// band — band-stacking, as a modern rig does it — falling back to the band
// plan. The QMX has no band-select command, so the register is entirely
// device-side.
//
// docs/rig-control-ux.md §4.1.

import CATBridgeKit
import QMXKit
import SwiftUI

struct BandBar: View {
    @Environment(RigController.self) private var rig
    private var memory = StationMemory.shared
    @State private var haptic = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(bands) { band in
                        chip(for: band)
                            .id(band.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentBand?.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                guard let id = currentBand?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .sensoryFeedback(.selection, trigger: haptic)
    }

    private func chip(for band: Band) -> some View {
        let isCurrent = band.id == currentBand?.id
        return Button {
            haptic += 1
            Task { await go(to: band) }
        } label: {
            Text(band.title)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)          // HIG minimum target
                .background(isCurrent ? Color.accentColor : Color.bandChipFill,
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .contextMenu {
            ForEach(band.segments) { segment in
                Button("\(segment.name) — \(Self.mhz(segment.hz))") {
                    haptic += 1
                    rig.tune(to: Frequency(hz: segment.hz))
                }
            }
            Divider()
            Button("Save Current Here", systemImage: "pin") {
                guard let hz = rig.state?.frequency?.hertz else { return }
                memory.noteVisit(hz: hz, mode: rig.state?.mode)
            }
            if let entry = memory.stackEntry(for: band) {
                Text("Last: \(Self.mhz(entry.hz))")
            }
        }
        .accessibilityLabel("\(band.title) band")
        .accessibilityHint(memory.stackEntry(for: band)
            .map { "Returns to \(Self.mhz($0.hz)) megahertz" }
            ?? "Tunes to the band's default frequency")
    }

    /// Only the bands this radio has, once it has told us. Until then,
    /// every band — hiding one the operator actually owns is worse than
    /// showing one they don't.
    private var bands: [Band] {
        guard let supported = rig.supportedBands, !supported.isEmpty else {
            return BandPlan.all
        }
        let planned = supported.planBands
        return planned.isEmpty ? BandPlan.all : planned
    }

    private var currentBand: Band? {
        rig.state?.frequency.flatMap { BandPlan.band(containing: $0.hertz) }
    }

    /// Last frequency on that band, or the band plan's default.
    private func go(to band: Band) async {
        if let entry = memory.stackEntry(for: band) {
            rig.tune(to: entry.frequency)
            // The QMX only has four modes; anything else in the register
            // is left alone rather than forced onto the radio.
            if let mode = entry.mode, mode != rig.state?.mode,
               let qmx = QMXMode(operatingMode: mode) {
                await rig.setMode(qmx)
            }
            return
        }
        // The radio's own configured centre for the band beats the plan's
        // generic default — it is where this unit is set up to land.
        let centre = rig.supportedBands?.entry(for: band)?.centerHz
        rig.tune(to: Frequency(hz: centre ?? band.defaultHz))
    }

    static func mhz(_ hz: UInt64) -> String {
        String(format: "%.3f", Double(hz) / 1_000_000)
    }
}

extension Color {
    static var bandChipFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemFill)
        #else
        Color.secondary.opacity(0.18)
        #endif
    }
}
