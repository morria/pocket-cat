// Client for the QMX's MM/ML Menu Manager (CAT manual fw 1_02_006):
// the radio's ENTIRE configuration menu is discoverable and editable over
// CAT. Discovery:  MM<path>|<i>?;  →  MM<type>|<meta>|<name>;
// Get: MM<path>;  →  MM<value>;      Set: MM<path>=<value>;  (EEPROM!)
// List options: ML<listType>;  →  ML<a>|<b>|…;
//
// Paths are |-delimited names (case-insensitive) or numeric indexes. Items
// whose NAME is numeric (CW filter rows) can only be addressed by index —
// so every node carries both a display path and a wire path.

import CATBridgeKit
import Foundation

public struct QMXMenuNode: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Sendable {
        case submenu = 0
        case action = 1     // application/action item
        case string = 2     // meta = field length
        case number = 3     // meta = field length
        case byte = 4       // 0…255
        case list = 5       // meta = list type (query options via ML)
        case info = 6       // display-only
        case mask = 7       // row of named booleans; meta = list type
    }

    /// Human path from the root, e.g. ["CW", "CW Keyer", "Keyer mode"].
    public var displayPath: [String]
    /// Path components to put on the wire — numeric-named items use their
    /// index (the radio would misparse the name as an index).
    public var wirePath: [String]
    public var name: String
    public var kind: Kind
    /// Field length (string/number) or list type (list/mask).
    public var meta: Int
    /// Grid pages (e.g. `Band config.[16]`): number of columns.
    public var columns: Int?

    public var id: String { displayPath.joined(separator: "|") }
    public var isEditable: Bool {
        switch kind {
        case .string, .number, .byte, .list, .mask: true
        case .submenu, .action, .info: false
        }
    }
}

public enum QMXMenuError: Error, Equatable {
    case malformedReply(String)
    case notAValue(String)   // get on a submenu/action
    case rejected(String)    // radio answered ?;
}

/// Stateless protocol driver; every call is one CAT round trip through the
/// session actor (which serializes against polling and user commands).
public struct QMXMenuClient: Sendable {
    private let session: TransceiverSession

    public init(session: TransceiverSession) {
        self.session = session
    }

    // MARK: - Discovery

    /// Children of a submenu (root when `parent` is nil). Walks indexes
    /// until the radio rejects the next one.
    public func children(of parent: QMXMenuNode? = nil) async throws
        -> [QMXMenuNode] {
        var out: [QMXMenuNode] = []
        for index in 0..<512 {
            let prefix = parent.map { wirePath($0.wirePath) + "|" } ?? ""
            let wire = "MM\(prefix)\(index)?;"
            let reply: String?
            do {
                reply = try await session.rawCommand(wire, expectsReply: true,
                                                     isIdempotent: true)
            } catch CATBridgeError.radioRejected {
                break // one past the last child
            }
            guard let reply else { break }
            guard var node = Self.parseDiscovery(
                reply: reply, index: index, parent: parent) else {
                throw QMXMenuError.malformedReply(reply)
            }
            // Rows of a grid page (Band config.[16]) inherit the page's
            // column count — the rows' own discovery replies don't carry it.
            if node.columns == nil, node.kind != .submenu,
               let inherited = parent?.columns {
                node.columns = inherited
            }
            out.append(node)
        }
        return out
    }

    static func parseDiscovery(reply: String, index: Int,
                               parent: QMXMenuNode?) -> QMXMenuNode? {
        // MM<type>|<meta>|<name>;
        guard reply.hasPrefix("MM"), reply.hasSuffix(";") else { return nil }
        let body = String(reply.dropFirst(2).dropLast())
        let parts = body.split(separator: "|", maxSplits: 2,
                               omittingEmptySubsequences: false)
        guard parts.count == 3,
              let rawKind = Int(parts[0]),
              let kind = QMXMenuNode.Kind(rawValue: rawKind),
              let meta = Int(parts[1])
        else { return nil }

        var name = String(parts[2])
        var columns: Int?
        // Grid pages report as "Band config.[16]".
        if name.hasSuffix("]"),
           let open = name.lastIndex(of: "["),
           let count = Int(name[name.index(after: open)..<name.index(
            before: name.endIndex)]) {
            columns = count
            name = String(name[..<open])
        }

        // Numeric names (CW filter rows) MUST go on the wire as indexes.
        let wireComponent = name.allSatisfy(\.isNumber) ? "\(index)" : name
        return QMXMenuNode(
            displayPath: (parent?.displayPath ?? []) + [name],
            wirePath: (parent?.wirePath ?? []) + [wireComponent],
            name: name,
            kind: kind,
            meta: meta,
            columns: columns)
    }

