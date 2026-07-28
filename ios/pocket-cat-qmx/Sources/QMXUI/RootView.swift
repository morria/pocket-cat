// App root: three tabs over one shared RigController, with a notice
// banner overlay and auto-reconnect to the last bridge on launch.

import QMXKit
import SwiftUI

public struct RootView: View {
    @State private var rig = RigController()
    @State private var settings = AppSettings.shared
    /// Owned here, not by the WSPR tab: a beacon must keep running — and
    /// keep being visible — when the operator looks at another screen.
    @State private var beacon = WSPRBeacon()

    public init() {}

    public var body: some View {
        TabView {
            NavigationStack { OperateView() }
                .tabItem { Label("Operate", systemImage: "dial.medium") }
            NavigationStack { SpectrumView() }
                .tabItem { Label("Spectrum", systemImage: "waveform") }
            NavigationStack { CWMessagesView() }
                .tabItem { Label("CW", systemImage: "text.bubble") }
            NavigationStack { WSPRView() }
                .tabItem {
                    Label("WSPR", systemImage: "dot.radiowaves.up.forward")
                }
            NavigationStack { MenuBrowserView() }
                .tabItem {
                    Label("Menu", systemImage: "slider.horizontal.3")
                }
            NavigationStack { ProfilesView() }
                .tabItem {
                    Label("Profiles",
                          systemImage: "externaldrive.badge.icloud")
                }
        }
        .environment(rig)
        .environment(beacon)
        .keepScreenAwake(settings.keepScreenAwake)
        .safeAreaInset(edge: .top, spacing: 0) { OnAirBar(rig: rig, beacon: beacon) }
        .overlay(alignment: .top) { NoticeStack(rig: rig) }
        .onChange(of: rig.session == nil) { _, gone in
            // Losing the radio must not leave a beacon believing it's live.
            if gone { Task { await beacon.stop() } }
        }
        .task {
            #if canImport(CoreBluetooth)
            if rig.lastBridgeID != nil {
                await rig.connectLast()
            }
            #endif
        }
    }
}

/// One app-wide transmit indicator.
///
/// Replaces the full-screen red border, which the device's rounded corners
/// clipped into four disconnected lines. A bar is legible, says *why* the
/// radio is keyed, and — unlike a border — can carry the stop control.
struct OnAirBar: View {
    let rig: RigController
    let beacon: WSPRBeacon

    private var isKeyed: Bool { rig.state?.isTransmitting ?? false }

    var body: some View {
        if isKeyed || beacon.isRunning {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(label)
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 0)
                if beacon.isRunning {
                    Button("Stop") { Task { await beacon.stop() } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.red)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.red)
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var label: String {
        if beacon.isRunning {
            if case .transmitting(let symbol) = beacon.phase {
                return "ON AIR · WSPR \(symbol + 1)/162"
            }
            return "WSPR beacon armed — waiting for the next slot"
        }
        return "ON AIR"
    }
}

/// Transient, dismissible notice banners (watchdog trips, errors).
struct NoticeStack: View {
    let rig: RigController

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rig.notices, id: \.self) { notice in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(notice)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        rig.dismissNotice(notice)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }
        }
        .animation(.snappy, value: rig.notices)
    }
}

#Preview {
    RootView()
}
