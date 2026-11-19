import AppKit
import MarkaCore

/// A drawn ```math / $$ / ```mermaid block sitting over its hidden source.
final class RenderedBlockView: NSView {
    var image: NSImage?
    var location = 0
    var onEdit: ((RenderedBlockView) -> Void)?
    private var hovered = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        guard let image else { return }
        let size = fittedSize(image.size)
        image.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    func fittedSize(_ natural: CGSize) -> CGSize {
        guard natural.width > bounds.width, natural.width > 0 else { return natural }
        return CGSize(width: bounds.width, height: natural.height * bounds.width / natural.width)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onEdit?(self) }
}

extension PagedEditorView {
    struct RenderedItem {
        let block: MarkdownSyntax.FencedCodeBlock
        let image: NSImage
        /// Size on the page (scaled down to the content width when wider).
        let size: CGSize
        var isMermaid: Bool { block.language?.lowercased().hasPrefix("mermaid") ?? false }
    }

    static let renderedPad: CGFloat = 8

    var bodyFontSize: CGFloat { textView.editorSettings.fontSize }

    func renderedImage(for block: MarkdownSyntax.FencedCodeBlock) -> NSImage {
        if block.language?.lowercased().hasPrefix("mermaid") ?? false {
            return MermaidRenderer.render(block.innerText, fontSize: max(10, bodyFontSize * 1.1), dark: darkPaper)
        }
        return MathRenderer.render(block.innerText, fontSize: max(11, bodyFontSize * 1.35),
                                   color: Theme.bodyColor(darkPaper: darkPaper), display: true).image
    }

    func renderedItems() -> [RenderedItem] {
        guard textView.mode == .wysiwyg else { return [] }
        let width = geometry.contentSize.width
        return MarkdownSyntax.renderedBlocks(in: textView.string).map { block in
            let image = renderedImage(for: block)
            var size = image.size
            if size.width > width, size.width > 0 { size = CGSize(width: width, height: size.height * width / size.width) }
            return RenderedItem(block: block, image: image, size: size)
        }
    }

    /// Space to reserve after the hidden source, and the drawing's top (text-container y). A drawing
    /// that would cross a page break moves to the top of the next page.
    ///
    /// The space is the paragraph spacing of the hidden source's (near-zero-height) last line, and
    /// TextKit counts that spacing as part of the line: a line that no longer fits moves to the next
    /// page *with* its spacing. So reserve just the drawing's height and draw it where that last line
    /// actually sits — adding the push distance too counted the page break twice.
    func renderedPlacement(_ item: RenderedItem) -> (spacing: CGFloat, top: CGFloat) {
        let group = item.block.group
        let height = item.size.height + Self.renderedPad * 2
        let lastLineY = caretY(at: max(group.location, NSMaxRange(group) - 1))
        return (height, lastLineY + Self.renderedPad)
    }

    func measureRenderedSpacing() -> [Int: CGFloat] {
        var spacing: [Int: CGFloat] = [:]
        for item in renderedItems() {
            spacing[item.block.group.location] = renderedPlacement(item).spacing
        }
        return spacing
    }

    func refreshRenderedBlocks() {
        let items = renderedItems()
        while renderedViews.count > items.count { renderedViews.removeLast().removeFromSuperview() }
        while renderedViews.count < items.count {
            let view = RenderedBlockView()
            view.onEdit = { [weak self] view in self?.editRenderedBlock(view) }
            addSubview(view, positioned: .above, relativeTo: textView)
            renderedViews.append(view)
        }
        let origin = textView.frame.origin
        let width = geometry.contentSize.width
        for (view, item) in zip(renderedViews, items) {
            let placement = renderedPlacement(item)
            view.image = item.image
            view.location = item.block.group.location
            view.toolTip = item.isMermaid ? "Mermaid diagram — click to edit" : "Equation — click to edit"
            view.frame = CGRect(x: origin.x, y: origin.y + placement.top - Self.renderedPad / 2,
                                width: width, height: item.size.height + Self.renderedPad)
            view.needsDisplay = true
        }
    }

