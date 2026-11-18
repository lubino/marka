import AppKit
import MarkaCore

@MainActor
protocol MarkdownTextViewDelegate: AnyObject {
    func markdownTextViewDidChange(_ view: MarkdownTextView)
    func markdownTextView(_ view: MarkdownTextView, didRequestRelayout: Void)
    var documentDirectory: URL? { get }
}

final class MarkdownTextView: NSTextView {
    weak var markdownDelegate: MarkdownTextViewDelegate?
    var mode: EditorMode = .wysiwyg
    var editorSettings = EditorSettings.default
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
        isRichText = true
        importsGraphics = false
        allowsImageEditing = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = true
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
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
    }

    func applyStyles() {
        guard let storage = textStorage, !isApplyingStyles else { return }
        isApplyingStyles = true
        let selection = selectedRange()
        undoManager?.disableUndoRegistration()
        StyleEngine.apply(to: storage, mode: mode, settings: editorSettings, selection: selection)
        undoManager?.enableUndoRegistration()
        typingAttributes = [
            .font: Theme.bodyFont(editorSettings),
            .foregroundColor: Theme.bodyColor(darkPaper: editorSettings.darkPaper)
        ]
        isApplyingStyles = false
    }

    func applyEdit(_ result: EditResult) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        insertText(result.text, replacementRange: full)
        setSelectedRange(result.selected)
    }

    func currentSource() -> String { string }

    override func didChangeText() {
        super.didChangeText()
        markdownDelegate?.markdownTextViewDidChange(self)
        markdownDelegate?.markdownTextView(self, didRequestRelayout: ())
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag {
            applyStyles()
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
        applyEdit(MarkdownEditing.toggleWrap(source: string, selected: selectedRange(), left: "**", right: "**"))
    }

    @objc func toggleItalicsMarkdown(_ sender: Any?) {
        applyEdit(MarkdownEditing.toggleWrap(source: string, selected: selectedRange(), left: "*", right: "*"))
    }

    @objc func toggleStrikethroughMarkdown(_ sender: Any?) {
        applyEdit(MarkdownEditing.toggleWrap(source: string, selected: selectedRange(), left: "~~", right: "~~"))
    }

    @objc func toggleInlineCodeMarkdown(_ sender: Any?) {
        applyEdit(MarkdownEditing.toggleWrap(source: string, selected: selectedRange(), left: "`", right: "`"))
    }

    func applyHeading(_ level: Int) {
        applyEdit(MarkdownEditing.setHeading(source: string, selected: selectedRange(), level: level))
    }

    func applyList(ordered: Bool, task: Bool) {
        applyEdit(MarkdownEditing.toggleList(source: string, selected: selectedRange(), ordered: ordered, task: task))
    }

    func applyLink() {
        let alert = NSAlert()
        alert.messageText = "Insert Link"
        alert.informativeText = "URL"
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "https://")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            applyEdit(MarkdownEditing.insertLink(source: string, selected: selectedRange(), url: field.stringValue))
        }
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

    func applyTable() {
        applyEdit(MarkdownEditing.insertTable(source: string, selected: selectedRange()))
    }

    func applyCodeBlock() {
        applyEdit(MarkdownEditing.insertCodeBlock(source: string, selected: selectedRange()))
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
