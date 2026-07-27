// Configuration profiles: capture the whole radio to an iCloud Drive file,
// compare a file against the live radio, and apply the difference —
// FTRestore's proven diff-before-write workflow, phone-native.

import FT891Kit
import SwiftUI

struct ProfilesView: View {
    @Environment(RigController.self) private var rig
    @State private var store = ProfileStore()
    @State private var profiles: [StoredProfile] = []
    @State private var showingSave = false
    @State private var storeLocation: ProfileStore.Location = .localFallback

    private var connected: Bool {
        if case .ready = rig.connectionPhase { return true }
        return false
    }

    var body: some View {
        List {
            if !connected {
                Section {
                    Label("Connect to the radio to save or apply profiles.",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(profiles) { stored in
                    NavigationLink {
                        ProfileDetailView(stored: stored,
                                          store: store,
                                          onChange: refresh)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stored.profile.name)
                            Text(stored.profile.savedAt,
                                 format: .dateTime.day().month().year()
                                     .hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet {
                            try? await store.delete(profiles[index])
                        }
                        await refresh()
                    }
                }
            } footer: {
                Text(storeLocation == .iCloud
                     ? "Stored in iCloud Drive — visible in the Files app."
                     : "iCloud unavailable — profiles are stored on this "
                       + "device only.")
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSave = true
                } label: {
                    Label("Save Current…", systemImage: "square.and.arrow.down")
                }
                .disabled(!connected)
            }
        }
        .sheet(isPresented: $showingSave) {
            SaveProfileSheet(onSaved: refresh)
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    @MainActor
    private func refresh() async {
        storeLocation = store.location
        profiles = (try? await store.list()) ?? []
    }
}

/// Runs the capture sweep with a determinate progress bar, then names and
/// saves the profile.
struct SaveProfileSheet: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss
    let onSaved: @MainActor () async -> Void

    @State private var name = ""
    @State private var notes = ""
    @State private var progress: ProfileProgress?
    @State private var captured: RadioProfile?
    @State private var errorText: String?
    @State private var captureTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. “FT8 Portable”)", text: $name)
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if let progress {
                    Section("Reading Radio") {
                        ProgressView(
                            value: Double(progress.completed),
                            total: Double(progress.total)
                        ) {
                            Text(progress.currentItem)
                                .font(.caption)
                        }
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save Configuration")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { start() }
                        .disabled(name.isEmpty || progress != nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        captureTask?.cancel()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(progress != nil)
        }
    }

    private func start() {
        guard let session = rig.session else { return }
        errorText = nil
        let profileName = name
        let profileNotes = notes
        captureTask = Task {
            do {
                var profile = try await ProfileEngine.capture(
                    from: session,
                    name: profileName,
                    savedAt: Date()
                ) { update in
                    Task { @MainActor in progress = update }
                }
                // Preserve any capture-generated notes (skipped items).
                profile.notes = [profileNotes, profile.notes]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let store = ProfileStore()
                try await store.save(profile)
                await onSaved()
                dismiss()
            } catch ProfileEngineError.frontPanelMenuActive {
                errorText = "The radio is in its front-panel menu — exit "
                    + "it on the radio, then try again."
            } catch is CancellationError {
                // user cancelled
            } catch {
                errorText = "Capture failed: \(error)"
            }
            progress = nil
        }
    }
}

struct ProfileDetailView: View {
    @Environment(RigController.self) private var rig
    let stored: StoredProfile
    let store: ProfileStore
    let onChange: @MainActor () async -> Void

    @State private var progress: ProfileProgress?
    @State private var diffs: [MenuDiff]?
    @State private var results: [ApplyResult]?
    @State private var errorText: String?
    @State private var showingApplyConfirm = false

    private var connected: Bool {
        if case .ready = rig.connectionPhase { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Saved",
                               value: stored.profile.savedAt.formatted())
                LabeledContent("Menu items",
                               value: "\(stored.profile.menu.count)")
                if let hz = stored.profile.operating.vfoAHz {
                    LabeledContent("VFO A", value: frequencyText(hz))
                }
                if !stored.profile.notes.isEmpty {
                    Text(stored.profile.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: stored.url) {
                    Label("Share Profile File",
                          systemImage: "square.and.arrow.up")
                }
            }

            if let progress {
                Section {
                    ProgressView(value: Double(progress.completed),
                                 total: Double(progress.total)) {
                        Text(progress.currentItem).font(.caption)
                    }
                }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let diffs {
                diffSection(diffs)
            } else if results == nil {
                Section {
                    Button {
                        compare()
                    } label: {
                        Label("Compare with Radio",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!connected || progress != nil)
                }
            }

            if let results {
                resultsSection(results)
            }
        }
        .navigationTitle(stored.profile.name)
        .confirmationDialog(
            "Apply \(diffs?.count ?? 0) changes to the radio?",
            isPresented: $showingApplyConfirm,
            titleVisibility: .visible
        ) {
            Button("Apply Changes", role: .destructive) { apply() }
        } message: {
            Text("Each change is written and read back to confirm. "
                 + "Operating state (frequency, mode, power) is set last.")
        }
    }

    @ViewBuilder
    private func diffSection(_ diffs: [MenuDiff]) -> some View {
        Section {
            if diffs.isEmpty {
                Label("Radio already matches this profile.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            ForEach(diffs) { diff in
                VStack(alignment: .leading, spacing: 2) {
                    Text(diff.item.friendlyName)
                        .font(.callout)
                    HStack(spacing: 6) {
                        Text(diff.currentValue.map {
                            diff.item.label(for: $0)
                        } ?? "?")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(diff.item.label(for: diff.newValue))
                            .foregroundStyle(.primary)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        } header: {
            Text(diffs.isEmpty ? "Differences" : "\(diffs.count) Differences")
        }
        if !diffs.isEmpty {
            Section {
                Button {
                    showingApplyConfirm = true
                } label: {
                    Label("Apply to Radio", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(progress != nil)
            }
        }
    }

    private func resultsSection(_ results: [ApplyResult]) -> some View {
        Section("Apply Results") {
            let failed = results.filter {
                if case .failed = $0.outcome { return true }
                return false
            }
            Label("\(results.count - failed.count) applied, "
                  + "\(failed.count) failed",
                  systemImage: failed.isEmpty
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                .foregroundStyle(failed.isEmpty ? .green : .orange)
            ForEach(failed) { result in
                if case let .failed(reason) = result.outcome {
                    VStack(alignment: .leading) {
                        Text(MenuCatalog.byID[result.itemID]?.friendlyName
                             ?? result.itemID)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func compare() {
        guard let session = rig.session else { return }
        errorText = nil
        Task {
            do {
                let found = try await ProfileEngine.diff(
                    stored.profile, against: session
                ) { update in
                    Task { @MainActor in progress = update }
                }
                diffs = found
            } catch {
                errorText = "Compare failed: \(error)"
            }
            progress = nil
        }
    }

    private func apply() {
        guard let session = rig.session, let pendingDiffs = diffs else {
            return
        }
        errorText = nil
        Task {
            do {
                let outcome = try await ProfileEngine.apply(
                    diffs: pendingDiffs,
                    operating: stored.profile.operating,
                    to: session
                ) { update in
                    Task { @MainActor in progress = update }
                }
                results = outcome
                diffs = nil
            } catch ProfileEngineError.frontPanelMenuActive {
                errorText = "The radio is in its front-panel menu — exit "
                    + "it on the radio, then try again."
            } catch {
                errorText = "Apply failed: \(error)"
            }
            progress = nil
        }
    }

    private func frequencyText(_ hz: UInt64) -> String {
        String(format: "%.6f MHz", Double(hz) / 1_000_000)
    }
}
