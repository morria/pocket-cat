// The full 159-item menu browser: grouped, searchable, with type-aware
// editors. Friendly names headline each row; the official Yaesu name and
// menu number ride along for cross-reference with the front panel.

import FT891Kit
import SwiftUI

struct MenuSettingsView: View {
    @Environment(RigController.self) private var rig
    @State private var searchText = ""
    @State private var editingItem: MenuItem?

    var body: some View {
        Group {
            if searchText.isEmpty {
                groupList
            } else {
                searchResults
            }
        }
        .navigationTitle("Menu Settings")
        .searchable(text: $searchText,
                    prompt: "Search settings, e.g. “notch” or “07-05”")
        .sheet(item: $editingItem) { item in
            MenuItemEditor(item: item)
                .presentationDetents([.medium])
        }
    }

    private var groupList: some View {
        List(MenuGroup.allCases) { group in
            NavigationLink {
                MenuGroupView(group: group, editingItem: $editingItem)
            } label: {
                LabeledContent(group.title) {
                    Text("\(MenuCatalog.items(in: group).count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchResults: some View {
        List(filteredItems) { item in
            MenuItemRow(item: item) { editingItem = item }
        }
    }

    private var filteredItems: [MenuItem] {
        let query = searchText.lowercased()
        return MenuCatalog.items.filter { item in
            item.friendlyName.lowercased().contains(query)
                || item.officialName.lowercased().contains(query)
                || item.summary.lowercased().contains(query)
                || item.id.contains(query)
        }
    }
}

struct MenuGroupView: View {
    @Environment(RigController.self) private var rig
    let group: MenuGroup
    @Binding var editingItem: MenuItem?

    var body: some View {
        List(MenuCatalog.items(in: group)) { item in
            MenuItemRow(item: item) { editingItem = item }
        }
        .navigationTitle(group.title)
        .task { await rig.loadMenuValues(in: group) }
    }
}

struct MenuItemRow: View {
    @Environment(RigController.self) private var rig
    let item: MenuItem
    let onTap: () -> Void

    var body: some View {
        Button(action: item.isWritable && !item.isAction ? onTap : {}) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.friendlyName)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(valueLabel)
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                }
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(item.id) · \(item.officialName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .task { await rig.loadMenuValue(item) }
        .accessibilityElement(children: .combine)
    }

    private var valueLabel: String {
        guard let value = rig.menuValues[item.id] else { return "—" }
        return item.label(for: value)
    }
}

/// Type-aware editor sheet. Writes through immediately with read-back
/// confirmation (RigController surfaces any mismatch as a notice).
struct MenuItemEditor: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss
    let item: MenuItem

    @State private var draft = 0
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    editor
                } header: {
                    Text(item.friendlyName)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.summary)
                        Text("Menu \(item.id) — \(item.officialName). "
                             + "Default: \(item.label(for: item.defaultValue))")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle(item.id)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset to Default") {
                        commit(item.defaultValue)
                    }
                    .disabled(draft == item.defaultValue)
                }
            }
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            draft = rig.menuValues[item.id] ?? item.defaultValue
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch item.kind {
        case .toggle:
            Toggle(item.friendlyName, isOn: Binding(
                get: { draft == 1 },
                set: { commit($0 ? 1 : 0) }
            ))
        case let .options(labels):
            Picker(item.friendlyName, selection: Binding(
                get: { draft },
                set: { commit($0) }
            )) {
                ForEach(labels.indices, id: \.self) { index in
                    Text(labels[index]).tag(index)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        case .number, .signedNumber:
            numberEditor
        }
    }

    private var numberEditor: some View {
        let range = item.kind.range
        let step = item.kind.step
        return VStack {
            HStack {
                Text(item.label(for: draft))
                    .font(.title3.monospacedDigit().weight(.medium))
                Spacer()
                Stepper("", value: Binding(
                    get: { draft },
                    set: { commit($0) }
                ), in: range, step: step)
                .labelsHidden()
            }
            if range.count <= 8_000 {
                Slider(
                    value: Binding(
                        get: { Double(draft) },
                        set: { draft = alignToStep(Int($0)) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                ) { editing in
                    if !editing { commit(draft) }
                }
            }
        }
    }

    private func alignToStep(_ value: Int) -> Int {
        let step = item.kind.step
        guard step > 1 else { return value }
        let lower = item.kind.range.lowerBound
        let aligned = lower + ((value - lower) / step) * step
        return min(max(aligned, lower), item.kind.range.upperBound)
    }

    private func commit(_ value: Int) {
        draft = value
        Task { await rig.writeMenuValue(item, value: value) }
    }
}
