import Foundation
import ExViewerCore

/// Large, neutral, local-only data set for exercising selection and grid updates.
enum LibrarySelectionQA {
    static let blockedTags: [GalleryTag] = (0..<250).map {
        GalleryTag(namespace: "qa-unmatched", name: "blocked-\($0)")
    }

    static func seedsBlockedTags(isQA: Bool, arguments: [String]) -> Bool {
        isQA && arguments.contains("--qa-library-large-selection")
    }

    @MainActor static let galleries: [Gallery] = {
        let templates = QASamples.galleries
        return (0..<600).map { index in
            var gallery = templates[index % templates.count]
            gallery.ref.gid = Int64(10_000 + index)
            gallery.title = String(format: "中性样例 %03d · %@", index + 1, templates[index % templates.count].title)
            gallery.cover = QASamples.cover(seed: index % 4 + 1)
            gallery.tagsComplete = true
            return gallery
        }
    }()
}
