// Save / load complete radio configurations. Capture walks the radio's
// whole menu tree over CAT; apply writes only what differs, with
// read-back verification and per-item results.

import QMXKit
import SwiftUI

struct ProfilesView: View {
    @Environment(RigController.self) private var rig
    @State private var store = ProfileStore()
    @State private var stored: [StoredProfile] = []
    @State private var showingSave = false
    @State private var listError: String?

    private var connected: Bool {
        if case .ready = rig.connectionPhase { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                Button {
                    showingSave = true
                } label: {
                    Label("Save Current Configuration",
                          systemImage: "square.and.arrow.down")
                }
                .disabled(!connected)
            } footer: {
                Text("Reads every menu item plus the operating state off "
                     + "the radio into a file you can share, archive, or "
                     + "apply later.")
            }

            Section("Saved Profiles") {
                if stored.isEmpty {
                    Text(listError ?? "No profiles yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(stored) { item in
                    NavigationLink {
                        ProfileDetailView(stored: item,
                                          onChanged: { Task { await reload() } })
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.profile.name)
                            Text("\(item.profile.menu.count) settings · "
                                 + item.profile.savedAt.formatted(
                                    date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexes in
                    Task {
                        for index in indexes {
                            try? await store.delete(stored[index])
                        }
                        await reload()
                    }
                }
            }
        }
        .navigationTitle("Profiles")
        .sheet(isPresented: $showingSave) {
            SaveProfileSheet(store: store) { Task { await reload() } }
        }
        .task { await reload() }
    }

    private func reload() async {
        do {
            stored = try await store.list()
            listError = nil
        } catch {
            listError = String(describing: error)
        }
    }
}

struct SaveProfileSheet: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss
    let store: ProfileStore
    var onSaved: () -> Void

    @State private var name = ""
    @State private var progress: QMXProfileProgress?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Profile name", text: $name)
                if let progress {
                    LabeledContent("Reading",
                                   value: "\(progress.completed) · "
                                   + progress.currentItem)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .navigationTitle("Save Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await capture() } }
                        .disabled(name.isEmpty || progress != nil)
                }
            }
        }
    }

    private func capture() async {
        guard let session = rig.session else { return }
        progress = QMXProfileProgress(completed: 0, total: nil,
                                      currentItem: "starting…")
        do {
            let profile = try await ProfileEngine.capture(
                name: name, session: session) { update in
                Task { @MainActor in progress = update }
            }
            try await store.save(profile)
            dismiss()
            onSaved()
        } catch {
            errorText = String(describing: error)
            progress = nil
        }
    }
}

struct ProfileDetailView: View {
    @Environment(RigController.self) private var rig
    let stored: StoredProfile
    var onChanged: () -> Void

    @State private var diffs: [QMXMenuDiff]?
    @State private var results: [QMXApplyResult]?
    @State private var working = false
    @State private var confirmingApply = false

    private var connected: Bool {
        if case .ready = rig.connectionPhase { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Saved", value: stored.profile.savedAt
                    .formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Settings",
                               value: "\(stored.profile.menu.count)")
                if let firmware = stored.profile.firmwareVersion {
                    LabeledContent("Radio firmware", value: firmware)
                }
                ShareLink(item: stored.url) {
                    Label("Share File", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button("Compare with Radio") {
                    Task { await compare() }
                }
                .disabled(!connected || working)
                if let diffs {
                    if diffs.isEmpty {
                        Label("Radio matches this profile",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(diffs) { diff in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(diff.displayName)
                                Text("\(diff.currentValue ?? "—") → "
                                     + diff.newValue)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Apply \(diffs.count) Changes to Radio") {
                            confirmingApply = true
                        }
                        .disabled(working)
                    }
                }
            } footer: {
                Text("Apply writes each differing item to the radio's "
                     + "configuration memory, then verifies it.")
            }

            if let results {
                Section("Results") {
                    ForEach(results) { result in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.displayName)
                                if let detail = result.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: result.succeeded
                                  ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(result.succeeded
                                             ? .green : .red)
                        }
                    }
                }
            }
        }
        .overlay { if working { ProgressView() } }
        .navigationTitle(stored.profile.name)
        .confirmationDialog(
            "Write \(diffs?.count ?? 0) settings to the radio's EEPROM?",
            isPresented: $confirmingApply, titleVisibility: .visible
        ) {
            Button("Apply", role: .destructive) {
                Task { await apply() }
            }
        }
    }

    private func compare() async {
        guard let session = rig.session else { return }
        working = true
        defer { working = false }
        results = nil
        diffs = try? await ProfileEngine.diff(stored.profile,
                                              session: session)
    }

    private func apply() async {
        guard let session = rig.session, let diffs else { return }
        working = true
        defer { working = false }
        results = await ProfileEngine.apply(stored.profile, diffs: diffs,
                                            session: session)
        self.diffs = nil
        onChanged()
    }
}
