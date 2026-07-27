// The catalog-vs-documentation checker: parses docs/ft891-menus.md and
// asserts the Swift table agrees on item ids, EX numbers, digit counts,
// and the signed-item set — so the doc and the code cannot drift apart.

import Foundation
import Testing
@testable import FT891Kit

@Suite("MenuCatalog matches docs/ft891-menus.md")
struct MenuCatalogDocTests {
    struct DocRow {
        let id: String
        let officialName: String
        let digits: Int?
    }

    static func loadDocRows() throws -> [DocRow] {
        let docURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FT891KitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("docs/ft891-menus.md")
        let text = try String(contentsOf: docURL, encoding: .utf8)

        let idPattern = /^\| (\d{2}-\d{2}) \| ([^|]+) \|/
        let digitsPattern = /(\d+) digits?/
        var rows: [DocRow] = []
        for line in text.split(separator: "\n") {
            guard let match = try? idPattern.firstMatch(
                in: String(line)) else { continue }
            let cells = line.split(separator: "|",
                                   omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // cells[0] is empty (leading |); EX format is the last non-empty
            let exCell = cells.dropLast().last ?? ""
            let digits = (try? digitsPattern.firstMatch(in: exCell))
                .flatMap { Int($0.1) }
            rows.append(DocRow(
                id: String(match.1),
                officialName: match.2.trimmingCharacters(in: .whitespaces),
                digits: digits))
        }
        return rows
    }

    @Test func allDocItemsPresent() throws {
        let rows = try Self.loadDocRows()
        #expect(rows.count == 159)
        #expect(MenuCatalog.items.count == 159)

        let catalogIDs = Set(MenuCatalog.items.map(\.id))
        for row in rows {
            #expect(catalogIDs.contains(row.id),
                    "doc item \(row.id) missing from catalog")
        }
    }

    @Test func officialNamesMatch() throws {
        for row in try Self.loadDocRows() {
            guard let item = MenuCatalog.byID[row.id] else { continue }
            #expect(item.officialName == row.officialName,
                    "\(row.id): \(item.officialName) ≠ \(row.officialName)")
        }
    }

    @Test func digitCountsMatch() throws {
        for row in try Self.loadDocRows() {
            guard let item = MenuCatalog.byID[row.id],
                  let docDigits = row.digits else { continue }
            #expect(item.digits == docDigits,
                    "\(row.id): digits \(item.digits) ≠ doc \(docDigits)")
        }
    }

    @Test func signedSetMatchesDocNote3() {
        let expected: Set<String> = [
            "0513", "0517", "0803", "0804", "1202",
            "1502", "1505", "1508", "1511", "1514", "1517",
        ]
        let actual = Set(MenuCatalog.items.filter(\.isSigned)
            .map(\.exNumber))
        #expect(actual == expected)
    }

    @Test func writabilityRules() {
        for item in MenuCatalog.items(in: .version) {
            #expect(!item.isWritable, "\(item.id) must be read-only")
        }
        let reset = MenuCatalog.byID["17-01"]
        #expect(reset?.isAction == true)
        #expect(MenuCatalog.profileItems.count == 159 - 3 - 1)
    }

    @Test func exNumbersAreWellFormed() {
        for item in MenuCatalog.items {
            #expect(item.exNumber.count == 4)
            let allDigits = item.exNumber.allSatisfy(\.isNumber)
            #expect(allDigits)
            #expect(MenuCatalog.byEXNumber[item.exNumber]?.id == item.id)
        }
    }
}
