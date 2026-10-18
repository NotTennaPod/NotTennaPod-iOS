import UIKit
import NotTennaPodCore

/// A long list's content (episode rows, the Subscriptions grid): every loaded item has a frame, but views exist
/// only for the items near the visible area and are released when they move away from it, as with Android's
/// RecyclerView (building every row froze each page load and each tab switch). Views
/// are kept in list order among the scroll view's subviews, the order VoiceOver reads them in.
///
/// An episode list (full-width rows stacked from `top`, `append(_:heights:width:)`) keeps its rows' heights in bounded
/// chunks with each chunk's total, so a row inserted, removed or resized anywhere touches one chunk and the directory,
/// and absolute frames are computed only for the views that exist: a change near the top of a long list never shifts
/// every loaded row. A grid (`append(_:frames:)`) keeps explicit frames.
@MainActor final class LazyContentList {
    /// Geometry work, for the screens' budgets: chunk directory entries and rows visited, row entries moved within
    /// chunks, and existing views moved.
    struct Metrics: Equatable {
        var directoryVisited = 0
        var rowsVisited = 0
        var rowsMoved = 0
        var viewsMoved = 0
    }

    private final class Chunk {
        var ids: [Int64] = []
        var heights: [CGFloat] = []
        var total: CGFloat = 0
    }
    private static let chunkCapacity = 256

    /// Grid mode: explicit frames.
    private var gridIDs: [Int64] = []
    private var gridFrames: [CGRect] = []
    private var positions: [Int64: Int] = [:]
    /// Row mode: chunked heights.
    private var rowMode = false
    private var chunks: [Chunk] = []
    private var chunkOf: [Int64: Chunk] = [:]
    private var rowWidth: CGFloat = 0
    private var totalHeight: CGFloat = 0
    private var rowCount = 0

    private(set) var views: [Int64: UIView] = [:]
    var metrics = Metrics()
    let top: CGFloat
    private let make: (Int64) -> UIView
    /// After a view was released.
    var released: ((Int64) -> Void)?
    /// A view that stays although it left the area (the row under the finger in a drag).
    var pinned: ((Int64) -> Bool)?
    /// Content kept above every list view (a collapsing header, a floating button).
    var ceiling: (() -> UIView?)?
    /// The height a freshly built view needs; a measured height that went stale moves the items below it.
    var fittedHeight: ((UIView, CGFloat) -> CGFloat)?
    /// After an item's height changed.
    var resized: (() -> Void)?
    private var updating = false

    init(top: CGFloat, make: @escaping (Int64) -> UIView) {
        self.top = top; self.make = make
    }

    // MARK: - Reading

    var count: Int { rowMode ? rowCount : gridIDs.count }
    var bottom: CGFloat { rowMode ? top + totalHeight : (gridFrames.last?.maxY ?? top) }

    /// Every item in order (explicit work: tests, a drag, the reading position of a short list).
    var ids: [Int64] { rowMode ? chunks.flatMap(\.ids) : gridIDs }
    var frames: [CGRect] {
        guard rowMode else { return gridFrames }
        var result: [CGRect] = [], y = top
        result.reserveCapacity(rowCount)
        for chunk in chunks {
            for height in chunk.heights { result.append(CGRect(x: 0, y: y, width: rowWidth, height: height)); y += height }
        }
        return result
    }

    func contains(_ id: Int64) -> Bool { rowMode ? chunkOf[id] != nil : positions[id] != nil }

    /// The chunk at array position `index`, its first row's index and its top.
    private func chunkPosition(of chunk: Chunk) -> (index: Int, first: Int, y: CGFloat)? {
        var first = 0, y = top
        for (index, candidate) in chunks.enumerated() {
            metrics.directoryVisited += 1
            if candidate === chunk { return (index, first, y) }
            first += candidate.ids.count; y += candidate.total
        }
        return nil
    }

    func frame(of id: Int64) -> CGRect? {
        guard rowMode else { return positions[id].map { gridFrames[$0] } }
        guard let chunk = chunkOf[id], let position = chunkPosition(of: chunk),
              let offset = chunk.ids.firstIndex(of: id) else { return nil }
        metrics.rowsVisited += offset
        let y = position.y + chunk.heights[..<offset].reduce(0, +)
        return CGRect(x: 0, y: y, width: rowWidth, height: chunk.heights[offset])
    }

