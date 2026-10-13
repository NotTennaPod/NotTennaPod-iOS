import UIKit

/// Fit-to-content, two-stop sheet motion. Offsets are measured down from the
/// expanded position; list content keeps its own independent scroll position.
struct DownloadLogSheetMotion {
    enum Stop { case expanded, collapsed, hidden }
    private(set) var stop: Stop = .collapsed
    private(set) var offset: CGFloat = 0
    private(set) var collapseOffset: CGFloat = 0
    private(set) var height: CGFloat = 0
    private(set) var isDragging = false
    private(set) var moved = false
    private var lastDelta: CGFloat = 0

    mutating func resize(height: CGFloat, visible: CGFloat) {
        let oldCollapse = collapseOffset, oldHeight = self.height
        let oldOffset = offset
        self.height = max(0, height)
        collapseOffset = max(0, height - visible)
        if isDragging {
            if oldOffset == 0 { offset = 0 }
            else if oldOffset <= oldCollapse, oldCollapse > 0 {
                offset = oldOffset / oldCollapse * collapseOffset
            } else {
                let fraction = (oldOffset - oldCollapse) / max(1, oldHeight - oldCollapse)
                offset = collapseOffset + fraction * (height - collapseOffset)
            }
            offset = min(self.height, max(0, offset))
        } else { offset = position(stop) }
    }
    mutating func begin() {
        isDragging = true; moved = false; lastDelta = 0
    }
    @discardableResult mutating func move(by delta: CGFloat) -> CGFloat {
        let previous = offset
        offset = min(height, max(0, offset + delta))
        let consumed = offset - previous
        if consumed != 0 { moved = true; lastDelta = consumed }
        return consumed
    }
    mutating func finish(velocity: CGFloat, horizontalVelocity: CGFloat = 0,
                         nested: Bool, cancelled: Bool = false) -> Stop {
        // ViewDragHelper releases cancellation with zero velocity. Settle from
        // the reached position, without retaining a stale pre-resize offset.
        if cancelled { return finish(velocity: 0, nested: false) }
        if nested {
            if offset == 0 || lastDelta < 0 { stop = .expanded }
            else if shouldHide(velocity) { stop = .hidden }
            else if lastDelta > 0 { stop = .collapsed }
            else { stop = nearest() }
        } else if velocity < 0 { stop = .expanded }
        else if shouldHide(velocity) {
            stop = (abs(horizontalVelocity) < velocity && velocity > 500) || offset > height / 2 ? .hidden : .expanded
        } else if velocity == 0 || abs(horizontalVelocity) > abs(velocity) { stop = nearest() }
        else { stop = .collapsed }
        isDragging = false; offset = position(stop)
        return stop
    }
    private func shouldHide(_ velocity: CGFloat) -> Bool {
        offset >= collapseOffset && abs(offset + velocity * 0.1 - collapseOffset) > (height - collapseOffset) * 0.5
    }
    private func nearest() -> Stop { offset < abs(offset - collapseOffset) ? .expanded : .collapsed }
    private func position(_ stop: Stop) -> CGFloat {
        switch stop { case .expanded: 0; case .collapsed: collapseOffset; case .hidden: height }
    }
}
