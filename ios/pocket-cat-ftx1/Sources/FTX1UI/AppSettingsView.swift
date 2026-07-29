// App preferences — the things the phone owns, as opposed to the radio's
// menu items (that's MenuBrowserView).

import FTX1Kit
import SwiftUI

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared

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
                    }
                    LabeledContent("Location") {
                        TextField("London", text: $settings.qth)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Grid") {
                        TextField("IO91wm", text: $settings.grid)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Station")
                } footer: {
                    Text("Fills the {CALL}, {NAME}, {QTH} and {GRID} "
                         + "placeholders in the CW templates.")
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
            }
            .navigationTitle("App Settings")
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
    AppSettingsView()
}
