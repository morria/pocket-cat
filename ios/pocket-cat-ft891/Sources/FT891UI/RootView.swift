// App root: three tabs over one shared RigController, with a notice
// banner overlay and auto-reconnect to the last bridge on launch.

import FT891Kit
import SwiftUI

public struct RootView: View {
    @State private var rig = RigController()

    public init() {}

    public var body: some View {
        TabView {
            NavigationStack { OperateView() }
                .tabItem { Label("Operate", systemImage: "dial.medium") }
            NavigationStack { MenuSettingsView() }
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            NavigationStack { ProfilesView() }
                .tabItem {
                    Label("Profiles",
                          systemImage: "externaldrive.badge.icloud")
                }
        }
        .environment(rig)
        .overlay(alignment: .top) { NoticeStack(rig: rig) }
        .task {
            #if canImport(CoreBluetooth)
            if rig.lastBridgeID != nil {
                await rig.connectLast()
            }
            #endif
        }
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
