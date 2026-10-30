import SwiftUI

struct GalleryFeedViewport {
    var space: String
    var height: CGFloat
    var topOcclusion: CGFloat = 0
    var contentTop: CGFloat { min(max(0, topOcclusion), max(0, height)) }

    static func restorationID(for galleryID: String) -> String { "feed.restore.\(galleryID)" }

    // The one-point marker restores immediately below the floating header,
    // independently of the cover's aspect ratio.
    var restorationAlignment: UnitPoint {
        UnitPoint(x: 0.5, y: min(max(0, topOcclusion) / max(1, height - 1), 1))
    }

    func nearestVisibleAnchor(in frames: [String: CGRect]) -> String? {
        guard height > contentTop else { return nil }
        return frames.filter { $0.value.maxY > contentTop && $0.value.minY < height }.min { lhs, rhs in
            let a = abs(lhs.value.minY - contentTop), b = abs(rhs.value.minY - contentTop)
            if a != b { return a < b }
            if lhs.value.minY != rhs.value.minY { return lhs.value.minY < rhs.value.minY }
            if lhs.value.minX != rhs.value.minX { return lhs.value.minX < rhs.value.minX }
            return lhs.key < rhs.key
        }?.key
    }
}
