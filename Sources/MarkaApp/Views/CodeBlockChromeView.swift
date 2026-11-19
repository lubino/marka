import AppKit
import MarkaCore

/// Rounded GitHub-style fill drawn *behind* the text view. Clicks pass through.
/// `shapeRect` is the full block in this view's coordinates; bounds clip it at page edges.
final class CodeBlockBackgroundView: NSView {
    var darkPaper = false
    var shapeRect: CGRect = .zero
    var language: String?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shape = shapeRect.width > 1 ? shapeRect : bounds
        Theme.drawCodeBlockFill(in: shape, darkPaper: darkPaper)
        if let language, !language.isEmpty {
            let label = language as NSString
            label.draw(
                at: CGPoint(x: shape.minX + 12, y: shape.minY + 8),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
    }
}

enum ChipGlyph {
    case copy
    case terminal
}

final class CopyCodeButton: NSButton {
    var glyph: ChipGlyph = .copy
    private var hovered = false
    private var copied = false
    var darkPaper = false

    static let popupSize = CGSize(width: 26, height: 26)
    /// How far the chip hangs past the block’s top-right corner.
    static let hang: CGFloat = 9
    static let chipGap: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        image = nil
        title = ""
        toolTip = glyph == .terminal ? "Run in Terminal" : "Copy"
        focusRingType = .none
        refusesFirstResponder = true
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow?.shadowBlurRadius = 6
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
    }

    override var acceptsFirstResponder: Bool { false }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSCursor.pointingHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = hovered ? 0.92 : 0.58
        let fill = darkPaper
            ? NSColor.black.withAlphaComponent(alpha)
            : NSColor.white.withAlphaComponent(alpha)
        let chip = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        fill.setFill()
        chip.fill()
        NSColor.separatorColor.withAlphaComponent(hovered ? 0.5 : 0.28).setStroke()
        chip.lineWidth = 0.6
        chip.stroke()

        let ink = (darkPaper ? NSColor.white : NSColor(white: 0.22, alpha: 1))
            .withAlphaComponent(hovered ? 0.95 : 0.8)
        ink.setStroke()
        if copied {
            drawCheck(in: bounds)
        } else if glyph == .terminal {
            drawTerminal(in: bounds)
        } else {
            drawOverlappingSquares(in: bounds)
        }
    }

    /// Two rounded squares, front over back — the standard copy glyph.
    private func drawOverlappingSquares(in rect: CGRect) {
        let side: CGFloat = 8.5
        let radius: CGFloat = 1.6
        let back = CGRect(x: rect.midX - 1.2, y: rect.midY - 6.4, width: side, height: side)
        let front = CGRect(x: rect.midX - 7.2, y: rect.midY - 2.2, width: side, height: side)
        let backPath = NSBezierPath(roundedRect: back, xRadius: radius, yRadius: radius)
        let frontPath = NSBezierPath(roundedRect: front, xRadius: radius, yRadius: radius)
        backPath.lineWidth = 1.35
        frontPath.lineWidth = 1.35
        backPath.stroke()
        let fill = darkPaper
            ? NSColor.black.withAlphaComponent(hovered ? 0.92 : 0.58)
            : NSColor.white.withAlphaComponent(hovered ? 0.92 : 0.58)
        fill.setFill()
        frontPath.fill()
        frontPath.stroke()
    }

    private func drawTerminal(in rect: CGRect) {
        let window = CGRect(x: rect.midX - 7, y: rect.midY - 5.5, width: 14, height: 11)
        let path = NSBezierPath(roundedRect: window, xRadius: 2, yRadius: 2)
        path.lineWidth = 1.25
        path.stroke()
        let prompt = NSBezierPath()
        prompt.move(to: CGPoint(x: window.minX + 3, y: window.midY + 1.5))
        prompt.line(to: CGPoint(x: window.minX + 6, y: window.midY - 0.5))
        prompt.line(to: CGPoint(x: window.minX + 3, y: window.midY - 2.5))
        prompt.lineWidth = 1.2
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.stroke()
        let cursor = NSBezierPath()
        cursor.move(to: CGPoint(x: window.minX + 7.5, y: window.midY - 2.2))
        cursor.line(to: CGPoint(x: window.minX + 11, y: window.midY - 2.2))
        cursor.lineWidth = 1.2
        cursor.lineCapStyle = .round
        cursor.stroke()
    }

    private func drawCheck(in rect: CGRect) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.midX - 5, y: rect.midY))
        path.line(to: CGPoint(x: rect.midX - 1.5, y: rect.midY + 4))
        path.line(to: CGPoint(x: rect.midX + 5.5, y: rect.midY - 4))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    func showCopied() {
        copied = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copied = false
            self?.needsDisplay = true
        }
    }
}

/// Semi-transparent copy chip that hangs off a block’s top-right corner.
final class CopyChipView: NSView {
    var copyText: String = ""
    var runScript: String?
    var onRun: ((String) -> Void)?
    let copyButton = CopyCodeButton()
    let runButton = CopyCodeButton()

    override var isFlipped: Bool { true }
    var showsRun: Bool { runScript != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        copyButton.glyph = .copy
        copyButton.toolTip = "Copy"
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        runButton.glyph = .terminal
        runButton.toolTip = "Run in Terminal"
        runButton.target = self
        runButton.action = #selector(runTapped)
        addSubview(copyButton)
        addSubview(runButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(copyText: String, darkPaper: Bool, runScript: String? = nil) {
        self.copyText = copyText
        self.runScript = runScript
        copyButton.darkPaper = darkPaper
        runButton.darkPaper = darkPaper
        runButton.isHidden = runScript == nil
        needsLayout = true
        window?.invalidateCursorRects(for: copyButton)
        window?.invalidateCursorRects(for: runButton)
    }

    static func frame(hangingFrom block: CGRect, showsRun: Bool = false) -> CGRect {
        let size = CopyCodeButton.popupSize
        let hang = CopyCodeButton.hang
        let width = showsRun ? size.width * 2 + CopyCodeButton.chipGap : size.width
        return CGRect(
            x: block.maxX - width + hang,
            y: block.minY - hang,
            width: width,
            height: size.height
        )
    }

    override func layout() {
        super.layout()
        let size = CopyCodeButton.popupSize
        var x: CGFloat = 0
        if showsRun {
            runButton.frame = CGRect(origin: .zero, size: size)
            x = size.width + CopyCodeButton.chipGap
        } else {
            runButton.frame = .zero
        }
        copyButton.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
        window?.invalidateCursorRects(for: copyButton)
        window?.invalidateCursorRects(for: runButton)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if copyButton.frame.contains(local) { return copyButton }
        if showsRun, runButton.frame.contains(local) { return runButton }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyText, forType: .string)
        copyButton.showCopied()
    }

    @objc func runTapped() {
        guard let runScript else { return }
        onRun?(runScript)
    }
}

typealias CodeBlockHeaderView = CopyChipView
