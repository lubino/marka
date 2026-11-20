import AppKit
import MarkaCore

/// Insert menu gallery (like the table gallery): a title and a grid of example tiles drawn as
/// they will look on the page — equations typeset, diagrams drawn, code as a sample. One click
/// inserts that block.
final class InsertGalleryView: NSView {
    let kind: InsertKind
    var onPick: ((InsertTemplate) -> Void)?
    private let darkPaper: Bool
    private let previews: [NSImage]
    private var hovered: Int?

    /// Diagrams get bigger tiles so their labels stay readable.
    private var tile: CGSize { Self.tileSize(for: kind) }
    static func tileSize(for kind: InsertKind) -> CGSize {
        kind.preview == .mermaid ? CGSize(width: 210, height: 150) : CGSize(width: 150, height: 96)
    }
    private static let labelHeight: CGFloat = 18
    private static let gap: CGFloat = 12
    private static let inset: CGFloat = 16
    private static let titleHeight: CGFloat = 26
    private static let columns = 3

    override var isFlipped: Bool { true }

    init(kind: InsertKind, darkPaper: Bool) {
        self.kind = kind
        self.darkPaper = darkPaper
        previews = kind.templates.map { Self.preview($0, kind: kind, darkPaper: darkPaper) }
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize(for: kind)))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Insert \(kind.title)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func preferredSize(for kind: InsertKind) -> NSSize {
        let count = kind.templates.count
        let rows = (count + columns - 1) / columns
        let tile = tileSize(for: kind)
        let width = inset * 2 + CGFloat(columns) * tile.width + CGFloat(columns - 1) * gap
        let height = inset * 2 + titleHeight + CGFloat(rows) * (tile.height + labelHeight) + CGFloat(rows - 1) * gap
        return NSSize(width: width, height: height)
    }

    func tileRect(_ index: Int) -> CGRect {
        let column = index % Self.columns
        let row = index / Self.columns
        return CGRect(
            x: Self.inset + CGFloat(column) * (tile.width + Self.gap),
            y: Self.inset + Self.titleHeight + CGFloat(row) * (tile.height + Self.labelHeight + Self.gap),
            width: tile.width,
            height: tile.height
        )
    }

    private func index(at point: CGPoint) -> Int? {
        kind.templates.indices.first { index in
            var rect = tileRect(index)
            rect.size.height += Self.labelHeight
            return rect.contains(point)
        }
    }

    // MARK: Previews

    /// The block as it will appear on the page (paper colours, so dark paper matches too).
    private static func preview(_ template: InsertTemplate, kind: InsertKind, darkPaper: Bool) -> NSImage {
        switch kind.preview {
        case .math:
            return MathRenderer.render(template.body, fontSize: 15, color: Theme.bodyColor(darkPaper: darkPaper), display: true).image
        case .mermaid:
            return MermaidRenderer.render(template.body, fontSize: 11, dark: darkPaper)
        case .code:
            let text = NSAttributedString(string: template.sample, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.bodyColor(darkPaper: darkPaper)
            ])
            // No wrapping: a long line scales the whole sample down instead.
            let size = text.boundingRect(with: CGSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).size
            return NSImage(size: CGSize(width: ceil(size.width), height: ceil(size.height)), flipped: true) { rect in
                text.draw(with: rect, options: [.usesLineFragmentOrigin])
                return true
            }
        }
    }

    // MARK: Interaction

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
        pick(index)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func pick(_ index: Int) {
        guard kind.templates.indices.contains(index) else { return }
        onPick?(kind.templates[index])
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let title = "Insert \(kind.title)" as NSString
        title.draw(at: CGPoint(x: Self.inset, y: Self.inset - 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        for (index, template) in kind.templates.enumerated() {
            let tile = tileRect(index)
            let card = NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8)
            // Paper-coloured card so drawings look exactly as on the page.
            Theme.paperColor(darkPaper: darkPaper).setFill()
            card.fill()
            if kind.preview == .code {
                Theme.codeBlockFill(darkPaper: darkPaper).setFill()
                NSBezierPath(roundedRect: tile.insetBy(dx: 6, dy: 6), xRadius: 5, yRadius: 5).fill()
            }
            (hovered == index ? NSColor.controlAccentColor.withAlphaComponent(0.8) : NSColor.separatorColor).setStroke()
            card.lineWidth = hovered == index ? 2 : 1
            card.stroke()
            drawPreview(previews[index], in: tile.insetBy(dx: kind.preview == .mermaid ? 8 : 12, dy: kind.preview == .mermaid ? 8 : 10), topLeft: kind.preview == .code)
            let label = template.title as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            label.draw(
                in: CGRect(x: tile.minX, y: tile.maxY + 3, width: tile.width, height: Self.labelHeight - 3),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: hovered == index ? .semibold : .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style
                ]
            )
        }
    }

    /// Scales the preview down (never up beyond 1.2×) to fit, centred — code sits top-left.
    private func drawPreview(_ image: NSImage, in rect: CGRect, topLeft: Bool) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height, 1.2)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = topLeft
            ? CGPoint(x: rect.minX, y: rect.minY)
            : CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // Testing
    var testPreviewSizes: [CGSize] { previews.map(\.size) }
}
