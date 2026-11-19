import AppKit

/// Round add (+, green) / remove (−, red) control placed next to a table's drag grip.
final class TableCircleButton: NSButton {
    enum Kind { case add, remove }
    let kind: Kind
    private var hovered = false
    static let size: CGFloat = 16

    init(kind: Kind, title: String) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isBordered = false
        self.title = ""
        toolTip = title
        setAccessibilityLabel(title)
        refusesFirstResponder = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        let base: NSColor = kind == .add ? .systemGreen : .systemRed
        let fill = hovered ? (base.blended(withFraction: 0.15, of: .white) ?? base) : base
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        let path = NSBezierPath(ovalIn: circle)
        NSGradient(starting: fill.blended(withFraction: 0.25, of: .white) ?? fill, ending: fill)?.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()
        // Glyph: + or −.
        NSColor.white.setStroke()
        let glyph = NSBezierPath()
        let arm: CGFloat = 3.6
        glyph.move(to: CGPoint(x: circle.midX - arm, y: circle.midY))
        glyph.line(to: CGPoint(x: circle.midX + arm, y: circle.midY))
        if kind == .add {
            glyph.move(to: CGPoint(x: circle.midX, y: circle.midY - arm))
            glyph.line(to: CGPoint(x: circle.midX, y: circle.midY + arm))
        }
        glyph.lineWidth = 1.8
        glyph.lineCapStyle = .round
        glyph.stroke()
    }
}

/// Drag handle for moving the focused row (vertical) or column (horizontal).
final class TableGripView: NSView {
    enum Axis { case row, column }
    let axis: Axis
    /// Called with the drag position in the *table view's* coordinates.
    var onDrag: ((_ phase: NSEvent.Phase, _ point: CGPoint) -> Void)?

    static let rowSize = CGSize(width: 12, height: 12)
    static let columnSize = CGSize(width: 18, height: 12)

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: NSRect(origin: .zero, size: axis == .row ? Self.rowSize : Self.columnSize))
        toolTip = axis == .row ? "Drag to move this row" : "Drag to move this column"
        setAccessibilityRole(.handle)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .row ? .resizeUpDown : .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        pill.fill()
        // Six-dot grip.
        NSColor.white.setFill()
        let dot: CGFloat = 2
        for i in 0..<3 {
            for j in 0..<2 {
                let x: CGFloat, y: CGFloat
                if axis == .row {
                    x = bounds.midX - 2.5 + CGFloat(j) * 3 - dot / 2 + 1
                    y = bounds.midY - 4 + CGFloat(i) * 4 - dot / 2
                } else {
                    x = bounds.midX - 4 + CGFloat(i) * 4 - dot / 2
                    y = bounds.midY - 2.5 + CGFloat(j) * 3 - dot / 2 + 1
                }
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: dot, height: dot)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) { report(.began, event) }
    override func mouseDragged(with event: NSEvent) { report(.changed, event) }
    override func mouseUp(with event: NSEvent) { report(.ended, event) }

    private func report(_ phase: NSEvent.Phase, _ event: NSEvent) {
        guard let table = superview else { return }
        onDrag?(phase, table.convert(event.locationInWindow, from: nil))
    }
}
