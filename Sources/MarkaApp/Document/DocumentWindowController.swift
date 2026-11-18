import AppKit
import MarkaCore
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSSplitViewDelegate, MarkdownTextViewDelegate {
    private let split = NSSplitView()
    private let sidebar = ThumbnailSidebar()
    private let scroll = NSScrollView()
    private let status = StatusBarView()
    private let textView: MarkdownTextView
    private let canvas: PagedEditorView
    private var zoomLabel: NSTextField?
    private var headingPopup: NSPopUpButton?
    private var settingsController: SettingsWindowController?
    var mode: EditorMode = .wysiwyg {
        didSet {
            textView.mode = mode
            textView.applyStyles()
            canvas.queueRelayout()
            refreshStatus()
        }
    }

    init() {
        let tv = MarkdownTextView()
        textView = tv
        canvas = PagedEditorView(textView: tv)
        super.init(window: nil)
        tv.markdownDelegate = self
        canvas.onPagesChanged = { [weak self] _ in
            self?.refreshThumbnails(debounce: true)
            self?.refreshStatus()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.title = "Marka"
        window.tabbingMode = .automatic
        self.window = window
        window.contentView = buildContent()
        configureToolbar(window)
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: SettingsStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(document: MarkdownDocument) {
        self.document = document
        canvas.documentDirectory = document.fileURL?.deletingLastPathComponent()
        window?.representedURL = document.fileURL
        refreshStatus()
    }

    func setMarkdown(_ string: String) {
        textView.string = string
        textView.applyStyles()
        canvas.relayout()
        refreshThumbnails(debounce: false)
        refreshStatus()
    }

    func markdownString() -> String { textView.string }

    var documentDirectory: URL? {
        (document as? MarkdownDocument)?.fileURL?.deletingLastPathComponent()
    }

    func markdownTextViewDidChange(_ view: MarkdownTextView) {
        (document as? MarkdownDocument)?.noteEditorChanged()
        refreshStatus()
    }

    func markdownTextView(_ view: MarkdownTextView, didRequestRelayout: Void) {
        canvas.queueRelayout()
    }

    private func buildContent() -> NSView {
        let root = NSView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        sidebar.provider = { [weak self] page in
            guard let self else { return nil }
            let size = NSSize(width: 96, height: 136)
            return self.canvas.snapshot(page: page, size: size)
        }
        sidebar.onSelectPage = { [weak self] page in
            guard let self else { return }
            self.canvas.scrollToPage(page, in: self.scroll)
        }
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 2.0
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.canvasColor(darkPaper: SettingsStore.shared.current.darkPaper)
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(scroll)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        DispatchQueue.main.async { [weak self] in
            self?.split.setPosition(140, ofDividerAt: 0)
        }

        let column = NSStackView(views: [split, status])
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: 24)
        ])
        return root
    }

    private func configureToolbar(_ window: NSWindow) {
        let toolbar = NSToolbar(identifier: "sk.lubino.marka.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .sidebar, .heading, .bold, .italic, .strike, .lists, .link, .code, .table, .image,
            .flexibleSpace, .undo, .redo, .find, .share, .zoom, .exportPDF
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebar:
            return buttonItem(itemIdentifier, title: "Sidebar", symbol: "sidebar.left", action: #selector(toggleSidebar))
        case .heading:
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["Paragraph", "Heading 1", "Heading 2", "Heading 3", "Heading 4", "Heading 5", "Heading 6"])
            popup.target = self
            popup.action = #selector(headingChanged(_:))
            headingPopup = popup
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = popup
            item.label = "Heading"
            return item
        case .bold:
            return buttonItem(itemIdentifier, title: "Bold", symbol: "bold", action: #selector(boldAction))
        case .italic:
            return buttonItem(itemIdentifier, title: "Italic", symbol: "italic", action: #selector(italicAction))
        case .strike:
            return buttonItem(itemIdentifier, title: "Strike", symbol: "strikethrough", action: #selector(strikeAction))
        case .lists:
            return buttonItem(itemIdentifier, title: "List", symbol: "list.bullet", action: #selector(listAction))
        case .link:
            return buttonItem(itemIdentifier, title: "Link", symbol: "link", action: #selector(linkAction))
        case .code:
            return buttonItem(itemIdentifier, title: "Code", symbol: "chevron.left.forwardslash.chevron.right", action: #selector(codeAction))
        case .table:
            return buttonItem(itemIdentifier, title: "Table", symbol: "tablecells", action: #selector(tableAction))
        case .image:
            return buttonItem(itemIdentifier, title: "Image", symbol: "photo", action: #selector(imageAction))
        case .undo:
            return buttonItem(itemIdentifier, title: "Undo", symbol: "arrow.uturn.backward", action: #selector(undoAction))
        case .redo:
            return buttonItem(itemIdentifier, title: "Redo", symbol: "arrow.uturn.forward", action: #selector(redoAction))
        case .find:
            return buttonItem(itemIdentifier, title: "Find", symbol: "magnifyingglass", action: #selector(findAction))
        case .share:
            return buttonItem(itemIdentifier, title: "Share", symbol: "square.and.arrow.up", action: #selector(shareAction(_:)))
        case .zoom:
            let wrap = NSStackView()
            wrap.orientation = .horizontal
            wrap.spacing = 4
            let minus = NSButton(title: "−", target: self, action: #selector(zoomOut))
            let plus = NSButton(title: "+", target: self, action: #selector(zoomIn))
            let label = NSTextField(labelWithString: "100 %")
            label.font = .systemFont(ofSize: 11)
            minus.bezelStyle = .roundRect
            plus.bezelStyle = .roundRect
            wrap.addArrangedSubview(minus)
            wrap.addArrangedSubview(label)
            wrap.addArrangedSubview(plus)
            zoomLabel = label
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = wrap
            item.label = "Zoom"
            return item
        case .exportPDF:
            return buttonItem(itemIdentifier, title: "PDF", symbol: "arrow.down.document", action: #selector(exportPDF))
        default:
            return nil
        }
    }

    private func buttonItem(_ id: NSToolbarItem.Identifier, title: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title
        item.paletteLabel = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        100
    }

    @objc private func settingsChanged() { applySettings() }

    func applySettings() {
        let s = SettingsStore.shared.current
        textView.editorSettings = s
        canvas.geometry = s.geometry
        canvas.darkPaper = s.darkPaper
        scroll.backgroundColor = Theme.canvasColor(darkPaper: s.darkPaper)
        sidebar.isHidden = !s.showSidebar
        textView.applyStyles()
        canvas.relayout()
        refreshStatus()
    }

    @objc private func scrollChanged() {
        refreshStatus()
        sidebar.currentPage = canvas.visiblePageIndex(in: scroll.contentView.bounds)
    }

    func refreshThumbnails(debounce: Bool) {
        sidebar.reload(
            pageCount: canvas.pageCount,
            currentPage: canvas.visiblePageIndex(in: scroll.contentView.bounds),
            debounce: debounce
        )
    }

    func refreshStatus() {
        let source = textView.string
        let page = canvas.visiblePageIndex(in: scroll.contentView.bounds) + 1
        status.update(
            page: page,
            pageCount: canvas.pageCount,
            words: TextMetrics.wordCount(source),
            characters: TextMetrics.characterCount(source),
            path: (document as? MarkdownDocument)?.fileURL?.path ?? "Untitled"
        )
        let pct = Int((scroll.magnification * 100).rounded())
        zoomLabel?.stringValue = "\(pct) %"
        window?.title = (document as? MarkdownDocument)?.displayName ?? "Marka"
    }

    @objc func toggleSidebar() {
        var s = SettingsStore.shared.current
        s.showSidebar.toggle()
        SettingsStore.shared.current = s
    }

    @objc func headingChanged(_ sender: NSPopUpButton) {
        textView.applyHeading(sender.indexOfSelectedItem)
    }

    @objc func boldAction() { textView.toggleBoldfaceMarkdown(nil) }
    @objc func italicAction() { textView.toggleItalicsMarkdown(nil) }
    @objc func strikeAction() { textView.toggleStrikethroughMarkdown(nil) }
    @objc func listAction() { textView.applyList(ordered: false, task: false) }
    @objc func orderedListAction() { textView.applyList(ordered: true, task: false) }
    @objc func taskListAction() { textView.applyList(ordered: false, task: true) }
    @objc func linkAction() { textView.applyLink() }
    @objc func codeAction() { textView.toggleInlineCodeMarkdown(nil) }
    @objc func codeBlockAction() { textView.applyCodeBlock() }
    @objc func tableAction() { textView.applyTable() }
    @objc func imageAction() { textView.applyImage() }
    @objc func quoteAction() { textView.applyQuote() }
    @objc func ruleAction() { textView.applyRule() }
    @objc func pageBreakAction() { textView.applyPageBreak() }
    @objc func undoAction() { window?.firstResponder?.undoManager?.undo() }
    @objc func redoAction() { window?.firstResponder?.undoManager?.redo() }
    @objc func findAction() { window?.makeFirstResponder(textView); textView.performFindPanelAction(self) }

    @objc func toggleSourceMode() {
        mode = (mode == .wysiwyg) ? .source : .wysiwyg
    }

    @objc func zoomIn() { setZoom(PageLayout.stepZoom(from: scroll.magnification, delta: 1)) }
    @objc func zoomOut() { setZoom(PageLayout.stepZoom(from: scroll.magnification, delta: -1)) }
    @objc func zoomActual() { setZoom(1) }
    @objc func zoomFitWidth() {
        let width = scroll.contentView.bounds.width
        let canvasWidth = canvas.geometry.paperSize.width + PageGeometry.canvasPadding * 2
        setZoom(max(0.5, min(2, width / canvasWidth)))
    }

    func setZoom(_ value: CGFloat) {
        scroll.magnification = value
        refreshStatus()
    }

    @objc func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ((document as? MarkdownDocument)?.displayName ?? "Document")
            .replacingOccurrences(of: ".md", with: "") + ".pdf"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try PDFExporter.write(from: self.canvas, to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc func printDocumentAction() {
        PrintController.run(canvas: canvas, from: window)
    }

    @objc func shareAction(_ sender: Any?) {
        var items: [Any] = []
        if let url = (document as? MarkdownDocument)?.fileURL {
            items.append(url)
        } else if let data = PDFExporter.data(from: canvas) {
            items.append(data)
        }
        let picker = NSSharingServicePicker(items: items)
        if let view = (sender as? NSView) ?? window?.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    @objc func addTableRow() { textView.mutateTable(TableMutator.addRow) }
    @objc func addTableColumn() { textView.mutateTable(TableMutator.addColumn) }
    @objc func deleteTableRow() { textView.mutateTable(TableMutator.deleteRow) }
    @objc func deleteTableColumn() { textView.mutateTable(TableMutator.deleteColumn) }

    @objc func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow(self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSourceMode) {
            menuItem.state = mode == .source ? .on : .off
        }
        if menuItem.action == #selector(toggleSidebar) {
            menuItem.state = SettingsStore.shared.current.showSidebar ? .on : .off
        }
        return true
    }
}

extension NSToolbarItem.Identifier {
    static let sidebar = NSToolbarItem.Identifier("sidebar")
    static let heading = NSToolbarItem.Identifier("heading")
    static let bold = NSToolbarItem.Identifier("bold")
    static let italic = NSToolbarItem.Identifier("italic")
    static let strike = NSToolbarItem.Identifier("strike")
    static let lists = NSToolbarItem.Identifier("lists")
    static let link = NSToolbarItem.Identifier("link")
    static let code = NSToolbarItem.Identifier("code")
    static let table = NSToolbarItem.Identifier("table")
    static let image = NSToolbarItem.Identifier("image")
    static let undo = NSToolbarItem.Identifier("undo")
    static let redo = NSToolbarItem.Identifier("redo")
    static let find = NSToolbarItem.Identifier("find")
    static let share = NSToolbarItem.Identifier("share")
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let exportPDF = NSToolbarItem.Identifier("exportPDF")
}
