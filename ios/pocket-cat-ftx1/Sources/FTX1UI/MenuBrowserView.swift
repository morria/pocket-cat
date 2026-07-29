// Raw menu access by EX number.
//
// The FT-891 app browses a typed catalog of its 159 menu items. The FTX-1's
// numbering is different and this repo has no verified catalog for it
// (esp32s3/docs/references/yaesu-cat-ftx1.md), so this reads and writes by
// number instead of pretending to know what each item means. Bookmarks let
// an operator build their own list as they learn the radio.

import CATBridgeKit
import FTX1Kit
import SwiftUI

struct MenuBrowserView: View {
    @Environment(RigController.self) private var rig
    @State private var number = ""
    @State private var value = ""
    @State private var reading = false
    @State private var status: String?
    @State private var bookmarks: [MenuBookmark] = MenuBookmark.load()
    @State private var discovery = MenuDiscovery()
    @State private var scanGroup = 1

    var body: some View {
        Form {
            Section {
                LabeledContent("Menu number") {
                    TextField("0506", text: $number)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                LabeledContent("Value") {
                    TextField("—", text: $value)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                HStack {
                    Button("Read", action: read)
                        .disabled(!isNumberValid || rig.session == nil)
                    Spacer()
                    Button("Write", action: write)
                        .disabled(!isNumberValid || value.isEmpty
                                  || rig.session == nil)
                    if reading { ProgressView() }
                }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.hasPrefix("Rejected")
                                         ? .orange : .secondary)
                }
            } header: {
                Text("EX menu")
            } footer: {
                Text("Four-digit item number, as printed in the FTX-1 CAT "
                     + "manual. Values are the radio's raw digits — it "
                     + "rejects anything out of range rather than clamping.")
            }

            Section {
                Picker("Group", selection: $scanGroup) {
                    ForEach(MenuDiscovery.groups, id: \.self) { group in
                        Text(String(format: "%02d", group)).tag(group)
                    }
                }
                if discovery.isScanning {
                    HStack {
                        ProgressView(value: discovery.progress)
                        Button("Stop") { discovery.cancel() }
                    }
                } else {
                    Button("Scan Group \(String(format: "%02d", scanGroup))",
                           systemImage: "magnifyingglass") {
                        discovery.scan(group: scanGroup, rig: rig)
                    }
                    .disabled(rig.session == nil)
                }
            } header: {
                Text("Discover")
            } footer: {
                Text("Asks the radio for every item in a group and keeps "
                     + "the ones it answers. About 99 questions per group, "
                     + "so it takes a few seconds — but the result is this "
                     + "radio's real menu rather than another radio's.")
            }

            ForEach(discovery.groupsFound, id: \.self) { group in
                Section("Group \(String(format: "%02d", group))") {
                    ForEach(discovery.items(inGroup: group)) { item in
                        Button {
                            number = item.number
                            value = item.value
                            read()
                        } label: {
                            LabeledContent(item.displayNumber,
                                           value: item.value)
                        }
                    }
                }
            }

            Section {
                NavigationLink("CAT Console") { CATConsoleView() }
            } footer: {
                Text("Send raw commands and read the replies — how an "
                     + "unknown format gets pinned down.")
            }

            Section {
                if bookmarks.isEmpty {
                    Text("Save an item after reading it to build your own "
                         + "list.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(bookmarks) { bookmark in
                    Button {
                        number = bookmark.number
                        read()
                    } label: {
                        LabeledContent(bookmark.name, value: bookmark.number)
                    }
                }
                .onDelete { offsets in
                    bookmarks.remove(atOffsets: offsets)
                    MenuBookmark.save(bookmarks)
                }
                Button("Save Current Item", systemImage: "bookmark") {
                    guard isNumberValid else { return }
                    bookmarks.append(MenuBookmark(number: number,
                                                  name: "Menu \(number)"))
                    MenuBookmark.save(bookmarks)
                }
                .disabled(!isNumberValid)
            } header: {
                Text("Bookmarks")
            }
        }
        .navigationTitle("Menu")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionStatusButton() }
        }
    }

    private var isNumberValid: Bool {
        number.count == 4 && number.allSatisfy(\.isNumber)
    }

    private func read() {
        reading = true
        status = nil
        Task {
            defer { reading = false }
            do {
                value = try await rig.readMenuDigits(number)
                status = "Read \(number) = \(value)"
            } catch {
                status = "Rejected — the radio doesn't know item \(number)"
            }
        }
    }

    private func write() {
        reading = true
        status = nil
        Task {
            defer { reading = false }
            do {
                try await rig.writeMenuDigits(number, digits: value)
                status = "Wrote \(number) = \(value)"
            } catch {
                status = "Rejected — \(value) is out of range for \(number)"
            }
        }
    }
}

/// An operator-built list of the menu numbers they care about.
struct MenuBookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var number: String
    var name: String

    private static let key = "ftx1.menuBookmarks"

    static func load() -> [MenuBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MenuBookmark].self,
                                                   from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [MenuBookmark]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

#Preview {
    NavigationStack { MenuBrowserView() }.environment(RigController())
}