    /// The item's index in the list.
    func index(of id: Int64) -> Int? {
        guard rowMode else { return positions[id] }
        guard let chunk = chunkOf[id], let position = chunkPosition(of: chunk), let offset = chunk.ids.firstIndex(of: id) else { return nil }
        return position.first + offset
    }

    /// The item at `index` and its frame.
    func item(at index: Int) -> (id: Int64, frame: CGRect)? {
        guard index >= 0, index < count else { return nil }
        guard rowMode else { return (gridIDs[index], gridFrames[index]) }
        var first = 0, y = top
        for chunk in chunks {
            metrics.directoryVisited += 1
            if index < first + chunk.ids.count {
                let offset = index - first
                metrics.rowsVisited += offset
                return (chunk.ids[offset], CGRect(x: 0, y: y + chunk.heights[..<offset].reduce(0, +), width: rowWidth, height: chunk.heights[offset]))
            }
            first += chunk.ids.count; y += chunk.total
        }
        return nil
    }

    /// The first item whose bottom is below `y`, and its frame (the reading position).
    func firstItem(below y: CGFloat) -> (index: Int, id: Int64, frame: CGRect)? {
        guard rowMode else {
            guard let index = gridFrames.firstIndex(where: { $0.maxY > y }) else { return nil }
            return (index, gridIDs[index], gridFrames[index])
        }
        var first = 0, start = top
        for chunk in chunks {
            metrics.directoryVisited += 1
            if start + chunk.total > y {
                var rowY = start
                for (offset, height) in chunk.heights.enumerated() {
                    metrics.rowsVisited += 1
                    if rowY + height > y { return (first + offset, chunk.ids[offset], CGRect(x: 0, y: rowY, width: rowWidth, height: height)) }
                    rowY += height
                }
            }
            first += chunk.ids.count; start += chunk.total
        }
        return nil
    }

    /// The items overlapping `minY..<maxY` (frames run top to bottom).
    func indices(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        guard rowMode else {
            func first(_ predicate: (CGRect) -> Bool) -> Int {
                var low = 0, high = gridFrames.count
                while low < high {
                    let middle = (low + high) / 2
                    if predicate(gridFrames[middle]) { high = middle } else { low = middle + 1 }
                }
                return low
            }
            let start = first { $0.maxY > minY }
            return start..<max(start, first { $0.minY >= maxY })
        }
        guard let first = firstItem(below: minY) else { return rowCount..<rowCount }
        var end = first.index
        let cursor = rowCursor(at: first.index)
        while let row = cursor.next(), row.frame.minY < maxY { end += 1 }
        return first.index..<end
    }

    /// Rows from `index` on, in order, with their frames.
    private func rowCursor(at index: Int) -> AnyIterator<(id: Int64, frame: CGRect)> {
        var chunkIndex = 0, offset = 0, y = top, first = 0
        while chunkIndex < chunks.count, index >= first + chunks[chunkIndex].ids.count {
            metrics.directoryVisited += 1
            first += chunks[chunkIndex].ids.count; y += chunks[chunkIndex].total; chunkIndex += 1
        }
        if chunkIndex < chunks.count {
            offset = index - first
            y += chunks[chunkIndex].heights[..<offset].reduce(0, +)
        }
        return AnyIterator { [self] in
            while chunkIndex < chunks.count, offset >= chunks[chunkIndex].ids.count { chunkIndex += 1; offset = 0 }
            guard chunkIndex < chunks.count else { return nil }
            let chunk = chunks[chunkIndex], height = chunk.heights[offset]
            defer { offset += 1; y += height }
            metrics.rowsVisited += 1
            return (chunk.ids[offset], CGRect(x: 0, y: y, width: rowWidth, height: height))
        }
    }

    // MARK: - Building

