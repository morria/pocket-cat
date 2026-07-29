// Connection status capsule + the scan/connect sheet.

import CATBridgeKit
import FTX1Kit
import SwiftUI

/// Compact status shown at the top of the Operate screen; tap to manage
/// the connection.
struct ConnectionStatusButton: View {
    @Environment(RigController.self) private var rig
    @State private var showingSheet = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSheet) { ConnectionSheet() }
        .accessibilityLabel("Connection: \(statusText)")
    }

    private var statusText: String {
        if rig.isSimulated, case .ready = rig.connectionPhase {
            return "Simulator"
        }
        switch rig.connectionPhase {
        case .idle: return "Not Connected"
        case .connecting: return "Connecting…"
        case .bridgeReady: return "Bridge Only — No Radio"
        case .identifyingRadio: return "Identifying Radio…"
        case .ready: return "FTX-1"
        case let .reconnecting(attempt): return "Reconnecting (\(attempt))…"
        case .failed: return "Connection Failed"
        }
    }

    private var statusColor: Color {
        switch rig.connectionPhase {
        case .ready: .green
        case .connecting, .identifyingRadio, .reconnecting: .yellow
        case .bridgeReady: .orange
        case .idle, .failed: .red
        }
    }
}

struct ConnectionSheet: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss

    /// Naming the phase turns "it just sits there" into something the
    /// operator can act on.
    private var phaseDescription: String {
        switch rig.connectionPhase {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .bridgeReady: "Bridge ready — probing the radio…"
        case .identifyingRadio: "Identifying radio…"
        case .ready: rig.isSimulated ? "Ready (simulated)" : "Ready"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))…"
        case .failed(let reason): "Failed — \(reason)"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Shown for any live session, not just a ready one: a
                // connection that stalls mid-handshake is exactly when
                // Disconnect is needed, and gating it on .ready left no
                // way out but forgetting the device in iOS Settings.
                if rig.session != nil {
                    Section {
                        LabeledContent("Radio", value: "Yaesu FTX-1")
                        LabeledContent("State", value: phaseDescription)
                        if let baud = rig.state?.bridge.baud, baud > 0 {
                            LabeledContent("CAT rate",
                                           value: "\(baud) baud")
                        }
                        Button("Disconnect", role: .destructive) {
                            Task {
                                await rig.disconnect()
                                dismiss()
                            }
                        }
                    }  footer: {
                        Text("Disconnecting also lets the bridge advertise "
                             + "again — it stays silent while connected.")
                    }
                }

                #if canImport(CoreBluetooth)
                Section {
                    if rig.discovered.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Scanning…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rig.discovered, id: \.id) { bridge in
                        Button {
                            Task {
                                await rig.connect(to: bridge)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Label(bridge.name ?? "Bridge",
                                      systemImage: "antenna.radiowaves.left.and.right")
                                Spacer()
                                if bridge.isAlreadyConnected {
                                    // Already connected to iOS, so it is
                                    // not advertising and has no RSSI.
                                    Text("Connected")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                } else if let rssi = bridge.rssi {
                                    Text("\(rssi) dB")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Nearby Bridges")
                } footer: {
                    Text("Bridges advertise as CATBridge-XXXX. Pairing is "
                         + "required on first connect. A bridge iOS is "
                         + "already connected to stops advertising, so it "
                         + "appears here as Connected rather than with a "
                         + "signal reading.")
                }
                #endif

                Section {
                    Button {
                        Task {
                            await rig.connectSimulator()
                            dismiss()
                        }
                    } label: {
                        Label("Simulated FTX-1",
                              systemImage: "waveform.path.ecg.rectangle")
                    }
                } footer: {
                    Text("A built-in radio simulator — explore the app "
                         + "with no hardware.")
                }
            }
            .navigationTitle("Connection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                #if canImport(CoreBluetooth)
                rig.startScanning()
                #endif
            }
            .onDisappear {
                #if canImport(CoreBluetooth)
                rig.stopScanning()
                #endif
            }
        }
    }
}
