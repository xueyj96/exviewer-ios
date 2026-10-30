import Foundation

/// A feed keeps existing cards in their columns as covers resolve and pages
/// append. A new ordering starts a new placement; deletions only close gaps.
struct GalleryGridPlacement {
    private(set) var order: [String] = []
    private(set) var columns: [[String]] = [[], []]

    mutating func update(ids: [String], aspects: [String: Double]) {
        var seen = Set<String>()
        let incoming = ids.filter { seen.insert($0).inserted }
        guard incoming != order else { return }
        let incomingSet = Set(incoming)
        let retained = order.filter { incomingSet.contains($0) }
        // Preserve only an existing prefix followed by new items. A prepend,
        // insertion or explicit sort must display the new source order.
        if Array(incoming.prefix(retained.count)) != retained {
            columns = [[], []]
        } else {
            columns = columns.map { $0.filter { incomingSet.contains($0) } }
        }
        func height(_ id: String) -> Double {
            let aspect = aspects[id] ?? 0.71
            return 1 / (aspect.isFinite && aspect > 0 ? aspect : 0.71) + 0.36
        }
        var heights = columns.map { $0.reduce(0) { $0 + height($1) } }
        let assigned = Set(columns.flatMap { $0 })
        for id in incoming where !assigned.contains(id) {
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(id)
            heights[column] += height(id)
        }
        order = incoming
    }
}
