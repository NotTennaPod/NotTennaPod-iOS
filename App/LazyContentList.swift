import UIKit
import NotTennaPodCore

/// A long list's content (episode rows, the Subscriptions grid): every loaded item has a frame, but views exist
/// only for the items near the visible area and are released when they move away from it, as with Android's
/// RecyclerView (building every row froze each page load and each tab switch). Views
/// are kept in list order among the scroll view's subviews, the order VoiceOver reads them in.
@MainActor final class LazyContentList {
    private(set) var ids: [Int64] = []
    private(set) var frames: [CGRect] = []
    private var positions: [Int64: Int] = [:]
    private(set) var views: [Int64: UIView] = [:]
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

    var bottom: CGFloat { frames.last?.maxY ?? top }
    func frame(of id: Int64) -> CGRect? { positions[id].map { frames[$0] } }

    func append(_ newIDs: [Int64], frames newFrames: [CGRect]) {
        for (offset, id) in newIDs.enumerated() where positions[id] == nil { positions[id] = ids.count + offset }
        ids += newIDs; frames += newFrames
    }

    /// Stacks the items below the current end.
    func append(_ newIDs: [Int64], heights: [CGFloat], width: CGFloat) {
        var y = bottom
        append(newIDs, frames: heights.map { height in
            defer { y += height }
            return CGRect(x: 0, y: y, width: width, height: height)
        })
    }

    /// The items overlapping `minY..<maxY` (frames run top to bottom).
    func indices(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        func first(_ predicate: (CGRect) -> Bool) -> Int {
            var low = 0, high = frames.count
            while low < high {
                let middle = (low + high) / 2
                if predicate(frames[middle]) { high = middle } else { low = middle + 1 }
            }
            return low
        }
        let start = first { $0.maxY > minY }
        return start..<max(start, first { $0.minY >= maxY })
    }

    /// Builds the views within one screen of the visible area and releases those more than two screens away.
    func update(in scroll: UIScrollView) {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        // At least a few rows ahead, also in a very short window.
        let margin = max(400, scroll.bounds.height)
        let keep = scroll.bounds.minY - 2 * margin ..< scroll.bounds.maxY + 2 * margin
        for (id, view) in views where pinned?(id) != true {
            if let index = positions[id], frames[index].maxY > keep.lowerBound, frames[index].minY < keep.upperBound { continue }
            view.removeFromSuperview(); views[id] = nil; released?(id)
        }
        var index = indices(from: scroll.bounds.minY - margin, to: scroll.bounds.maxY + margin).lowerBound
        while index < ids.count, frames[index].minY < scroll.bounds.maxY + margin {
            let id = ids[index]
            if views[id] == nil, positions[id] == index {
                let view = make(id)
                views[id] = view
                view.frame = frames[index]
                insert(view, at: index, in: scroll)
                if let fitted = fittedHeight?(view, frames[index].width), abs(fitted - frames[index].height) > 0.5 {
                    setHeight(fitted, at: index, in: scroll)
                }
            }
            index += 1
        }
    }

    /// Puts the items in `order` (items it does not name follow in their order) and moves their views; the
    /// `holding` item's view stays where it is (the row under the finger).
    func reorder(_ order: [Int64], holding: Int64? = nil) {
        let named = Set(order)
        let next = order.filter { positions[$0] != nil } + ids.filter { !named.contains($0) }
        var old: [Int64: CGRect] = [:]
        for (index, id) in ids.enumerated() where old[id] == nil { old[id] = frames[index] }
        var y = top
        ids = next; positions = [:]; frames = []
        for (index, id) in next.enumerated() {
            if positions[id] == nil { positions[id] = index }
            let frame = old[id] ?? .zero
            frames.append(CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
            y += frame.height
        }
        for (id, view) in views where id != holding {
            if let index = positions[id] { view.frame.origin.y = frames[index].minY }
        }
    }

    private func setHeight(_ height: CGFloat, at index: Int, in scroll: UIScrollView) {
        let delta = height - frames[index].height
        let above = frames[index].maxY <= scroll.bounds.minY
        frames[index].size.height = height
        views[ids[index]]?.frame = frames[index]
        for later in frames.indices.dropFirst(index + 1) { frames[later].origin.y += delta }
        for (id, view) in views {
            if let position = positions[id], position > index { view.frame.origin.y = frames[position].minY }
        }
        resized?()
        // Content above the screen grew or shrank: what the person is reading stays in place.
        if above { scroll.contentOffset.y += delta }
    }

    private func insert(_ view: UIView, at index: Int, in scroll: UIScrollView) {
        var lower: (position: Int, view: UIView)?, upper: (position: Int, view: UIView)?
        for (id, other) in views where other !== view && other.superview === scroll {
            guard let position = positions[id] else { continue }
            if position < index { if lower.map({ position > $0.position }) ?? true { lower = (position, other) } }
            else if upper.map({ position < $0.position }) ?? true { upper = (position, other) }
        }
        if let lower { scroll.insertSubview(view, aboveSubview: lower.view) }
        else if let upper { scroll.insertSubview(view, belowSubview: upper.view) }
        else if let ceiling = ceiling?(), ceiling.superview === scroll { scroll.insertSubview(view, belowSubview: ceiling) }
        else { scroll.addSubview(view) }
    }
}
