import AppKit

/// Floating glass bar shown while the cursor is in a table: insert / delete rows and columns.
final class TableEditBar: NSView {
    enum Command: CaseIterable {
        case rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn

        var symbol: String {
            switch self {
            case .rowAbove: return "arrow.up.to.line.compact"
            case .rowBelow: return "arrow.down.to.line.compact"
            case .columnLeft: return "arrow.left.to.line.compact"
            case .columnRight: return "arrow.right.to.line.compact"
            case .deleteRow: return "rectangle.split.1x2"
            case .deleteColumn: return "rectangle.split.2x1"
            }
        }

        var title: String {
            switch self {
            case .rowAbove: return "Insert Row Above"
            case .rowBelow: return "Insert Row Below"
            case .columnLeft: return "Insert Column Left"
            case .columnRight: return "Insert Column Right"
            case .deleteRow: return "Delete Row"
            case .deleteColumn: return "Delete Column"
            }
        }

        var isDestructive: Bool { self == .deleteRow || self == .deleteColumn }
    }

    static let buttonSize: CGFloat = 24
    static let height: CGFloat = 30
    static var width: CGFloat {
        CGFloat(Command.allCases.count) * buttonSize + 4 * 2 + 10   // + divider gap
    }

    var onCommand: ((Command) -> Void)?
    private(set) var buttons: [Command: NSButton] = [:]
    private let glass: NSView

    override init(frame frameRect: NSRect) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        if GlassChrome.usesLiquidGlass {
            glass = GlassChrome.wrap(content, style: .regular, cornerRadius: Self.height / 2, interactive: true)
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.height / 2
            effect.layer?.masksToBounds = true
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            glass = effect
        }
        super.init(frame: frameRect)
        wantsLayer = true
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow?.shadowBlurRadius = 6
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        var x: CGFloat = 4
        for command in Command.allCases {
            if command == .deleteRow { x += 10 }   // gap between insert and delete groups
            let button = NSButton(frame: NSRect(x: x, y: (Self.height - Self.buttonSize) / 2, width: Self.buttonSize, height: Self.buttonSize))
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            button.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)?.withSymbolConfiguration(config)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.contentTintColor = command.isDestructive ? .systemRed : .labelColor
            button.toolTip = command.title
            button.setAccessibilityLabel(command.title)
            button.refusesFirstResponder = true
            button.target = self
            button.action = #selector(tapped(_:))
            button.tag = Command.allCases.firstIndex(of: command) ?? 0
            content.addSubview(button)
            buttons[command] = button
            x += Self.buttonSize
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func tapped(_ sender: NSButton) {
        onCommand?(Command.allCases[sender.tag])
    }

    /// Hit-test the buttons by frame (the glass wraps them in private views).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for button in buttons.values {
            let rect = button.convert(button.bounds, to: self)
            if rect.contains(local) { return button }
        }
        return self
    }

    func perform(_ command: Command) { onCommand?(command) }
}

/// Drag handle for moving the focused row (vertical) or column (horizontal).
final class TableGripView: NSView {
    enum Axis { case row, column }
    let axis: Axis
    /// Called with the drag position in the *table view's* coordinates.
    var onDrag: ((_ phase: NSEvent.Phase, _ point: CGPoint) -> Void)?

    static let rowSize = CGSize(width: 12, height: 18)
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
