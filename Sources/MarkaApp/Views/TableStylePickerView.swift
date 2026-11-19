import AppKit

/// Pages-style "insert table" gallery: a grid of ready-made table shapes drawn as GitHub-style
/// thumbnails. One click inserts that table (Pages inserts a styled default table the same way).
/// Markdown tables have a single look, so presets differ in shape, not colour.
final class TableStylePickerView: NSView {
    struct Preset: Equatable {
        var title: String
        var columns: Int
        /// Data rows below the header.
        var rows: Int
    }

    static let presets: [Preset] = [
        Preset(title: "Basic", columns: 3, rows: 3),
        Preset(title: "Two Columns", columns: 2, rows: 4),
        Preset(title: "Wide", columns: 5, rows: 3),
        Preset(title: "Compact", columns: 3, rows: 1),
        Preset(title: "Tall", columns: 3, rows: 8),
        Preset(title: "Grid", columns: 4, rows: 4)
    ]

    var onPick: ((Preset) -> Void)?
    var darkPaper = false

    private static let tile = CGSize(width: 96, height: 72)
    private static let labelHeight: CGFloat = 18
    private static let gap: CGFloat = 12
    private static let inset: CGFloat = 14
    private static let columnsPerRow = 3

    private var hovered: Int?

    override var isFlipped: Bool { true }

    static var preferredSize: NSSize {
        let rows = (presets.count + columnsPerRow - 1) / columnsPerRow
        let width = inset * 2 + CGFloat(columnsPerRow) * tile.width + CGFloat(columnsPerRow - 1) * gap
        let height = inset * 2 + CGFloat(rows) * (tile.height + labelHeight) + CGFloat(rows - 1) * gap
        return NSSize(width: width, height: height)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Insert Table")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tileRect(_ index: Int) -> CGRect {
        let column = index % Self.columnsPerRow
        let row = index / Self.columnsPerRow
        return CGRect(
            x: Self.inset + CGFloat(column) * (Self.tile.width + Self.gap),
            y: Self.inset + CGFloat(row) * (Self.tile.height + Self.labelHeight + Self.gap),
            width: Self.tile.width,
            height: Self.tile.height
        )
    }

    private func index(at point: CGPoint) -> Int? {
        Self.presets.indices.first { index in
            var rect = tileRect(index)
            rect.size.height += Self.labelHeight
            return rect.contains(point)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let next = index(at: convert(event.locationInWindow, from: nil))
        if next != hovered {
            hovered = next
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(Self.presets[index])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func pick(_ index: Int) {
        onPick?(Self.presets[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, preset) in Self.presets.enumerated() {
            let tile = tileRect(index)
            let card = NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8)
            (hovered == index ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)).setFill()
            card.fill()
            if hovered == index {
                NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
                card.lineWidth = 1.5
                card.stroke()
            }
            drawThumbnail(preset, in: tile.insetBy(dx: 12, dy: 10))
            let title = preset.title as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            title.draw(
                in: CGRect(x: tile.minX, y: tile.maxY + 3, width: tile.width, height: Self.labelHeight - 3),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: hovered == index ? .semibold : .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style
                ]
            )
        }
    }

    /// GitHub-style miniature: white cells, bold header bar, striped rows, 1 px grid.
    private func drawThumbnail(_ preset: Preset, in rect: CGRect) {
        let rows = preset.rows + 1
        let rowH = min(9, rect.height / CGFloat(rows))
        let height = rowH * CGFloat(rows)
        let frame = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let colW = frame.width / CGFloat(preset.columns)
        NSColor.white.setFill()
        frame.fill()
        for r in 0..<rows {
            let y = frame.minY + CGFloat(r) * rowH
            if r > 0, r % 2 == 0 {
                Theme.tableHeaderFill(darkPaper: false).setFill()
                CGRect(x: frame.minX, y: y, width: frame.width, height: rowH).fill()
            }
            // Text stand-ins: a bold bar in the header, thin bars in the body.
            for c in 0..<preset.columns {
                let x = frame.minX + CGFloat(c) * colW
                NSColor(white: r == 0 ? 0.25 : 0.6, alpha: 1).setFill()
                CGRect(x: x + 3, y: y + rowH / 2 - (r == 0 ? 1.25 : 0.75), width: colW * (r == 0 ? 0.55 : 0.45), height: r == 0 ? 2.5 : 1.5).fill()
            }
        }
        Theme.tableBorder(darkPaper: false).setStroke()
        let grid = NSBezierPath()
        for r in 0...rows {
            let y = frame.minY + CGFloat(r) * rowH
            grid.move(to: CGPoint(x: frame.minX, y: y))
            grid.line(to: CGPoint(x: frame.maxX, y: y))
        }
        for c in 0...preset.columns {
            let x = frame.minX + CGFloat(c) * colW
            grid.move(to: CGPoint(x: x, y: frame.minY))
            grid.line(to: CGPoint(x: x, y: frame.maxY))
        }
        grid.lineWidth = 0.75
        grid.stroke()
    }
}