    func append(_ newIDs: [Int64], frames newFrames: [CGRect]) {
        precondition(!rowMode)
        for (offset, id) in newIDs.enumerated() where positions[id] == nil { positions[id] = gridIDs.count + offset }
        gridIDs += newIDs; gridFrames += newFrames
    }

    /// Stacks full-width rows below the current end.
    func append(_ newIDs: [Int64], heights: [CGFloat], width: CGFloat) {
        precondition(gridIDs.isEmpty)
        rowMode = true; rowWidth = width
        for (id, height) in zip(newIDs, heights) where chunkOf[id] == nil {
            if chunks.last.map({ $0.ids.count >= Self.chunkCapacity }) ?? true { chunks.append(Chunk()) }
            let chunk = chunks[chunks.count - 1]
            chunk.ids.append(id); chunk.heights.append(height); chunk.total += height
            chunkOf[id] = chunk
            totalHeight += height; rowCount += 1
        }
    }

    // MARK: - Changes (row mode)

    /// Inserts row `id` with `height` at `index`; rows and views below move down.
    func insert(_ id: Int64, height: CGFloat, at index: Int) {
        precondition(rowMode || count == 0)
        rowMode = true
        guard chunkOf[id] == nil else { return }
        let y = item(at: index)?.frame.minY ?? bottom
        var first = 0, target = chunks.count - 1
        for (position, chunk) in chunks.enumerated() {
            metrics.directoryVisited += 1
            if index <= first + chunk.ids.count { target = position; break }
            first += chunk.ids.count
        }
        if chunks.isEmpty { chunks = [Chunk()]; target = 0; first = 0 }
        let chunk = chunks[target], offset = min(chunk.ids.count, index - first)
        metrics.rowsMoved += chunk.ids.count - offset
        chunk.ids.insert(id, at: offset); chunk.heights.insert(height, at: offset); chunk.total += height
        chunkOf[id] = chunk
        totalHeight += height; rowCount += 1
        if chunk.ids.count > Self.chunkCapacity { split(target) }
        shiftViews(from: y, by: height, except: id)
    }

    /// Removes row `id` (its view is released); rows and views below move up.
    func remove(_ id: Int64) {
        guard rowMode, let chunk = chunkOf[id], let position = chunkPosition(of: chunk),
              let offset = chunk.ids.firstIndex(of: id) else { return }
        let y = position.y + chunk.heights[..<offset].reduce(0, +), height = chunk.heights[offset]
        metrics.rowsMoved += chunk.ids.count - offset - 1
        chunk.ids.remove(at: offset); chunk.heights.remove(at: offset); chunk.total -= height
        chunkOf[id] = nil
        totalHeight -= height; rowCount -= 1
        if chunk.ids.isEmpty { chunks.remove(at: position.index) }
        if let view = views.removeValue(forKey: id) { view.removeFromSuperview(); released?(id) }
        shiftViews(from: y + height, by: -height, except: nil)
    }

    /// Rebuilds row `id`'s view if it exists (its content changed); returns whether it did.
    @discardableResult
    func rebuild(_ id: Int64, in scroll: UIScrollView) -> Bool {
        guard let old = views[id], let frame = frame(of: id) else { return false }
        let view = make(id)
        view.frame = frame
        old.superview?.insertSubview(view, aboveSubview: old)
        old.removeFromSuperview()
        views[id] = view
        if let fitted = fittedHeight?(view, frame.width), abs(fitted - frame.height) > 0.5 { setHeight(fitted, of: id, in: scroll) }
        return true
    }

    /// Row `id` takes `height`; rows below move. Content above the screen that grew or shrank keeps the reading place.
    func setHeight(_ height: CGFloat, of id: Int64, in scroll: UIScrollView?) {
        guard rowMode, let chunk = chunkOf[id], let offset = chunk.ids.firstIndex(of: id), let frame = frame(of: id) else { return }
        let delta = height - chunk.heights[offset]
        guard abs(delta) > 0.001 else { return }
        chunk.heights[offset] = height; chunk.total += delta; totalHeight += delta
        views[id]?.frame.size.height = height
        shiftViews(from: frame.maxY, by: delta, except: id)
        resized?()
        if let scroll, frame.maxY <= scroll.bounds.minY { scroll.contentOffset.y += delta }
    }

