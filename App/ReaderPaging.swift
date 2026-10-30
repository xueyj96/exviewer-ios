import SwiftUI

enum ReaderTapAction: Equatable {
    case previous, center, next
}

enum ReaderTapPolicy {
    static func action(at point: CGPoint, in viewport: CGRect,
                       direction: ReaderDirection, mode: ReaderMode) -> ReaderTapAction? {
        guard point.x.isFinite, point.y.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0, viewport.contains(point) else { return nil }
        let x = (point.x - viewport.minX) / viewport.width
        let y = (point.y - viewport.minY) / viewport.height
        guard mode == .singlePage else {
            return (0.28...0.72).contains(x) && (0.24...0.76).contains(y) ? .center : nil
        }
        let position = direction.horizontal ? x : y
        if (0.30...0.70).contains(position) { return .center }
        let forward = (position > 0.70) != direction.reverseOrder
        return forward ? .next : .previous
    }
}

enum ReaderSnapPolicy {
    static func offset(proposed: CGFloat, viewport: CGFloat, content: CGFloat,
                       ranges: [CGRect], horizontal: Bool, zoomed: Bool) -> CGFloat? {
        guard !zoomed, viewport > 0, content > viewport else { return nil }
        let bounds = max(0, content - viewport)
        let position = min(bounds, max(0, proposed))
        // A viewport wholly inside a long image must remain where the reader stopped.
        if ranges.contains(where: { rect in
            let start = horizontal ? rect.minX : rect.minY
            let end = horizontal ? rect.maxX : rect.maxY
            return end - start > viewport * 1.05 && position > start + 2 && position + viewport < end - 2
        }) { return nil }
        let candidates = ranges.flatMap { rect -> [CGFloat] in
            let start = horizontal ? rect.minX : rect.minY
            let end = horizontal ? rect.maxX : rect.maxY
            // Match ReaderView.scrollPosition: horizontal pages use center,
            // vertical pages use top. Reversing reading order changes the
            // sequence, not this physical anchor. A trailing anchor would
            // collapse several short reverse pages onto offset zero.
            let shortPageOffset = horizontal ? (start + end - viewport) / 2 : start
            let offsets = end - start > viewport * 1.05 ? [start, end - viewport] : [shortPageOffset]
            return offsets.map { min(bounds, max(0, $0)) }
        }
        guard let closest = candidates.min(by: { abs($0 - position) < abs($1 - position) }),
              abs(closest - position) <= viewport * 0.65 else { return nil }
        return closest
    }
}

struct ReaderSnappingBehavior: ScrollTargetBehavior {
    var ranges: [CGRect]
    var direction: ReaderDirection
    var zoomed: Bool
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let horizontal = direction.horizontal
        let viewport = horizontal ? context.containerSize.width : context.containerSize.height
        let content = horizontal ? context.contentSize.width : context.contentSize.height
        let proposed = horizontal ? target.rect.minX : target.rect.minY
        guard let offset = ReaderSnapPolicy.offset(proposed: proposed, viewport: viewport, content: content,
                                                   ranges: ranges, horizontal: horizontal, zoomed: zoomed) else { return }
        if horizontal { target.rect.origin.x = offset } else { target.rect.origin.y = offset }
    }
}

enum ReaderSlidePolicy {
    static func travel(direction: ReaderDirection, forward: Bool, size: CGSize) -> CGSize {
        let sign: CGFloat = (forward != direction.reverseOrder) ? 1 : -1
        return direction.horizontal ? CGSize(width: sign * size.width, height: 0) : CGSize(width: 0, height: sign * size.height)
    }
}

enum ReaderDragPolicy {
    static func pageOffset(index: Int, current: Int, direction: ReaderDirection, size: CGSize, translation: CGFloat) -> CGSize {
        let travel = ReaderSlidePolicy.travel(direction: direction, forward: true, size: size)
        let distance = CGFloat(index - current)
        return direction.horizontal ? CGSize(width: distance * travel.width + translation, height: 0)
                                    : CGSize(width: 0, height: distance * travel.height + translation)
    }
    static func pageDelta(offset: CGFloat, direction: ReaderDirection) -> Int {
        let forwardSign: CGFloat = direction.reverseOrder ? 1 : -1
        return offset * forwardSign > 0 ? 1 : -1
    }
    static func commits(offset: CGFloat, predicted: CGFloat, extent: CGFloat) -> Bool {
        guard extent > 0, abs(offset) >= 36 else { return false }
        return abs(offset) >= max(44, extent * 0.23) ||
            (offset * predicted > 0 && abs(predicted) >= extent * 0.5)
    }
    static func boundedOffset(_ offset: CGFloat, extent: CGFloat, hasNeighbor: Bool) -> CGFloat {
        let clamped = min(extent, max(-extent, offset))
        return hasNeighbor ? clamped : clamped * 0.16
    }
}
