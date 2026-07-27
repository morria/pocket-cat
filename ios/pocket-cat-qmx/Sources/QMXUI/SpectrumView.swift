// Panadapter: live trace + scrolling waterfall fed by the bridge's
// SPECTRUM stream (docs/qmx-panadapter.md §6). The app owns the axis —
// frames carry only a sample rate; frequency labels come from the VFO
// (± RIT) the app already tracks. History clears on QSY, the display
// blanks during TX, and streaming stops when the app leaves the
// foreground (it is the bridge's battery being spent).

import CATBridgeKit
import CoreGraphics
import QMXKit
import SwiftUI

struct SpectrumView: View {
    @Environment(RigController.self) private var rig
    @Environment(\.scenePhase) private var scenePhase
    @State private var waterfall = WaterfallStore()
    @State private var lastCentreHz: UInt64?

    private var isTX: Bool { rig.state?.isTransmitting ?? false }

    private var centreHz: UInt64 {
        let vfo = rig.state?.frequency?.hertz ?? 0
        let rit = rig.ritEnabled ? Int64(rig.ritOffset) : 0
        return UInt64(max(0, Int64(vfo) + rit))
    }

    var body: some View {
        VStack(spacing: 10) {
            switch rig.spectrumSupported {
            case .none:
                ContentUnavailableView("Checking bridge…",
                                       systemImage: "waveform")
            case .some(false):
                ContentUnavailableView(
                    "This bridge's firmware has no spectrum support — "
                    + "reflash it to enable the panadapter.",
                    systemImage: "waveform.slash")
            case .some(true):
                controls
                if rig.panadapterActive {
                    display
                } else {
                    ContentUnavailableView(
                        "Panadapter is off.", systemImage: "waveform")
                }
            }
        }
        .padding()
        .navigationTitle("Spectrum")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionStatusButton() }
        }
        .task {
            if rig.spectrumSupported == nil { await rig.probePanadapter() }
        }
        .onChange(of: rig.latestSpectrum) { _, frame in
            guard let frame, !isTX else { return }
            // QSY: rows captured at the old frequency would lie — clear.
            if let last = lastCentreHz, last != centreHz {
                waterfall.clear()
            }
            lastCentreHz = centreHz
            waterfall.push(frame.bins)
        }
        .onChange(of: scenePhase) { _, phase in
            // A background waterfall only drains the bridge's cell.
            if phase != .active, rig.panadapterActive {
                Task { await rig.stopPanadapter() }
            }
        }
        .onDisappear {
            if rig.panadapterActive {
                Task { await rig.stopPanadapter() }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { rig.panadapterActive },
                set: { on in
                    Task {
                        if on {
                            await rig.startPanadapter()
                        } else {
                            await rig.stopPanadapter()
                        }
                    }
                }
            )) {
                Label("Panadapter", systemImage: "waveform")
            }
            .toggleStyle(.switch)
            Text("While on, the QMX streams raw I/Q instead of USB "
                 + "audio (Q9). It reverts automatically at power-off.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var display: some View {
        if isTX {
            ContentUnavailableView("Transmitting — spectrum paused.",
                                   systemImage: "antenna.radiowaves.left.and.right")
                .frame(maxHeight: 200)
        } else if let frame = rig.latestSpectrum {
            VStack(spacing: 4) {
                TraceView(frame: frame)
                    .frame(height: 130)
                axisLabels(frame: frame)
                WaterfallView(store: waterfall)
                    .frame(maxHeight: .infinity)
                if rig.spectrumFramesLost > 0 {
                    Text("\(rig.spectrumFramesLost) frames dropped "
                         + "(link busy — CAT has priority)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView("Waiting for frames…")
        }
    }

    private func axisLabels(frame: SpectrumFrame) -> some View {
        let half = Double(frame.sampleRateHz) / 2.0
        let centre = Double(centreHz)
        func label(_ hz: Double) -> String {
            String(format: "%.3f", hz / 1_000_000.0)
        }
        return HStack {
            Text(label(centre - half))
            Spacer()
            Text(label(centre) + " MHz")
                .fontWeight(.medium)
            Spacer()
            Text(label(centre + half))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// Live trace: one Canvas path per frame — well within budget at
/// 256 bins × 15 fps (plan §6).
struct TraceView: View {
    let frame: SpectrumFrame

    var body: some View {
        Canvas { context, size in
            let bins = frame.bins
            guard bins.count > 1 else { return }
            var path = Path()
            for (i, value) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                // 0 = full scale at the top; 255 = floor at the bottom.
                let y = size.height * CGFloat(value) / 255.0
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(.green), lineWidth: 1.5)
            // Centre line = the tuned frequency (bin N/2 is DC).
            let cx = size.width / 2
            context.stroke(
                Path { $0.move(to: CGPoint(x: cx, y: 0))
                       $0.addLine(to: CGPoint(x: cx, y: size.height)) },
                with: .color(.red.opacity(0.4)), lineWidth: 1)
        }
        .background(.black.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Waterfall history as a pixel buffer → CGImage per frame; rows shift
/// instead of redrawing (the cheap approach the plan calls for).
@Observable
final class WaterfallStore {
    static let maxRows = 160
    private(set) var image: CGImage?
    private var rows: [[UInt8]] = []

    func clear() {
        rows.removeAll()
        image = nil
    }

    func push(_ bins: [UInt8]) {
        rows.insert(bins, at: 0)
        if rows.count > Self.maxRows {
            rows.removeLast()
        }
        render()
    }

    private func render() {
        guard let width = rows.first?.count, width > 0 else { return }
        var pixels = [UInt8](repeating: 0,
                             count: width * rows.count * 4)
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() where row.count == width {
                let (red, green, blue) = Self.colour(for: value)
                let o = (r * width + c) * 4
                pixels[o] = red
                pixels[o + 1] = green
                pixels[o + 2] = blue
                pixels[o + 3] = 255
            }
        }
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        image = CGImage(
            width: width, height: rows.count, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    /// Classic blue→yellow→white heat map over the dBFS byte
    /// (0 = strongest).
    static func colour(for value: UInt8) -> (UInt8, UInt8, UInt8) {
        let strength = 255 - Int(value) // 0 quiet … 255 loud
        switch strength {
        case ..<64:
            return (0, 0, UInt8(40 + strength * 2))
        case ..<160:
            let t = strength - 64
            return (UInt8(t * 2), UInt8(t), UInt8(168 - t))
        default:
            let t = min(strength - 160, 95)
            return (UInt8(192 + t / 2), UInt8(96 + t), UInt8(t))
        }
    }
}

struct WaterfallView: View {
    let store: WaterfallStore

    var body: some View {
        GeometryReader { geo in
            if let image = store.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
