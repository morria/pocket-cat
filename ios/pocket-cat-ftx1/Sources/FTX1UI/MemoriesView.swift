// Saved memories and automatic recents, as an ordinary iOS list: tap to
// tune, swipe to delete, `+` stores where you are now.
//
// docs/rig-control-ux.md §4.2–4.3.

import CATBridgeKit
import FTX1Kit
import SwiftUI

struct MemoriesView: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss
    private var memory = StationMemory.shared

    @State private var renaming: MemoryChannel?
    @State private var draftName = ""
    @State private var haptic = 0

    var body: some View {
        NavigationStack {
            List {
                if !memory.recents.isEmpty {
                    Section {
                        ForEach(memory.recents) { channel in
                            row(channel, saved: false)
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear") { memory.clearRecents() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    } footer: {
                        Text("Where you've been, newest first. Kept "
                             + "automatically.")
                    }
                }

                ForEach(memory.channelsByBand, id: \.band) { group in
                    Section(group.band) {
                        ForEach(group.channels) { channel in
                            row(channel, saved: true)
                        }
                    }
                }

                if memory.channels.isEmpty && memory.recents.isEmpty {
                    ContentUnavailableView(
                        "No Memories",
                        systemImage: "bookmark",
                        description: Text("Tap + to keep the frequency "
                                          + "you're on."))
                }
            }
            .navigationTitle("Memories")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save Current", systemImage: "plus",
                           action: storeCurrent)
                        .disabled(rig.state?.frequency == nil)
                }
            }
            .alert("Rename", isPresented: .init(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let channel = renaming {
                        memory.rename(channel.id, to: draftName)
                    }
                    renaming = nil
                }
            }
            .sensoryFeedback(.selection, trigger: haptic)
        }
    }

    private func row(_ channel: MemoryChannel, saved: Bool) -> some View {
        Button {
            haptic += 1
            tune(to: channel)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .foregroundStyle(.primary)
                    Text(channel.displayFrequency
                         + (channel.mode.map { " · \(Self.label(for: $0))" }
                            ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent(channel) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if saved {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    memory.delete(channel.id)
                }
                Button("Rename", systemImage: "pencil") {
                    draftName = channel.name
                    renaming = channel
                }
                .tint(.indigo)
            } else {
                Button("Keep", systemImage: "bookmark") {
                    memory.store(hz: channel.hz, mode: channel.mode)
                }
                .tint(.accentColor)
            }
        }
    }

    private func isCurrent(_ channel: MemoryChannel) -> Bool {
        rig.state?.frequency?.hertz == channel.hz
    }

    private func tune(to channel: MemoryChannel) {
        rig.tune(to: channel.frequency)
        if let mode = channel.mode, mode != rig.state?.mode {
            Task { await rig.setMode(mode) }
        }
        dismiss()
    }

    private func storeCurrent() {
        guard let hz = rig.state?.frequency?.hertz else { return }
        haptic += 1
        memory.store(hz: hz, mode: rig.state?.mode)
    }

    static func label(for mode: OperatingMode) -> String {
        switch mode {
        case .lsb: "LSB"
        case .usb: "USB"
        case .cw: "CW"
        case .cwReverse: "CW-R"
        case .fm: "FM"
        case .fmNarrow: "FM-N"
        case .am: "AM"
        case .amNarrow: "AM-N"
        case .rtty: "RTTY"
        case .rttyReverse: "RTTY-R"
        case .dataLSB: "DATA-L"
        case .dataUSB: "DATA-U"
        case .dataFM: "DATA-FM"
        case .dataFMNarrow: "DATA-FM-N"
        case .c4fm: "C4FM"
        }
    }
}

#Preview {
    MemoriesView().environment(RigController())
}
