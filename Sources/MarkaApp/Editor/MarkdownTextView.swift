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

    func applyStyles() {
        guard let storage = textStorage, !isApplyingStyles else { return }
        isApplyingStyles = true
        let selection = selectedRange()
        let um = window?.undoManager ?? undoManager
        um?.disableUndoRegistration()
        StyleEngine.apply(
            to: storage,
            mode: mode,
            settings: editorSettings,
            selection: selection,
            extraBlockSpacing: extraBlockSpacing
        )
        um?.enableUndoRegistration()
        typingAttributes = [
            .font: Theme.bodyFont(editorSettings),
            .foregroundColor: Theme.bodyColor(darkPaper: editorSettings.darkPaper)
        ]
        isApplyingStyles = false
    }

    func applyEdit(_ result: EditResult) {
        let old = string
        let full = NSRange(location: 0, length: (old as NSString).length)
        guard old != result.text else {
            setSelectedRange(result.selected)
            return
        }
        if shouldChangeText(in: full, replacementString: result.text) {
            textStorage?.replaceCharacters(in: full, with: result.text)
            didChangeText()
        }
        setSelectedRange(result.selected)
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

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, !isApplyingStyles {
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

    /// Rounded GitHub-style boxes behind inline code (one per line segment), in view coordinates.
    /// Works with TextKit 2 and with the TextKit 1 fallback AppKit switches to once `layoutManager`
    /// is touched.
    func inlineCodeBoxRects(in area: NSRect? = nil) -> [CGRect] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let origin = textContainerOrigin
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
            let font = (storage.attribute(.font, at: range.location + min(range.length - 1, 1), effectiveRange: nil) as? NSFont)
                ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
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
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        drawInlineCodeBoxes(in: dirtyRect)
        super.draw(dirtyRect)
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
            markdownDelegate?.markdownTextViewDidChangeSelection(self)
        }
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if NSEvent.modifierFlags.contains(.command) {
            let url = (link as? URL)?.absoluteString ?? (link as? String) ?? MarkdownEditing.link(at: charIndex, in: string)?.url
            if let url { Hyperlink.open(url, relativeTo: markdownDelegate?.documentDirectory) }
            return
        }
        setSelectedRange(NSRange(location: charIndex, length: 0))
        snapCaretOutOfLinkMarkers()
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .wysiwyg, event.modifierFlags.contains(.command) {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if let link = MarkdownEditing.link(at: index, in: string) {
                Hyperlink.open(link.url, relativeTo: markdownDelegate?.documentDirectory)
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

    func insertDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"]
        guard imageExts.contains(ext) else {
            let result = MarkdownEditing.insertLink(
                source: string,
                selected: selectedRange(),
                url: url.lastPathComponent
            )
            applyEdit(result)
            return
        }
        let destPath = copyAsset(url)
        let result = MarkdownEditing.insertImage(
            source: string,
            selected: selectedRange(),
            path: destPath,
            alt: url.deletingPathExtension().lastPathComponent
        )
        applyEdit(result)
    }

    func copyAsset(_ url: URL) -> String {
        guard let dir = markdownDelegate?.documentDirectory else {
            return url.path
        }
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var dest = assets.appendingPathComponent(url.lastPathComponent)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = assets.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(i).\(url.pathExtension)")
            i += 1
        }
        try? FileManager.default.copyItem(at: url, to: dest)
        return "assets/\(dest.lastPathComponent)"
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
        styleGeneration += 1
        let gen = styleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.styleGeneration == gen else { return }
            self.applyStyles()
        }
    }
}
