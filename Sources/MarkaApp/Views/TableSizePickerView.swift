import AppKit

/// Pages-style table size grid (hover to choose columns × rows, click to insert).
final class TableSizePickerView: NSView {
    var onPick: ((Int, Int) -> Void)?

    static let maxColumns = 8
    static let maxRows = 8
    private static let cell: CGFloat = 16
    private static let gap: CGFloat = 3
    private static let inset: CGFloat = 12

    private var hoverColumns = 3
    private var hoverRows = 2
    private let label = NSTextField(labelWithString: "3 × 2 Table")

    override var isFlipped: Bool { true }

    static var preferredSize: NSSize {
        let gridW = inset * 2 + CGFloat(maxColumns) * cell + CGFloat(maxColumns - 1) * gap
        let gridH = inset + CGFloat(maxRows) * cell + CGFloat(maxRows - 1) * gap + 28
        return NSSize(width: gridW, height: gridH)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        addSubview(label)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 8, y: bounds.height - 24, width: bounds.width - 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        for row in 0..<Self.maxRows {
            for col in 0..<Self.maxColumns {
                let rect = cellRect(column: col, row: row)
                let selected = col < hoverColumns && row < hoverRows
                let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                if selected {
                    NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
                    NSColor.controlAccentColor.setStroke()
                } else {
                    NSColor.separatorColor.withAlphaComponent(0.35).setFill()
                    NSColor.separatorColor.setStroke()
                }
                path.fill()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        onPick?(hoverColumns, hoverRows)
    }

    private func updateHover(at point: NSPoint) {
        var cols = 1
        var rows = 1
        for col in 0..<Self.maxColumns {
            if point.x >= cellRect(column: col, row: 0).minX - 1 {
                cols = col + 1
            }
        }
        for row in 0..<Self.maxRows {
            if point.y >= cellRect(column: 0, row: row).minY - 1 {
                rows = row + 1
            }
        }
        cols = min(Self.maxColumns, max(1, cols))
        rows = min(Self.maxRows, max(1, rows))
        if cols != hoverColumns || rows != hoverRows {
            hoverColumns = cols
            hoverRows = rows
            label.stringValue = "\(cols) × \(rows) Table"
            needsDisplay = true
        }
    }

    private func cellRect(column: Int, row: Int) -> CGRect {
        CGRect(
            x: Self.inset + CGFloat(column) * (Self.cell + Self.gap),
            y: Self.inset + CGFloat(row) * (Self.cell + Self.gap),
            width: Self.cell,
            height: Self.cell
        )
    }
}
