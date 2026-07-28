// App preferences — the things the phone owns, as opposed to the radio's
// own menu tree (that's MenuBrowserView).

import QMXKit
import SwiftUI

struct AppSettingsView: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared
    @State private var locator = GridLocator()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Callsign") {
                        TextField("M0ABC", text: $settings.callsign)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                    }
                    LabeledContent("Name") {
                        TextField("Andrew", text: $settings.operatorName)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                    }
                    LabeledContent("Location") {
                        TextField("London", text: $settings.qth)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                    }
                    LabeledContent("Grid") {
                        TextField("IO91wm", text: $settings.grid)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    Button {
                        Task {
                            if let grid = await locator.currentLocator() {
                                settings.grid = grid
                            }
                        }
                    } label: {
                        HStack {
                            Label("Use Current Location",
                                  systemImage: "location")
                            if locator.state == .locating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(locator.state == .locating)
                    if case .failed(let reason) = locator.state {
                        Label(reason, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Station")
                } footer: {
                    Text("Used by the CW message templates and the WSPR "
                         + "beacon. WSPR sends the first four characters of "
                         + "the grid.")
                }

                Section {
                    Toggle("Keep Screen Awake",
                           isOn: $settings.keepScreenAwake)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Stops the screen locking while the app is in the "
                         + "foreground. Costs battery — useful on a bench, "
                         + "less so in a pack.")
                }

                Section {
                    Toggle("Sync Clock on Connect",
                           isOn: $settings.syncClockOnConnect)
                    LabeledContent("Radio Clock", value: clockStatus)
                    Button("Sync Now") {
                        Task { await rig.syncClock() }
                    }
                    .disabled(rig.session == nil)
                } header: {
                    Text("Clock")
                } footer: {
                    Text("Sets the radio's clock to the phone's UTC time. "
                         + "The QMX keeps time of day only, and it drifts — "
                         + "digital modes care.")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var clockStatus: String {
        guard let synced = rig.lastClockSync else { return "Not synced" }
        let stamp = synced.formatted(date: .omitted, time: .shortened)
        guard let drift = rig.clockDriftSeconds else { return "Set \(stamp)" }
        if drift == 0 { return "Was exact · set \(stamp)" }
        let direction = drift > 0 ? "ahead" : "behind"
        return "Was \(abs(drift)) s \(direction) · set \(stamp)"
    }
}

// MARK: - Keep awake

extension View {
    /// Holds the display on while the app is foregrounded. The flag is
    /// cleared whenever the app leaves the foreground so a backgrounded app
    /// can never pin someone's screen on.
    func keepScreenAwake(_ enabled: Bool) -> some View {
        modifier(KeepScreenAwakeModifier(enabled: enabled))
    }
}

private struct KeepScreenAwakeModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: enabled) { apply() }
            .onChange(of: scenePhase) { apply() }
            .onAppear { apply() }
            .onDisappear { setIdleTimerDisabled(false) }
    }

    private func apply() {
        setIdleTimerDisabled(enabled && scenePhase == .active)
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

#Preview {
    AppSettingsView().environment(RigController())
}