    /// PDF / print: the drawings, at their page positions.
    func drawRenderedBlocks(intoPage paper: CGRect, paperOnCanvas: CGRect) {
        for view in renderedViews where !view.isHidden {
            let rect = CGRect(x: view.frame.minX - paperOnCanvas.minX, y: view.frame.minY - paperOnCanvas.minY,
                              width: view.frame.width, height: view.frame.height)
            guard rect.intersects(paper), let image = view.image else { continue }
            let size = view.fittedSize(image.size)
            image.draw(in: CGRect(x: rect.minX + (rect.width - size.width) / 2, y: rect.minY + (rect.height - size.height) / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: Testing

    var testRenderedFrames: [CGRect] { renderedViews.filter { !$0.isHidden }.map(\.frame) }

    /// Canvas y of the line holding `location` (top of its line fragment).
    func testCanvasY(of location: Int) -> CGFloat { textView.frame.minY + caretY(at: location) }

    /// Content rect (canvas coordinates) of the page holding canvas y `y`.
    func testPageContentRect(containing y: CGFloat) -> CGRect? {
        for page in 0..<pageCount {
            let paper = paperRect(page: page)
            if y >= paper.minY - 1, y <= paper.maxY + 1 { return paper.insetBy(dx: geometry.margin, dy: geometry.margin) }
        }
        return nil
    }

    func testEditRenderedBlock(_ index: Int, newSource: String) {
        guard index < renderedViews.count else { return }
        editRenderedBlock(renderedViews[index])
        renderedEditor?.testSetSource(newSource)
        renderedEditor?.commit()
    }

    // MARK: Editing

    func editRenderedBlock(_ view: RenderedBlockView) {
        guard let block = MarkdownSyntax.renderedBlocks(in: textView.string).first(where: { $0.group.location == view.location }) else { return }
        let editor = RenderedSourceEditor(source: block.innerText, mermaid: block.language?.lowercased().hasPrefix("mermaid") ?? false) { [weak self] source in
            self?.renderedImage(forSource: source, like: block) ?? NSImage()
        }
        editor.onCommit = { [weak self] text in self?.replaceRenderedSource(at: view.location, with: text) }
        let popover = NSPopover()
        popover.contentViewController = editor
        popover.behavior = .transient
        popover.delegate = editor
        editor.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        renderedEditor = editor
    }

    func renderedImage(forSource source: String, like block: MarkdownSyntax.FencedCodeBlock) -> NSImage {
        var copy = block
        copy.innerText = source
        return renderedImage(for: copy)
    }

    /// Replaces the source between the block's markers (one undo step; markers untouched).
    func replaceRenderedSource(at location: Int, with text: String) {
        guard let block = MarkdownSyntax.renderedBlocks(in: textView.string).first(where: { $0.group.location == location }),
              text != block.innerText else { return }
        let ns = textView.string as NSString
        let range: NSRange
        let replacement: String
        if block.content.length > 0 {
            let original = ns.substring(with: block.content)
            range = block.content
            replacement = (original.hasPrefix("\n") ? "\n" : "") + text + (original.hasSuffix("\n") ? "\n" : "")
        } else {
            // Empty fence: insert on a line of its own after the opening marker.
            let firstLine = ns.lineRange(for: NSRange(location: block.group.location, length: 0))
            range = NSRange(location: NSMaxRange(firstLine), length: 0)
            replacement = text + "\n"
        }
        let updated = ns.replacingCharacters(in: range, with: replacement)
        textView.applyEdit(EditResult(text: updated, selected: NSRange(location: NSMaxRange(block.group) + ((updated as NSString).length - ns.length), length: 0)))
        relayout()
    }
}

/// Popover editor for a drawn block: source on top, live preview below (Pages-style equations).
final class RenderedSourceEditor: NSViewController, NSTextViewDelegate, NSPopoverDelegate {
    var onCommit: ((String) -> Void)?
    weak var popover: NSPopover?
    private let initial: String
    private let mermaid: Bool
    private let render: (String) -> NSImage
    private let textView = NSTextView()
    private let preview = NSImageView()
    private var committed = false

    init(source: String, mermaid: Bool, render: @escaping (String) -> NSImage) {
        initial = source
        self.mermaid = mermaid
        self.render = render
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: mermaid ? "Mermaid diagram" : "Equation (LaTeX)")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = initial
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = textView
        preview.imageScaling = .scaleProportionallyDown
        preview.image = render(initial)
        let done = NSButton(title: "Done", target: self, action: #selector(commit))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        done.bezelStyle = .push
        let hint = NSTextField(labelWithString: "⌘↩ to apply")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let buttons = NSStackView(views: [hint, NSView(), done])
        let stack = NSStackView(views: [title, scroll, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 420),
            scroll.heightAnchor.constraint(equalToConstant: mermaid ? 150 : 80),
            preview.widthAnchor.constraint(equalToConstant: 420),
            preview.heightAnchor.constraint(lessThanOrEqualToConstant: 260),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            buttons.widthAnchor.constraint(equalToConstant: 420)
        ])
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        preview.image = render(textView.string)
    }

    @objc func commit() {
        guard !committed else { return }
        committed = true
        onCommit?(textView.string)
        popover?.performClose(nil)
    }

    /// Closing the popover by clicking away also applies the edit.
    func popoverWillClose(_ notification: Notification) { commit() }

    // Testing
    func testSetSource(_ text: String) { _ = view; textView.string = text; textDidChange(Notification(name: NSText.didChangeNotification)) }
    var testPreviewSize: CGSize { preview.image?.size ?? .zero }
}
