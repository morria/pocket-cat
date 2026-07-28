// One-tap band hopping. A chip tunes to the last frequency used on that
// band — band-stacking, as a modern rig does it — falling back to the
// radio's own BS register, then to the band plan.
//
// docs/rig-control-ux.md §4.1.

import CATBridgeKit
import FT891Kit
import SwiftUI

struct BandBar: View {
    @Environment(RigController.self) private var rig
    private var memory = StationMemory.shared
    @State private var haptic = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(BandPlan.all) { band in
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
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isCurrent ? Color.accentColor : Color.bandChipFill,
                            in: Capsule())
        }
        .buttonStyle(.plain)
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

    private var currentBand: Band? {
        rig.state?.frequency.flatMap { BandPlan.band(containing: $0.hertz) }
    }

    /// Last frequency on that band → the radio's own band register → the
    /// band plan's default.
    private func go(to band: Band) async {
        if let entry = memory.stackEntry(for: band) {
            rig.tune(to: entry.frequency)
            if let mode = entry.mode, mode != rig.state?.mode {
                await rig.setMode(mode)
            }
            return
        }
        if let catBand = band.catBand {
            await rig.selectBand(catBand)
            return
        }
        rig.tune(to: Frequency(hz: band.defaultHz))
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