    // MARK: - Values

    /// Read a leaf's value. Grid cells pass their column subscript.
    public func value(of node: QMXMenuNode, column: Int? = nil) async throws
        -> String {
        guard node.isEditable || node.kind == .info else {
            throw QMXMenuError.notAValue(node.id)
        }
        let wire = "MM\(wirePath(node.wirePath, column: column));"
        do {
            guard let reply = try await session.rawCommand(
                wire, expectsReply: true, isIdempotent: true),
                reply.hasPrefix("MM"), reply.hasSuffix(";")
            else { throw QMXMenuError.malformedReply(wire) }
            return String(reply.dropFirst(2).dropLast())
        } catch CATBridgeError.radioRejected {
            throw QMXMenuError.rejected(node.id)
        }
    }

    /// Write a leaf's value. ⚠️ MM sets persist to the radio's EEPROM.
    public func setValue(_ value: String, of node: QMXMenuNode,
                         column: Int? = nil) async throws {
        guard node.isEditable else { throw QMXMenuError.notAValue(node.id) }
        guard !value.contains(";"), !value.contains("=") else {
            throw QMXMenuError.malformedReply(value)
        }
        let wire = "MM\(wirePath(node.wirePath, column: column))=\(value);"
        do {
            _ = try await session.rawCommand(wire, expectsReply: false)
        } catch CATBridgeError.radioRejected {
            throw QMXMenuError.rejected(node.id)
        }
    }

    /// The permitted values for a list/mask item (`ML<listType>;`).
    public func listOptions(for node: QMXMenuNode) async throws -> [String] {
        guard node.kind == .list || node.kind == .mask else { return [] }
        guard let reply = try await session.rawCommand(
            "ML\(node.meta);", expectsReply: true, isIdempotent: true),
            reply.hasPrefix("ML"), reply.hasSuffix(";")
        else { throw QMXMenuError.malformedReply("ML\(node.meta);") }
        return reply.dropFirst(2).dropLast()
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
    }

    // MARK: - Whole-tree walk (profiles, search indexing)

    public struct Leaf: Sendable, Hashable {
        public var node: QMXMenuNode
        public var column: Int?
        public var value: String

        /// Stable identity for persistence: wire path + column.
        public var key: String {
            node.wirePath.joined(separator: "|")
                + (column.map { "[\($0)]" } ?? "")
        }
    }

    /// Depth-first walk collecting every readable leaf value. `onProgress`
    /// receives the running count and each leaf as it lands (the walk is
    /// one CAT round trip per node, so progress matters on a real radio).
    public func snapshotTree(
        onProgress: (@Sendable (Int, Leaf) -> Void)? = nil
    ) async throws -> [Leaf] {
        var leaves: [Leaf] = []
        var stack: [QMXMenuNode?] = [nil]
        while let parent = stack.popLast() {
            let kids: [QMXMenuNode]
            if let parent, parent.kind != .submenu { continue }
            kids = try await children(of: parent ?? nil)
            for kid in kids {
                switch kid.kind {
                case .submenu:
                    stack.append(kid)
                case .action, .info:
                    continue // nothing to save
                case .string, .number, .byte, .list, .mask:
                    let columns: [Int?] = kid.columns
                        .map { (0..<$0).map(Optional.some) } ?? [nil]
                    for column in columns {
                        guard let value = try? await value(of: kid,
                                                           column: column)
                        else { continue }
                        let leaf = Leaf(node: kid, column: column,
                                        value: value)
                        leaves.append(leaf)
                        onProgress?(leaves.count, leaf)
                    }
                }
            }
        }
        return leaves
    }

    // MARK: - Path encoding

    private func wirePath(_ components: [String],
                          column: Int? = nil) -> String {
        components.joined(separator: "|") + (column.map { "[\($0)]" } ?? "")
    }
}
