import UIKit
import UIKit.UIGestureRecognizerSubclass
import NotTennaPodCore

/// Queue starts on touch-down in the source handle/leading artwork region, not long press.
@MainActor final class QueueRowDrag: UIGestureRecognizer {
    var accepts: ((CGPoint) -> Bool)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // A later finger must notify the active controller to restore its preview/scroll state.
        if state == .began || state == .changed { state = .cancelled; return }
        guard state == .possible, touches.count == 1, let touch = touches.first, let view,
              accepts?(touch.location(in: view)) == true else { state = .failed; return }
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }; state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }; state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }; state = .cancelled
    }
}

/// Owns only transient row placement. Persistence goes through one captured-order transaction at release.
/// Rows exist only near the screen (`LazyContentList`): the list places them in the dragged order, also those
/// built while the drag scrolls, and keeps the row under the finger.
@MainActor final class QueueDragController: NSObject {
    private let episodes: [LibraryEpisode]
    private weak var list: LazyContentList?
    private weak var scroll: UIScrollView?
    private let policy: () -> QueueInteractionPolicy
    private let commit: (QueueManualMove, [QueueEpisodeIdentity]) -> Void
    private var session: QueueDragSession?
    private var source: EpisodeRowView?
    private var sourceID: Int64?
    private var touchOffset: CGFloat = 0
    private var location = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var initialScrollEnabled = true
    private var recognizers: [QueueRowDrag] = []

    init(episodes: [LibraryEpisode], list: LazyContentList, scroll: UIScrollView,
         policy: @escaping () -> QueueInteractionPolicy, commit: @escaping (QueueManualMove, [QueueEpisodeIdentity]) -> Void) {
        self.episodes = episodes; self.list = list; self.scroll = scroll; self.policy = policy; self.commit = commit
        super.init()
    }
    isolated deinit {
        displayLink?.invalidate()
        for gesture in recognizers { gesture.view?.removeGestureRecognizer(gesture) }
    }
    /// A queue row that was built: dragging starts on its handle or cover.
    func attach(_ row: EpisodeRowView, id: Int64) {
        recognizers.removeAll { $0.view == nil }
        let gesture = QueueRowDrag(target: self, action: #selector(changed(_:)))
        gesture.name = String(id)
        gesture.accepts = { [weak self, weak row] point in
            guard let self, let row, session == nil else { return false }
            return row.acceptsQueueDrag(at: point, policy: policy())
        }
        row.addGestureRecognizer(gesture); recognizers.append(gesture)
    }
    /// The row being dragged: it stays built while the drag scrolls it away from its place.
    func holds(_ id: Int64) -> Bool { session != nil && sourceID == id }
    func cancel() {
        displayLink?.invalidate(); displayLink = nil
        if let scroll, session != nil { scroll.isScrollEnabled = initialScrollEnabled }
        source?.layer.zPosition = 0; source?.transform = .identity
        session = nil; source = nil; sourceID = nil
        place(episodes.map(\.id), dragging: false)
        for recognizer in recognizers { recognizer.isEnabled = false; recognizer.isEnabled = true }
    }
    @objc private func changed(_ gesture: QueueRowDrag) {
        guard let scroll, let id = gesture.name.flatMap(Int64.init), let row = gesture.view as? EpisodeRowView else { return }
        location = gesture.location(in: scroll)
        switch gesture.state {
        case .began:
            guard let next = QueueDragSession(episodes: episodes, episodeID: id, policy: policy()) else { return }
            session = next; source = row; sourceID = id; touchOffset = location.y - row.frame.minY
            initialScrollEnabled = scroll.isScrollEnabled; scroll.isScrollEnabled = false
            scroll.bringSubviewToFront(row); row.layer.zPosition = 1
            displayLink = CADisplayLink(target: self, selector: #selector(tick)); displayLink?.add(to: .main, forMode: .common)
        case .changed: move()
        case .ended:
            move() // Validate current policy and the release position before accepting the commit.
            guard let completed = session else { return }
            displayLink?.invalidate(); displayLink = nil; scroll.isScrollEnabled = initialScrollEnabled
            row.layer.zPosition = 0; source = nil; sourceID = nil; session = nil
            place(completed.order, dragging: false)
            if let move = completed.move { commit(move, completed.snapshot) }
        case .cancelled, .failed: if session != nil { cancel() }
        default: break
        }
    }
    private func move() {
        guard var current = session, let source, let list, policy().allowsDrag else { cancel(); return }
        let center = location.y - touchOffset + source.bounds.height / 2
        // Every row's centre where it is placed now, built or not.
        var centers: [Int64: CGFloat] = [:]
        for (index, id) in list.ids.enumerated() { centers[id] = list.frames[index].midY }
        current.cross(centerY: center, rowCenters: centers)
        session = current; place(current.order, dragging: true)
        source.frame.origin.y = location.y - touchOffset
    }
    private func place(_ order: [Int64], dragging: Bool) {
        list?.reorder(order, holding: dragging ? sourceID : nil)
    }
    @objc private func tick() {
        guard session != nil, let scroll, let source else { return }
        let visible = scroll.bounds
        let beyond = source.frame.minY < visible.minY ? source.frame.minY - visible.minY : max(0, source.frame.maxY - visible.maxY)
        guard beyond != 0 else { return }
        let maximum = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let next = min(maximum, max(-scroll.adjustedContentInset.top, scroll.contentOffset.y + min(20, max(-20, beyond / 4))))
        let delta = next - scroll.contentOffset.y
        scroll.contentOffset.y = next; location.y += delta; move()
    }
}
