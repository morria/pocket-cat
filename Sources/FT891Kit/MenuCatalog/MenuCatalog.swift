// Catalog access. The item table itself lives in CatalogItems.swift
// (transcribed from docs/ft891-menus.md; verified by MenuCatalogDocTests).

public enum MenuCatalog {
    /// All 159 items in front-panel order.
    public static let items: [MenuItem] = CatalogItems.all

    public static let byID: [String: MenuItem] =
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    public static let byEXNumber: [String: MenuItem] =
        Dictionary(uniqueKeysWithValues: items.map { ($0.exNumber, $0) })

    public static func items(in group: MenuGroup) -> [MenuItem] {
        items.filter { $0.group == group }
    }

    /// Items included in a configuration profile: writable, non-action.
    public static var profileItems: [MenuItem] {
        items.filter { $0.isWritable && !$0.isAction }
    }
}
