import AppKit

/// Centers the document when it is smaller than the clip view (zoomed-out pages).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if doc.width < rect.width {
            rect.origin.x = (doc.width - rect.width) / 2
        }
        if doc.height < rect.height {
            rect.origin.y = documentView.isFlipped
                ? (doc.height - rect.height) / 2
                : (rect.height - doc.height) / 2
        }
        return rect
    }
}
