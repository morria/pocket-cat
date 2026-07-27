// The QMX configuration browser. The tree is discovered LIVE from the
// radio via the MM/ML Menu Manager, so it always matches the connected
// firmware; QMXMenuNotes overlays a written explanation for every item it
// knows. Values edit with type-aware controls; MM writes persist to the
// radio's EEPROM.

import QMXKit
import SwiftUI

struct MenuBrowserView: View {
    @Environment(RigController.self) private var rig
    @State private var roots: [QMXMenuNode] = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        List {
            if let note = groupNote {
                Section { } footer: { Text(note) }
            }
            ForEach(roots) { node in
                MenuNodeRow(node: node)
            }
            if roots.isEmpty && !loading {
                ContentUnavailableView(
                    loadError ?? "Connect to a QMX to browse its menu.",
                    systemImage: "slider.horizontal.3")
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Menu")
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
        .onChange(of: rig.connectionPhase) { _, phase in
            if case .ready = phase { Task { await load(force: true) } }
        }
    }

    private var groupNote: String? {
        roots.isEmpty
            ? nil
            : "Everything below is read live from the radio. Changes save "
              + "to the QMX's configuration memory immediately."
    }

    private func load(force: Bool) async {
        guard force || roots.isEmpty else { return }
        guard let session = rig.session,
              case .ready = rig.connectionPhase else { return }
        loading = true
        defer { loading = false }
        do {
            roots = try await QMXMenuClient(session: session).children()
            loadError = nil
        } catch {
            loadError = "Menu discovery failed: \(error)"
        }
    }
}

/// One row: leaf values edit in place, submenus push a child list.
struct MenuNodeRow: View {
    @Environment(RigController.self) private var rig
    let node: QMXMenuNode

    var body: some View {
        switch node.kind {
        case .submenu:
            NavigationLink {
                MenuChildrenView(parent: node)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                    if let note = QMXMenuNotes.note(
                        forPath: node.displayPath) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        case .action:
            Label(node.name, systemImage: "bolt.circle")
                .foregroundStyle(.secondary)
        case .info, .string, .number, .byte, .list, .mask:
            NavigationLink {
                MenuLeafView(node: node)
            } label: {
                LeafRowLabel(node: node)
            }
        }
    }
}

struct LeafRowLabel: View {
    @Environment(RigController.self) private var rig
    let node: QMXMenuNode
    @State private var value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(node.name)
                Spacer()
                Text(value ?? "…")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            if let note = QMXMenuNotes.note(forPath: node.displayPath) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .task {
            guard value == nil, node.columns == nil,
                  let session = rig.session else { return }
            value = try? await QMXMenuClient(session: session)
                .value(of: node)
        }
    }
}

struct MenuChildrenView: View {
    @Environment(RigController.self) private var rig
    let parent: QMXMenuNode
    @State private var children: [QMXMenuNode] = []
    @State private var loading = false

    var body: some View {
        List {
            if let note = QMXMenuNotes.note(forPath: parent.displayPath) {
                Section { } footer: { Text(note) }
            }
            ForEach(children) { node in
                MenuNodeRow(node: node)
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(parent.name)
        .task {
            guard children.isEmpty, let session = rig.session else { return }
            loading = true
            defer { loading = false }
            children = (try? await QMXMenuClient(session: session)
                .children(of: parent)) ?? []
        }
    }
}

/// Full-screen editor for one leaf: explanation on top, then a type-aware
/// control (grid leaves show one editor per column/band).
struct MenuLeafView: View {
    @Environment(RigController.self) private var rig
    let node: QMXMenuNode

    @State private var values: [Int?: String] = [:]
    @State private var options: [String] = []
    @State private var draft = ""
    @State private var savingColumn: Int??
    @State private var message: String?

    private var columns: [Int?] {
        node.columns.map { (0..<$0).map(Optional.some) } ?? [nil]
    }

    var body: some View {
        Form {
            Section {
                Text(QMXMenuNotes.note(forPath: node.displayPath)
                     ?? QMXMenuNotes.fallback)
                .font(.callout)
            }
            ForEach(columns, id: \.self) { column in
                Section(columnTitle(column)) {
                    editor(for: column)
                }
            }
            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(node.name)
        .task { await load() }
    }

    private func columnTitle(_ column: Int?) -> String {
        guard let column else { return "Value" }
        return "Column \(column)" // band index within Band config.
    }

    @ViewBuilder
    private func editor(for column: Int?) -> some View {
        let current = values[column] ?? nil
        switch node.kind {
        case .list, .mask:
            Picker(node.name, selection: Binding(
                get: { current ?? "" },
                set: { new in Task { await save(new, column: column) } }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        case .info:
            Text(current ?? "—")
                .font(.callout.monospacedDigit())
        default:
            HStack {
                TextField("Value", text: Binding(
                    get: { current ?? "" },
                    set: { values[column] = $0 }
                ))
                #if os(iOS)
                .keyboardType(node.kind == .string ? .default : .numberPad)
                #endif
                .font(.callout.monospacedDigit())
                Button("Save") {
                    Task { await save(values[column] ?? "" ?? "",
                                      column: column) }
                }
                .disabled(savingColumn != nil)
            }
        }
    }

    private func load() async {
        guard let session = rig.session else { return }
        let client = QMXMenuClient(session: session)
        for column in columns where values[column] == nil {
            values[column] = try? await client.value(of: node,
                                                     column: column)
        }
        if node.kind == .list || node.kind == .mask {
            options = (try? await client.listOptions(for: node)) ?? []
        }
    }

    private func save(_ newValue: String, column: Int?) async {
        guard let session = rig.session else { return }
        savingColumn = column
        defer { savingColumn = nil }
        let client = QMXMenuClient(session: session)
        do {
            try await client.setValue(newValue, of: node, column: column)
            let readback = try await client.value(of: node, column: column)
            values[column] = readback
            message = readback == newValue
                ? nil
                : "Radio kept \(readback)."
        } catch {
            message = "Write failed: \(error)"
        }
    }
}