    private func split(_ index: Int) {
        let chunk = chunks[index], half = chunk.ids.count / 2
        let tail = Chunk()
        tail.ids = Array(chunk.ids[half...]); tail.heights = Array(chunk.heights[half...]); tail.total = tail.heights.reduce(0, +)
        chunk.ids.removeSubrange(half...); chunk.heights.removeSubrange(half...); chunk.total -= tail.total
        for id in tail.ids { chunkOf[id] = tail }
        metrics.rowsMoved += tail.ids.count
        chunks.insert(tail, at: index + 1)
    }

    /// Moves the existing views at or below `y` by `delta` (only views exist as absolute frames).
    private func shiftViews(from y: CGFloat, by delta: CGFloat, except: Int64?) {
        for (id, view) in views where id != except && view.frame.minY >= y - 0.5 {
            view.frame.origin.y += delta
            metrics.viewsMoved += 1
        }
    }

    // MARK: - Views

    /// Builds the views within one screen of the visible area and releases those more than two screens away.
    func update(in scroll: UIScrollView) {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        // At least a few rows ahead, also in a very short window.
        let margin = max(400, scroll.bounds.height)
        let keep = scroll.bounds.minY - 2 * margin ..< scroll.bounds.maxY + 2 * margin
        for (id, view) in views where pinned?(id) != true {
            if view.frame.maxY > keep.lowerBound, view.frame.minY < keep.upperBound, contains(id) { continue }
            view.removeFromSuperview(); views[id] = nil; released?(id)
        }
        if rowMode {
            guard let first = firstItem(below: scroll.bounds.minY - margin) else { return }
            let cursor = rowCursor(at: first.index)
            while let row = cursor.next(), row.frame.minY < scroll.bounds.maxY + margin {
                guard views[row.id] == nil else { continue }
                let view = make(row.id)
                views[row.id] = view
                view.frame = row.frame
                insert(view, in: scroll)
                if let fitted = fittedHeight?(view, row.frame.width), abs(fitted - row.frame.height) > 0.5 {
                    setHeight(fitted, of: row.id, in: scroll)
                    // The rows after it moved: continue from a fresh position.
                    return update(continuingIn: scroll)
                }
            }
            return
        }
        var index = indices(from: scroll.bounds.minY - margin, to: scroll.bounds.maxY + margin).lowerBound
        while index < gridIDs.count, gridFrames[index].minY < scroll.bounds.maxY + margin {
            let id = gridIDs[index]
            if views[id] == nil, positions[id] == index {
                let view = make(id)
                views[id] = view
                view.frame = gridFrames[index]
                insert(view, in: scroll)
                if let fitted = fittedHeight?(view, gridFrames[index].width), abs(fitted - gridFrames[index].height) > 0.5 {
                    setGridHeight(fitted, at: index, in: scroll)
                }
            }
            index += 1
        }
    }

    private func update(continuingIn scroll: UIScrollView) {
        updating = false
        update(in: scroll)
        updating = true
    }

    /// Grid mode: the items become `newIDs` at `newFrames` (a patch of the Subscriptions grid). Views of items that stay are
    /// kept and moved to their new frames, views of items that left are released, new items are built by the next
    /// `update(in:)`; the views are put back in list order for VoiceOver.
    func setGrid(_ newIDs: [Int64], frames newFrames: [CGRect], in scroll: UIScrollView) {
        precondition(!rowMode)
        gridIDs = newIDs; gridFrames = newFrames; positions = [:]
        for (index, id) in newIDs.enumerated() where positions[id] == nil { positions[id] = index }
        for (id, view) in views {
            if let index = positions[id] {
                if view.frame != gridFrames[index] { view.frame = gridFrames[index]; metrics.viewsMoved += 1 }
            } else {
                view.removeFromSuperview(); views[id] = nil; released?(id)
            }
        }
        let ordered = views.sorted { (positions[$0.key] ?? 0) < (positions[$1.key] ?? 0) }
        guard ordered.count > 1 else { return }
        for index in 1..<ordered.count where ordered[index].value.superview === scroll && ordered[index - 1].value.superview === scroll {
            scroll.insertSubview(ordered[index].value, aboveSubview: ordered[index - 1].value)
        }
    }

