import Foundation

/// An order the user picked (the island's tabs), kept valid as the app changes: names it no
/// longer knows are dropped, repeats ignored, and anything new joins at the end.
public enum Ordering {
    /// The saved names in order, then the items they didn't mention, in their default order.
    public static func restore<Item>(_ saved: [String], all: [Item], name: (Item) -> String) -> [Item] {
        var result: [Item] = []
        var seen = Set<String>()
        for key in saved where !seen.contains(key) {
            guard let item = all.first(where: { name($0) == key }) else { continue }
            result.append(item)
            seen.insert(key)
        }
        result += all.filter { !seen.contains(name($0)) }
        return result
    }

    /// The items with the one at `index` moved `offset` places (−1 earlier, +1 later), stopping
    /// at either end.
    public static func move<Item>(_ items: [Item], from index: Int, by offset: Int) -> [Item] {
        guard items.indices.contains(index) else { return items }
        let target = min(max(index + offset, 0), items.count - 1)
        guard target != index else { return items }
        var moved = items
        moved.insert(moved.remove(at: index), at: target)
        return moved
    }
}
