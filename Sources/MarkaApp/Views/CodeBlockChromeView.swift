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
                    .font: Theme.codeLabelFont,
                    .foregroundColor: Theme.paperSecondaryText(darkPaper: darkPaper)
                ]
            )
        }
    }
}

enum ChipGlyph {
    case copy
    case terminal
}

/// Small round icon button (copy / run). Borderless SF Symbol; the round glass behind it comes
/// from `CopyChipView`. Always shows the pointing-hand cursor.
final class CopyCodeButton: NSButton {
    var glyph: ChipGlyph = .copy { didSet { updateImage() } }
    private var copied = false
    var darkPaper = false { didSet { updateTint() } }

    static let popupSize = CGSize(width: 22, height: 22)
    /// How far the chip hangs past the block’s top-right corner.
    static let hang: CGFloat = 7
    static let chipGap: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        focusRingType = .none
        refusesFirstResponder = true
        setButtonType(.momentaryChange)
        updateImage()
        updateTint()
    }

    override var acceptsFirstResponder: Bool { false }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateImage() {
        let name: String
        if copied {
            name = "checkmark"
        } else {
            name = glyph == .terminal ? "apple.terminal" : "doc.on.doc"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        image = NSImage(systemSymbolName: name, accessibilityDescription: glyph == .terminal ? "Run in Terminal" : "Copy")?
            .withSymbolConfiguration(config)
        toolTip = glyph == .terminal ? "Run in Terminal" : "Copy"
    }

    private func updateTint() {
        contentTintColor = darkPaper ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.25, alpha: 1)
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

    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func showCopied() {
        copied = true
        updateImage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copied = false
            self?.updateImage()
        }
    }
}

/// Round glass icons (run, copy) hanging off a block’s top-right corner. No tile, no border:
/// Liquid Glass on macOS 26+, a translucent material on 14/15.
final class CopyChipView: NSView {
    var copyText: String = ""
    var runScript: String?
    var onRun: ((String) -> Void)?
    let copyButton = CopyCodeButton()
    let runButton = CopyCodeButton()
    private let copyGlass: NSView
    private let runGlass: NSView

    override var isFlipped: Bool { true }
    var showsRun: Bool { runScript != nil }

    private static func roundGlass(around button: NSButton) -> NSView {
        let size = CopyCodeButton.popupSize
        let radius = size.height / 2
        // The glass sizes its content view; a plain container keeps the button exactly 22 × 22.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        button.frame = container.bounds
        button.autoresizingMask = [.width, .height]
        button.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(button)
        if GlassChrome.usesLiquidGlass {
            let glass = GlassChrome.wrap(container, style: .regular, cornerRadius: radius, interactive: true)
            glass.frame = NSRect(origin: .zero, size: size)
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        effect.frame = NSRect(origin: .zero, size: size)
        effect.addSubview(container)
        return effect
    }

    override init(frame frameRect: NSRect) {
        copyGlass = Self.roundGlass(around: copyButton)
        runGlass = Self.roundGlass(around: runButton)
        super.init(frame: frameRect)
        copyButton.glyph = .copy
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        runButton.glyph = .terminal
        runButton.target = self
        runButton.action = #selector(runTapped)
        addSubview(runGlass)
        addSubview(copyGlass)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(copyText: String, darkPaper: Bool, runScript: String? = nil) {
        self.copyText = copyText
        self.runScript = runScript
        copyButton.darkPaper = darkPaper
        runButton.darkPaper = darkPaper
        runGlass.isHidden = runScript == nil
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
            runGlass.frame = CGRect(origin: .zero, size: size)
            x = size.width + CopyCodeButton.chipGap
        } else {
            runGlass.frame = .zero
        }
        copyGlass.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
        window?.invalidateCursorRects(for: copyButton)
        window?.invalidateCursorRects(for: runButton)
    }

    /// Only the round icons take clicks; the gap between them passes through to the text.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if copyGlass.frame.contains(local) { return copyButton }
        if showsRun, runGlass.frame.contains(local) { return runButton }
        return nil
    }

    /// True when `windowPoint` is over one of the icons (used to keep the pointing-hand cursor).
    func containsIcon(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard !isHidden, window != nil else { return false }
        let local = convert(windowPoint, from: nil)
        return copyGlass.frame.contains(local) || (showsRun && runGlass.frame.contains(local))
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
