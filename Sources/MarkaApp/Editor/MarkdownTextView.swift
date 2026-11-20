import AppKit
import MarkaCore

@MainActor
protocol MarkdownTextViewDelegate: AnyObject {
    /// Called before every user/text edit is applied (before restyle and relayout move anything).
    func markdownTextViewWillChange(_ view: MarkdownTextView)
    func markdownTextViewDidChange(_ view: MarkdownTextView)
    func markdownTextView(_ view: MarkdownTextView, didRequestRelayout: Void)
    func markdownTextViewDidChangeSelection(_ view: MarkdownTextView)
    func markdownTextViewDidRequestLinkCard(_ view: MarkdownTextView)
    var documentDirectory: URL? { get }
    /// Work-tree root while the document is tracked by git (files inside it need no copy).
    var trackedRoot: URL? { get }
    var documentFileURL: URL? { get }
    /// `[x](#heading)`: scroll to that heading.
    func markdownTextView(_ view: MarkdownTextView, openAnchor anchor: String)
}

final class MarkdownTextView: NSTextView {
    weak var markdownDelegate: MarkdownTextViewDelegate?
    var mode: EditorMode = .wysiwyg
    var editorSettings = EditorSettings.default
    var extraBlockSpacing: [Int: CGFloat] = [:]
    private var isApplyingStyles = false
    private var styleGeneration: UInt64 = 0
    private var ownedContentStorage: NSTextContentStorage?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init(usingTextLayoutManager flag: Bool = true) {
        if flag {
            let storage = NSTextContentStorage()
            let tlm = NSTextLayoutManager()
            storage.addTextLayoutManager(tlm)
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000_000))
            tlm.textContainer = container
            self.init(frame: .zero, textContainer: container)
            self.ownedContentStorage = storage
        } else {
            self.init(frame: .zero, textContainer: nil)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = true
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsImageEditing = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = true
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        enabledTextCheckingTypes = 0
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesInspectorBar = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainerInset = .zero
        backgroundColor = .clear
        drawsBackground = false
        insertionPointColor = NSColor.controlAccentColor
        usesAdaptiveColorMappingForDarkAppearance = false
        layoutManager?.allowsNonContiguousLayout = true
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        if let storage = textStorage {
            storage.delegate = self
        }
        allowsUndo = true
    }

    override var undoManager: UndoManager? {
        window?.undoManager ?? super.undoManager
    }

    /// Restyles the document, or only `range` (grown to whole lines / blocks) when given.
    func applyStyles(range: NSRange? = nil) {
        guard let storage = textStorage, !isApplyingStyles else { return }
        isApplyingStyles = true
        let selection = selectedRange()
        let um = window?.undoManager ?? undoManager
        um?.disableUndoRegistration()
        // One edit transaction: otherwise every attribute call is processed (and invalidates
        // layout) on its own — hundreds of times per restyle.
        storage.beginEditing()
        StyleEngine.apply(
            to: storage,
            mode: mode,
            settings: editorSettings,
            selection: selection,
            extraBlockSpacing: extraBlockSpacing,
            limit: range
        )
        storage.endEditing()
        um?.enableUndoRegistration()
        typingAttributes = [
            .font: Theme.bodyFont(editorSettings),
            .foregroundColor: Theme.bodyColor(darkPaper: editorSettings.darkPaper)
        ]
        isApplyingStyles = false
    }

    private enum PendingRestyle { case range(NSRange), full }
    private var pendingRestyle: PendingRestyle?

    /// Length of the last range `applyEdit` replaced (tests: edits must stay local).
    private(set) var lastEditLength = 0

    /// Applies an edit as the *smallest* replacement (common prefix / suffix kept), so formatting
    /// and table edits invalidate only the changed lines — replacing the whole text re-laid out the
    /// entire document, re-rendered every thumbnail and made the view jump for a while.
    func applyEdit(_ result: EditResult) {
        let old = string as NSString
        let new = result.text as NSString
        guard (string as String) != result.text else {
            setSelectedRange(result.selected)
            return
        }
        let range = Self.changedRange(old: old, new: new)
        let replacement = new.substring(with: NSRange(location: range.location, length: new.length - (old.length - range.length)))
        lastEditLength = range.length + (replacement as NSString).length
        if shouldChangeText(in: range, replacementString: replacement) {
            textStorage?.replaceCharacters(in: range, with: replacement)
            // Style the changed lines right now, before the window can draw a frame with raw
            // `**` showing; the pending asynchronous restyle is no longer needed.
            pendingRestyle = nil
            styleGeneration += 1
            if forceFullRestyle {
                forceFullRestyle = false
                applyStyles()
            } else {
                applyStyles(range: NSRange(location: range.location, length: (replacement as NSString).length))
            }
            didChangeText()
        }
        setSelectedRange(result.selected)
    }

    /// Range of `old` that differs from `new` (UTF-16), after stripping the common prefix and suffix.
    static func changedRange(old: NSString, new: NSString) -> NSRange {
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        // Never split a surrogate pair.
        if prefix > 0, prefix < old.length, UTF16.isTrailSurrogate(old.character(at: prefix)) { prefix -= 1 }
        return NSRange(location: prefix, length: old.length - prefix - suffix)
    }

    func setDocumentText(_ text: String) {
        let um = window?.undoManager ?? undoManager
        um?.disableUndoRegistration()
        let full = NSRange(location: 0, length: (string as NSString).length)
        textStorage?.replaceCharacters(in: full, with: text)
        um?.enableUndoRegistration()
        um?.removeAllActions(withTarget: self)
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Opens a link target: `#anchor` scrolls to the heading, anything else via `Hyperlink.open`.
    func openLink(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            markdownDelegate?.markdownTextView(self, openAnchor: trimmed)
        } else {
            Hyperlink.open(trimmed, relativeTo: markdownDelegate?.documentDirectory)
        }
    }

    func currentSource() -> String { string }

    /// Window-point test for clickable chrome drawn over the text (code-block icons). The text view
    /// re-applies its I-beam on every mouse move, which would override those views' cursor rects.
    var pointerHotspot: ((NSPoint) -> Bool)?

    override func mouseMoved(with event: NSEvent) {
        if pointerHotspot?(event.locationInWindow) == true {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if pointerHotspot?(event.locationInWindow) == true {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        if string.isEmpty, !text.isEmpty {
            let range = NSRange(location: 0, length: 0)
            if shouldChangeText(in: range, replacementString: text) {
                textStorage?.replaceCharacters(in: range, with: text)
                didChangeText()
            }
            setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            return
        }
        if mode == .wysiwyg, let snapped = MarkdownEditing.snapOutOfHeadingRule(source: string, selected: selectedRange()) {
            setSelectedRange(snapped)
            super.insertText(insertString, replacementRange: snapped)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    /// Characters that open or close blocks reaching beyond the edited lines (fences, tables).
    private static let structural = CharacterSet(charactersIn: "`~|$")
    /// The next restyle must cover the whole document (block structure may have changed elsewhere).
    private var forceFullRestyle = false

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, !isApplyingStyles {
            let ns = string as NSString
            let removed = NSMaxRange(affectedCharRange) <= ns.length ? ns.substring(with: affectedCharRange) : ""
            if removed.rangeOfCharacter(from: Self.structural) != nil
                || (replacementString ?? "").rangeOfCharacter(from: Self.structural) != nil {
                forceFullRestyle = true
            }
            markdownDelegate?.markdownTextViewWillChange(self)
        }
        return allowed
    }

    override func didChangeText() {
        super.didChangeText()
        markdownDelegate?.markdownTextViewDidChange(self)
        markdownDelegate?.markdownTextView(self, didRequestRelayout: ())
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isZ = event.charactersIgnoringModifiers?.lowercased() == "z"
        if isZ, flags.contains(.control) || flags.contains(.command) {
            if flags.contains(.shift) {
                redoMarkdown()
            } else {
                undoMarkdown()
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc func undoMarkdown() {
        (window?.undoManager ?? undoManager)?.undo()
    }

    @objc func redoMarkdown() {
        (window?.undoManager ?? undoManager)?.redo()
    }

    /// Rounded GitHub-style boxes behind inline code (one per line segment), in view coordinates
    /// (or relative to `origin` — the text container's position — for PDF export).
    /// Works with TextKit 2 and with the TextKit 1 fallback AppKit switches to once `layoutManager`
    /// is touched.
    func inlineCodeBoxRects(in area: NSRect? = nil, origin containerOrigin: CGPoint? = nil) -> [CGRect] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let origin = containerOrigin ?? textContainerOrigin
        var boxes: [CGRect] = []
        func add(_ rect: CGRect, font: NSFont) {
            guard rect.width > 1 else { return }
            // Tight around the glyphs: drop the paragraph's extra leading below/above.
            let height = min(rect.height, ceil(font.ascender - font.descender) + 4)
            var box = CGRect(x: rect.minX + origin.x, y: rect.maxY - height + origin.y, width: rect.width, height: height)
            box.origin.y -= max(0, (rect.height - height) * 0.15)
            if let area, !box.intersects(area) { return }
            boxes.append(box)
        }
        storage.enumerateAttribute(.markaInlineCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            // The first visible character's font (hidden markers — backticks, <kbd> tags — are tiny).
            var font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            storage.enumerateAttribute(.font, in: range) { value, _, stop in
                if let candidate = value as? NSFont, candidate.pointSize > 1 { font = candidate; stop.pointee = true }
            }
            if let tlm = textLayoutManager, let content = textContentStorage {
                guard let start = content.location(tlm.documentRange.location, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end) else { return }
                tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                    add(rect, font: font)
                    return true
                }
            } else if let lm = layoutManager, let container = textContainer {
                let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                lm.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    add(rect, font: font)
                }
            }
        }
        return boxes
    }

    /// Line-segment rects of a character range, in text-container coordinates (TextKit 2 or 1).
    func segmentRects(for range: NSRange) -> [CGRect] {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        var rects: [CGRect] = []
        if let tlm = textLayoutManager, let content = textContentStorage {
            guard let start = content.location(tlm.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return [] }
            tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                if rect.width > 0.5 { rects.append(rect) }
                return true
            }
        } else if let lm = layoutManager, let container = textContainer {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                if rect.width > 0.5 { rects.append(rect) }
            }
        }
        return rects
    }

    private func drawInlineCodeBoxes(in dirtyRect: NSRect) {
        let radius = Theme.inlineCodeRadius
        Theme.inlineCodeBox(darkPaper: editorSettings.darkPaper).setFill()
        for box in inlineCodeBoxRects(in: dirtyRect) {
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// Where each hidden inline `$…$` formula is drawn (sitting on the line's baseline).
    func inlineMathPlacements(origin containerOrigin: CGPoint? = nil) -> [(image: NSImage, rect: CGRect)] {
        guard let storage = textStorage, storage.length > 0, mode == .wysiwyg else { return [] }
        let origin = containerOrigin ?? textContainerOrigin
        var placements: [(NSImage, CGRect)] = []
        storage.enumerateAttribute(.markaInlineMath, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let latex = value as? String, range.length > 0 else { return }
            let rendered = MathRenderer.render(latex, fontSize: editorSettings.fontSize,
                                               color: Theme.bodyColor(darkPaper: editorSettings.darkPaper), display: false)
            let size = rendered.image.size
            var x: CGFloat = 0, baseline: CGFloat = 0
            if let lm = layoutManager, textLayoutManager == nil {
                let glyph = lm.glyphIndexForCharacter(at: range.location)
                let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let location = lm.location(forGlyphAt: glyph)
                x = line.minX + location.x
                baseline = line.minY + location.y
            } else if let first = segmentRects(for: NSRange(location: range.location, length: 1)).first {
                x = first.minX
                baseline = first.maxY - abs(Theme.bodyFont(editorSettings).descender)
            } else {
                return
            }
            placements.append((rendered.image, CGRect(x: origin.x + x, y: origin.y + baseline - (size.height - rendered.baseline), width: size.width, height: size.height)))
        }
        // Emoji over hidden :shortcodes: — drawn as text images on the same baseline.
        let body = Theme.bodyFont(editorSettings)
        storage.enumerateAttribute(.markaEmoji, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let emoji = value as? String, range.length > 0 else { return }
            var x: CGFloat = 0, baseline: CGFloat = 0
            if let lm = layoutManager, textLayoutManager == nil {
                let glyph = lm.glyphIndexForCharacter(at: range.location)
                let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let location = lm.location(forGlyphAt: glyph)
                x = line.minX + location.x
                baseline = line.minY + location.y
            } else if let first = segmentRects(for: NSRange(location: range.location, length: 1)).first {
                x = first.minX
                baseline = first.maxY - abs(body.descender)
            } else {
                return
            }
            let text = NSAttributedString(string: emoji, attributes: [.font: body])
            let size = text.size()
            let image = NSImage(size: size, flipped: true) { rect in
                text.draw(at: .zero)
                return true
            }
            // The image's text baseline sits one ascender below its top.
            placements.append((image, CGRect(x: origin.x + x, y: origin.y + baseline - body.ascender, width: size.width, height: size.height)))
        }
        return placements
    }

    func drawInlineCodeBoxesForExport(origin: CGPoint) {
        let radius = Theme.inlineCodeRadius
        Theme.inlineCodeBox(darkPaper: editorSettings.darkPaper).setFill()
        for box in inlineCodeBoxRects(origin: origin) {
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        }
    }

    func drawInlineMathForExport(origin: CGPoint) {
        for placement in inlineMathPlacements(origin: origin) {
            placement.image.draw(in: placement.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Inline extras drawn on top of the glyphs: GitHub code boxes and inline math. `origin` is the
    /// text container's position (PDF export); nil draws in this view.
    func drawInlineExtras(origin: CGPoint? = nil, in area: NSRect? = nil) {
        if origin != nil {
            let radius = Theme.inlineCodeRadius
            Theme.inlineCodeBox(darkPaper: editorSettings.darkPaper).setFill()
            for box in inlineCodeBoxRects(origin: origin) {
                NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            }
        }
        for placement in inlineMathPlacements(origin: origin) {
            if let area, !placement.rect.intersects(area) { continue }
            placement.image.draw(in: placement.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let paged = superview as? PagedEditorView, paged.pageCount > 0 {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath()
            for index in 0..<paged.pageCount {
                var content = paged.paperRect(page: index).insetBy(
                    dx: paged.geometry.margin,
                    dy: paged.geometry.margin
                )
                content.origin.x -= frame.minX
                content.origin.y -= frame.minY
                clip.appendRect(content)
            }
            clip.addClip()
            drawInlineCodeBoxes(in: dirtyRect)
            super.draw(dirtyRect)
            drawInlineExtras(in: dirtyRect)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        drawInlineCodeBoxes(in: dirtyRect)
        super.draw(dirtyRect)
        drawInlineExtras(in: dirtyRect)
    }

    override func becomeFirstResponder() -> Bool {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        smartInsertDeleteEnabled = false
        return super.becomeFirstResponder()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag {
            revealInlineMathIfNeeded()
            markdownDelegate?.markdownTextViewDidChangeSelection(self)
        }
    }

    /// Inline `$…$` the caret is in (its source is shown while editing it).
    private var revealedMathGroup: NSRange?

    /// Show the source of the inline formula the caret enters; hide the one it leaves. Restyles only
    /// those lines (incremental), so the rest of the document never moves.
    private func revealInlineMathIfNeeded() {
        guard mode == .wysiwyg, !isApplyingStyles, let storage = textStorage, storage.length > 0 else { return }
        let caret = selectedRange()
        let group = MarkdownSyntax.spans(in: string).first { span in
            span.kind == .inlineMath && span.role == .content
                && caret.location >= span.group.location && caret.location <= NSMaxRange(span.group)
        }?.group
        guard group != revealedMathGroup else { return }
        let previous = revealedMathGroup
        revealedMathGroup = group
        var dirty: NSRange?
        for range in [previous, group].compactMap({ $0 }) where NSMaxRange(range) <= storage.length {
            dirty = dirty.map { NSUnionRange($0, range) } ?? range
        }
        if let dirty { applyStyles(range: dirty) }
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if NSEvent.modifierFlags.contains(.command) {
            let url = (link as? URL)?.absoluteString ?? (link as? String) ?? MarkdownEditing.link(at: charIndex, in: string)?.url
            if let url { openLink(url) }
            return
        }
        setSelectedRange(NSRange(location: charIndex, length: 0))
        snapCaretOutOfLinkMarkers()
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .wysiwyg, event.modifierFlags.contains(.command) {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if let link = MarkdownEditing.link(at: index, in: string) {
                openLink(link.url)
                return
            }
        }
        super.mouseDown(with: event)
        if mode == .wysiwyg, !event.modifierFlags.contains(.shift) {
            snapCaretOutOfLinkMarkers()
            snapCaretOutOfHeadingRule()
        }
    }

    func snapCaretOutOfHeadingRule() {
        guard mode == .wysiwyg else { return }
        if let snapped = MarkdownEditing.snapOutOfHeadingRule(source: string, selected: selectedRange()) {
            setSelectedRange(snapped)
        }
    }

    /// Hidden `[` / `](url)` markers must not steal the caret; the label stays editable.
    func snapCaretOutOfLinkMarkers() {
        guard mode == .wysiwyg else { return }
        let range = selectedRange()
        guard range.length == 0, let link = MarkdownEditing.link(at: range.location, in: string) else { return }
        let text = link.textRange
        if range.location < text.location {
            setSelectedRange(NSRange(location: text.location, length: 0))
        } else if range.location > NSMaxRange(text) {
            setSelectedRange(NSRange(location: NSMaxRange(text), length: 0))
        }
    }

    override func paste(_ sender: Any?) {
        if let images = NSPasteboard.general.readObjects(forClasses: [NSURL.self, NSImage.self], options: nil),
           let url = images.first as? URL, url.isFileURL {
            insertDroppedFile(url)
            return
        }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            insertDroppedFile(url)
            return true
        }
        return super.performDragOperation(sender)
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "svg", "pdf"]

    /// Inserts a dropped / picked file: images as `![…](…)`, other files as links. Files outside
    /// the document's repository (or folder) ask first: copy next to the document, or reference
    /// the original (`FileReference`).
    func insertDroppedFile(_ url: URL) {
        let isImage = Self.imageExtensions.contains(url.pathExtension.lowercased())
        let selection = selectedRange()
        FileReference.resolve(
            url,
            kind: isImage ? .image : .link,
            documentDirectory: markdownDelegate?.documentDirectory,
            trackedRoot: markdownDelegate?.trackedRoot,
            window: window
        ) { [weak self] path in
            guard let self, let path else { return }
            let source = self.string
            let range = NSRange(location: min(selection.location, (source as NSString).length), length: min(selection.length, max(0, (source as NSString).length - selection.location)))
            let result = isImage
                ? MarkdownEditing.insertImage(source: source, selected: range, path: path, alt: url.deletingPathExtension().lastPathComponent)
                : MarkdownEditing.insertLink(source: source, selected: range, url: path)
            self.applyEdit(result)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(selectedRange().location, max(0, ns.length)), length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        switch MarkdownEditing.handleReturn(currentLine: line) {
        case .insert(let text):
            insertText(text, replacementRange: selectedRange())
        case .replaceLine(let text):
            insertText(text, replacementRange: lineRange)
        }
    }

    override func insertTab(_ sender: Any?) {
        transformCurrentLine { MarkdownEditing.indentListLine($0, indent: true) }
    }

    override func insertBacktab(_ sender: Any?) {
        transformCurrentLine { MarkdownEditing.indentListLine($0, indent: false) }
    }

    private func transformCurrentLine(_ transform: (String) -> String) {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(selectedRange().location, max(0, ns.length)), length: 0))
        var line = ns.substring(with: lineRange)
        var newline = ""
        if line.hasSuffix("\n") {
            newline = "\n"
            line.removeLast()
        }
        let updated = transform(line) + newline
        insertText(updated, replacementRange: lineRange)
    }

    @objc func toggleBoldfaceMarkdown(_ sender: Any?) {
        applyEdit(MarkdownEditing.toggleInline(source: string, selected: selectedRange(), left: "**", right: "**", kind: .strong))
    }

    @objc func toggleItalicsMarkdown(_ sender: Any?) {
        applyEdit(MarkdownEditing.toggleInline(source: string, selected: selectedRange(), left: "*", right: "*", kind: .emphasis))
    }

    @objc func toggleStrikethroughMarkdown(_ sender: Any?) {
        applyEdit(MarkdownEditing.toggleInline(source: string, selected: selectedRange(), left: "~~", right: "~~", kind: .strikethrough))
    }

    @objc func toggleInlineCodeMarkdown(_ sender: Any?) {
        applyEdit(MarkdownEditing.toggleInline(source: string, selected: selectedRange(), left: "`", right: "`", kind: .inlineCode))
    }

    func applyHeading(_ level: Int) {
        applyEdit(MarkdownEditing.setHeading(source: string, selected: selectedRange(), level: level))
    }

    func applyList(ordered: Bool, task: Bool) {
        applyEdit(MarkdownEditing.toggleList(source: string, selected: selectedRange(), ordered: ordered, task: task))
    }

    func applyLink() {
        if MarkdownEditing.link(at: selectedRange().location, in: string) == nil {
            applyEdit(MarkdownEditing.insertLink(source: string, selected: selectedRange(), url: "https://"))
        }
        markdownDelegate?.markdownTextViewDidRequestLinkCard(self)
    }

    func applyImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            insertDroppedFile(url)
        }
    }

    func applyTable(rows: Int = 2, columns: Int = 3) {
        applyEdit(MarkdownEditing.insertTable(source: string, selected: selectedRange(), rows: rows, columns: columns))
    }

    func applyCodeBlock(language: String = "") {
        let selected = selectedRange()
        let format = MarkdownEditing.format(at: selected, in: string)
        if format.inCodeBlock {
            if let retarget = MarkdownEditing.setCodeBlockLanguage(source: string, selected: selected, language: language) {
                applyEdit(retarget)
            }
            return
        }
        applyEdit(MarkdownEditing.insertCodeBlock(source: string, selected: selected, language: language))
    }

    func applyQuote() {
        transformCurrentLine { line in
            if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
            if line.hasPrefix(">") { return String(line.dropFirst()) }
            return "> " + line
        }
    }

    func applyRule() {
        applyEdit(MarkdownEditing.insertHorizontalRule(source: string, selected: selectedRange()))
    }

    func applyPageBreak() {
        applyEdit(MarkdownEditing.insertPageBreak(source: string, selected: selectedRange()))
    }

    func mutateTable(_ op: (String, Int) -> EditResult?) {
        if let result = op(string, selectedRange().location) {
            applyEdit(result)
        }
    }
}

extension MarkdownTextView: @preconcurrency NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard !isApplyingStyles, editedMask.contains(.editedCharacters) else { return }
        // Accumulate what changed since the last restyle (in current coordinates); several edits
        // before it runs fall back to a full restyle, which is always correct.
        if forceFullRestyle {
            forceFullRestyle = false
            pendingRestyle = .full
        } else if pendingRestyle == nil {
            pendingRestyle = .range(editedRange)
        } else if case .range = pendingRestyle {
            pendingRestyle = .full
        }
        styleGeneration += 1
        let gen = styleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.styleGeneration == gen else { return }
            let pending = self.pendingRestyle
            self.pendingRestyle = nil
            switch pending {
            case .range(let range)?: self.applyStyles(range: range)
            default: self.applyStyles()
            }
        }
    }
}
