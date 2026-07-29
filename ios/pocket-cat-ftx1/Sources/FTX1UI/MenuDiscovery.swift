// Discovering the radio's menu instead of shipping a catalog of it.
//
// The FT-891 app knows its 159 items because someone typed them in. This
// repo has no verified FTX-1 catalog, and a borrowed one writes the wrong
// setting — so the app asks the radio: walk `EX` numbers, keep the ones it
// answers, discard the ones it rejects with `?;`. The QMX app does the
// same thing over `MM`; this is the Yaesu equivalent, just slower because
// there is no tree to walk.

import CATBridgeKit
import FTX1Kit
import Foundation
import Observation

@MainActor
@Observable
final class MenuDiscovery {
    struct Item: Identifiable, Codable, Equatable {
        var number: String
        var value: String
        var id: String { number }

        /// "12-03" reads the way the radio's own menu prints it.
        var displayNumber: String {
            let group = number.prefix(2)
            let item = number.suffix(2)
            return "\(group)-\(item)"
        }
    }

    private(set) var items: [Item] = Item.load()
    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var lastScan: Date?

    private var task: Task<Void, Never>?

    /// Menu groups on this family run 01…20; each group's items are
    /// numbered from 01. Scanning a group is ~99 round trips, so it is
    /// offered per group rather than as one long sweep.
    static let groups = Array(1...20)

    func scan(group: Int, rig: RigController) {
        guard task == nil else { return }
        isScanning = true
        progress = 0
        task = Task { [weak self] in
            defer {
                self?.task = nil
                self?.isScanning = false
                self?.progress = 0
            }
            var found: [Item] = []
            for item in 1...99 {
                if Task.isCancelled { break }
                let number = String(format: "%02d%02d", group, item)
                if let value = try? await rig.readMenuDigits(number) {
                    found.append(Item(number: number, value: value))
                }
                self?.progress = Double(item) / 99
            }
            guard let self else { return }
            // Replace this group's entries, leave other groups alone.
            let prefix = String(format: "%02d", group)
            var merged = self.items.filter { !$0.number.hasPrefix(prefix) }
            merged.append(contentsOf: found)
            merged.sort { $0.number < $1.number }
            self.items = merged
            self.lastScan = Date()
            Item.save(merged)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    func update(_ number: String, to value: String) {
        guard let index = items.firstIndex(where: { $0.number == number })
        else { return }
        items[index].value = value
        Item.save(items)
    }

    func forget() {
        items.removeAll()
        Item.save(items)
    }

    var groupsFound: [Int] {
        Set(items.compactMap { Int($0.number.prefix(2)) }).sorted()
    }

    func items(inGroup group: Int) -> [Item] {
        let prefix = String(format: "%02d", group)
        return items.filter { $0.number.hasPrefix(prefix) }
    }
}

extension MenuDiscovery.Item {
    private static let key = "ftx1.discoveredMenu"

    static func load() -> [MenuDiscovery.Item] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MenuDiscovery.Item].self,
                                                   from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [MenuDiscovery.Item]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
