import Combine
import Foundation
import SwiftUI

@MainActor
struct LibrarySelectionSummaryState: Equatable {
    var count = 0
    var allLoadedSelected = false
}

@MainActor
final class LibrarySelectionSummary: ObservableObject {
    @Published private(set) var value = LibrarySelectionSummaryState()

    fileprivate func update(count: Int, allLoadedSelected: Bool) {
        let next = LibrarySelectionSummaryState(count: count, allLoadedSelected: allLoadedSelected)
        if value != next { value = next }
    }
}

@MainActor
final class LibrarySelectionEntry: ObservableObject {
    @Published private(set) var isSelected: Bool

    fileprivate init(isSelected: Bool) { self.isSelected = isSelected }

    fileprivate func update(_ selected: Bool) {
        if isSelected != selected { isSelected = selected }
    }
}

/// Owns selection without broadcasting a whole-feed update for each tap.
/// Visible cells observe only their stable per-ID entry; count and select-all
/// controls observe a separate summary object.
@MainActor
final class LibrarySelectionStore: ObservableObject {
    let summary = LibrarySelectionSummary()
    private(set) var selectedIDs = Set<String>()
    private var loadedIDs = Set<String>()
    private var loadedSelectedCount = 0
    private var entries: [String: LibrarySelectionEntry] = [:]

    func entry(for id: String) -> LibrarySelectionEntry {
        if let entry = entries[id] { return entry }
        let entry = LibrarySelectionEntry(isSelected: selectedIDs.contains(id))
        entries[id] = entry
        return entry
    }

    /// Dataset membership changes only when the filtered gallery identities
    /// change. Adding a page preserves the existing selection.
    func updateLoadedIDs(_ ids: Set<String>) {
        guard loadedIDs != ids else { return }
        let removed = selectedIDs.subtracting(ids)
        for id in removed { entries[id]?.update(false) }
        selectedIDs.subtract(removed)
        loadedIDs = ids
        loadedSelectedCount = selectedIDs.intersection(ids).count
        entries = entries.reduce(into: [:]) { retained, element in
            if ids.contains(element.key) { retained[element.key] = element.value }
        }
        publishSummary()
    }

    @discardableResult
    func beginSelecting(_ id: String) -> Bool {
        guard loadedIDs.contains(id) else { return false }
        for (entryID, entry) in entries where selectedIDs.contains(entryID) && entryID != id {
            entry.update(false)
        }
        selectedIDs = [id]
        loadedSelectedCount = loadedIDs.contains(id) ? 1 : 0
        entry(for: id).update(true)
        publishSummary()
        return true
    }

    @discardableResult
    func toggle(_ id: String) -> Bool {
        guard loadedIDs.contains(id) else { return false }
        if selectedIDs.remove(id) != nil {
            if loadedIDs.contains(id) { loadedSelectedCount = max(0, loadedSelectedCount - 1) }
            entries[id]?.update(false)
        } else {
            selectedIDs.insert(id)
            if loadedIDs.contains(id) { loadedSelectedCount += 1 }
            entries[id]?.update(true)
        }
        publishSummary()
        return true
    }

    func toggleAllLoaded() {
        guard !loadedIDs.isEmpty else { return }
        if summary.value.allLoadedSelected {
            for id in loadedIDs {
                selectedIDs.remove(id)
                entries[id]?.update(false)
            }
            loadedSelectedCount = 0
        } else {
            for id in loadedIDs {
                selectedIDs.insert(id)
                entries[id]?.update(true)
            }
            loadedSelectedCount = loadedIDs.count
        }
        publishSummary()
    }

    func remove(_ ids: [String]) {
        for id in ids {
            guard selectedIDs.remove(id) != nil else { continue }
            if loadedIDs.contains(id) { loadedSelectedCount = max(0, loadedSelectedCount - 1) }
            entries[id]?.update(false)
        }
        publishSummary()
    }

    func clear() {
        for (id, entry) in entries where selectedIDs.contains(id) { entry.update(false) }
        selectedIDs.removeAll(keepingCapacity: true)
        loadedSelectedCount = 0
        publishSummary()
    }

    private func publishSummary() {
        summary.update(count: selectedIDs.count,
                       allLoadedSelected: !loadedIDs.isEmpty && loadedSelectedCount == loadedIDs.count)
    }
}

struct FavoritesSelectionCount: View {
    @ObservedObject private var summary: LibrarySelectionSummary

    init(summary: LibrarySelectionSummary) { _summary = ObservedObject(wrappedValue: summary) }

    var body: some View {
        Text("已选 \(summary.value.count) 项")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("favorites.selection-count")
    }
}

struct FavoritesSelectionActions: View {
    @ObservedObject private var summary: LibrarySelectionSummary
    private let store: LibrarySelectionStore
    private let onMove: (Int) -> Void
    private let onRemove: () -> Void
    private let categoryName: (Int) -> String

    init(store: LibrarySelectionStore, onMove: @escaping (Int) -> Void, onRemove: @escaping () -> Void,
         categoryName: @escaping (Int) -> String) {
        self.store = store
        self.onMove = onMove
        self.onRemove = onRemove
        self.categoryName = categoryName
        _summary = ObservedObject(wrappedValue: store.summary)
    }

    var body: some View {
        HStack {
            Button(summary.value.allLoadedSelected ? "取消全选" : "全选已加载") {
                store.toggleAllLoaded()
            }
            .buttonStyle(AppActionButtonStyle())
            .frame(minHeight: 44)
            .accessibilityIdentifier("favorites.select-all")

            Spacer()

            Menu("移到分组") {
                ForEach(0...9, id: \.self) { index in
                    Button(categoryName(index)) { onMove(index) }
                }
            }
            .buttonStyle(AppActionButtonStyle())
            .frame(minHeight: 44)
            .disabled(summary.value.count == 0)
            .accessibilityIdentifier("favorites.move")

            Button("移除", role: .destructive, action: onRemove)
                .buttonStyle(AppActionButtonStyle())
                .frame(minHeight: 44)
                .disabled(summary.value.count == 0)
                .accessibilityIdentifier("favorites.remove")
        }
        .font(.subheadline)
    }
}