    /// Puts the items in `order` (items it does not name follow in their order) and moves their views; the
    /// `holding` item's view stays where it is (the row under the finger).
    func reorder(_ order: [Int64], holding: Int64? = nil) {
        if rowMode {
            var heights: [Int64: CGFloat] = [:]
            for chunk in chunks { for (id, height) in zip(chunk.ids, chunk.heights) { heights[id] = height } }
            let named = Set(order)
            let next = order.filter { heights[$0] != nil } + ids.filter { !named.contains($0) }
            chunks = []; chunkOf = [:]; totalHeight = 0; rowCount = 0
            append(next, heights: next.map { heights[$0] ?? 0 }, width: rowWidth)
            var y = top
            for id in next {
                if id != holding, let view = views[id] { view.frame.origin.y = y }
                y += heights[id] ?? 0
            }
            return
        }
        let named = Set(order)
        let next = order.filter { positions[$0] != nil } + gridIDs.filter { !named.contains($0) }
        var old: [Int64: CGRect] = [:]
        for (index, id) in gridIDs.enumerated() where old[id] == nil { old[id] = gridFrames[index] }
        var y = top
        gridIDs = next; positions = [:]; gridFrames = []
        for (index, id) in next.enumerated() {
            if positions[id] == nil { positions[id] = index }
            let frame = old[id] ?? .zero
            gridFrames.append(CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
            y += frame.height
        }
        for (id, view) in views where id != holding {
            if let index = positions[id] { view.frame.origin.y = gridFrames[index].minY }
        }
    }

    /// Puts the existing views back in list order among the scroll view's subviews (VoiceOver reads them in that order),
    /// after rows moved.
    func restoreViewOrder(in scroll: UIScrollView) {
        let ordered = views.sorted { $0.value.frame.minY < $1.value.frame.minY }
        guard ordered.count > 1 else { return }
        for index in 1..<ordered.count where ordered[index].value.superview === scroll {
            scroll.insertSubview(ordered[index].value, aboveSubview: ordered[index - 1].value)
        }
    }

    private func setGridHeight(_ height: CGFloat, at index: Int, in scroll: UIScrollView) {
        let delta = height - gridFrames[index].height
        let above = gridFrames[index].maxY <= scroll.bounds.minY
        gridFrames[index].size.height = height
        views[gridIDs[index]]?.frame = gridFrames[index]
        for later in gridFrames.indices.dropFirst(index + 1) { gridFrames[later].origin.y += delta }
        for (id, view) in views {
            if let position = positions[id], position > index { view.frame.origin.y = gridFrames[position].minY }
        }
        resized?()
        // Content above the screen grew or shrank: what the person is reading stays in place.
        if above { scroll.contentOffset.y += delta }
    }

    /// Places a new view among the existing ones in list order (rows: by their place on screen; grid items: by index).
    private func insert(_ view: UIView, in scroll: UIScrollView) {
        func key(_ id: Int64, _ view: UIView) -> CGFloat { rowMode ? view.frame.minY : CGFloat(positions[id] ?? .max) }
        guard let id = views.first(where: { $0.value === view })?.key else { scroll.addSubview(view); return }
        let own = key(id, view)
        var lower: (key: CGFloat, view: UIView)?, upper: (key: CGFloat, view: UIView)?
        for (other, otherView) in views where otherView !== view && otherView.superview === scroll {
            let value = key(other, otherView)
            if value < own { if lower.map({ value > $0.key }) ?? true { lower = (value, otherView) } }
            else if upper.map({ value < $0.key }) ?? true { upper = (value, otherView) }
        }
        if let lower { scroll.insertSubview(view, aboveSubview: lower.view) }
        else if let upper { scroll.insertSubview(view, belowSubview: upper.view) }
        else if let ceiling = ceiling?(), ceiling.superview === scroll { scroll.insertSubview(view, belowSubview: ceiling) }
        else { scroll.addSubview(view) }
    }
}
