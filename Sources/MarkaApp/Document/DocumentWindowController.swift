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
    private var zoomAutoButton: NSButton?
    private var headingPopup: NSPopUpButton?
    private var formatButtons: [NSToolbarItem.Identifier: NSButton] = [:]
    private var actionItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var settingsController: SettingsWindowController?
    private var tablePickerPopover: NSPopover?
    private var isRefreshingToolbar = false
    private var restoredSidebarWidth: CGFloat = 140
    private var sidebarDisplayWidth: CGFloat = 140
    private var sidebarAnimating = false
    private var sidebarAnimFrom: CGFloat = 0
    private var sidebarAnimTo: CGFloat = 0
    private var sidebarAnimStart: TimeInterval = 0
    private var sidebarAnimationTimer: Timer?
    private static let sidebarOpenWidth: CGFloat = 140
    private static let sidebarAnimationDuration: TimeInterval = 0.25
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
        canvas.onEditContextChanged = { [weak self] in
            self?.refreshFormatToolbar()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.title = "Marka"
        window.toolbarStyle = .unified
        window.tabbingMode = .automatic
        self.window = window
        window.contentView = buildContent()
        configureToolbar(window)
        _ = window.toolbar?.items
        applySettings()
        applySidebarVisibility(animated: false)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: SettingsStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillCloseNote), name: NSWindow.willCloseNotification, object: window)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4
        window.initialFirstResponder = textView
        DispatchQueue.main.async { [weak self] in
            self?.applyZoomFromSettings(persist: false)
            self?.focusEditor()
        }
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
        textView.setDocumentText(string)
        textView.applyStyles()
        canvas.relayout()
        applyFitWidthIfNeeded()
        refreshThumbnails(debounce: false)
        refreshStatus()
        refreshFormatToolbar()
        focusEditor()
    }

    func focusEditor() {
        window?.initialFirstResponder = textView
        window?.makeFirstResponder(textView)
    }

    func markdownString() -> String { textView.string }

    var documentDirectory: URL? {
        (document as? MarkdownDocument)?.fileURL?.deletingLastPathComponent()
    }

    func markdownTextViewDidChange(_ view: MarkdownTextView) {
        (document as? MarkdownDocument)?.noteEditorChanged()
        refreshStatus()
        refreshFormatToolbar()
    }

    func markdownTextView(_ view: MarkdownTextView, didRequestRelayout: Void) {
        canvas.queueRelayout()
    }

    func markdownTextViewDidChangeSelection(_ view: MarkdownTextView) {
        canvas.refreshLinkCard()
        refreshFormatToolbar()
    }

    func markdownTextViewDidRequestLinkCard(_ view: MarkdownTextView) {
        canvas.pendingLinkCardFocus = true
        canvas.refreshLinkCard()
    }

    private func buildContent() -> NSView {
        let root = NSView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        sidebar.provider = { [weak self] page in
            guard let self else { return nil }
            return self.canvas.snapshot(page: page, size: self.sidebar.thumbnailImageSize)
        }
        sidebar.onSelectPage = { [weak self] page in
            guard let self else { return }
            self.canvas.scrollToPage(page, in: self.scroll)
        }
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = Theme.canvasColor(darkPaper: SettingsStore.shared.current.darkPaper)
        clip.postsBoundsChangedNotifications = true
        scroll.contentView = clip
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4.0
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.canvasColor(darkPaper: SettingsStore.shared.current.darkPaper)
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(scroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.clipsToBounds = true
        sidebar.clipsToBounds = true

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
        let toolbar = NSToolbar(identifier: "sk.lubino.marka.toolbar.v2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .sidebar, .sidebarTrackingSeparator,
            .heading, .bold, .italic, .strike, .lists, .link, .code, .table, .image,
            .flexibleSpace, .undo, .redo, .find, .share, .zoom, .exportPDF
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            return NSToolbarItem(itemIdentifier: .sidebarTrackingSeparator)
        case .sidebar:
            return buttonItem(itemIdentifier, title: "Sidebar", symbol: "sidebar.left", action: #selector(toggleSidebar))
        case .heading:
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["Paragraph", "Heading 1", "Heading 2", "Heading 3", "Heading 4", "Heading 5", "Heading 6"])
            popup.target = self
            popup.action = #selector(headingChanged(_:))
            popup.refusesFirstResponder = true
            headingPopup = popup
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = popup
            item.label = "Heading"
            return item
        case .bold:
            return toggleItem(itemIdentifier, title: "Bold", symbol: "bold", action: #selector(boldAction))
        case .italic:
            return toggleItem(itemIdentifier, title: "Italic", symbol: "italic", action: #selector(italicAction))
        case .strike:
            return toggleItem(itemIdentifier, title: "Strike", symbol: "strikethrough", action: #selector(strikeAction))
        case .lists:
            return toggleItem(itemIdentifier, title: "List", symbol: "list.bullet", action: #selector(listAction))
        case .link:
            return toggleItem(itemIdentifier, title: "Link", symbol: "link", action: #selector(linkAction))
        case .code:
            return toggleItem(itemIdentifier, title: "Code", symbol: "chevron.left.forwardslash.chevron.right", action: #selector(codeAction))
        case .table:
            return buttonItem(itemIdentifier, title: "Table", symbol: "tablecells", action: #selector(tableAction(_:)))
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
            wrap.spacing = 2
            wrap.alignment = .centerY
            let minus = zoomToolButton(
                image: NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out"),
                tooltip: "Zoom Out",
                action: #selector(zoomOut)
            )
            let auto = zoomToolButton(
                image: ZoomGlyph.autoImage(),
                tooltip: "Auto Width",
                action: #selector(zoomAuto)
            )
            auto.setButtonType(.pushOnPushOff)
            zoomAutoButton = auto
            let plus = zoomToolButton(
                image: NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In"),
                tooltip: "Zoom In",
                action: #selector(zoomIn)
            )
            wrap.addArrangedSubview(minus)
            wrap.addArrangedSubview(auto)
            wrap.addArrangedSubview(plus)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = wrap
            item.label = "Zoom"
            item.paletteLabel = "Zoom"
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
        actionItems[id] = item
        return item
    }

    private func zoomToolButton(image: NSImage?, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = image
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.frame.size = NSSize(width: 32, height: 24)
        button.refusesFirstResponder = true
        return button
    }

    private func toggleItem(_ id: NSToolbarItem.Identifier, title: String, symbol: String, action: Selector) -> NSToolbarItem {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.setButtonType(.pushOnPushOff)
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = title
        button.frame.size = NSSize(width: 32, height: 24)
        button.refusesFirstResponder = true
        formatButtons[id] = button
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title
        item.paletteLabel = title
        item.view = button
        return item
    }

    func currentFormat() -> MarkdownEditing.FormatState {
        MarkdownEditing.format(at: textView.selectedRange(), in: textView.string)
    }

    func currentAvailability() -> MarkdownEditing.FormatAvailability {
        MarkdownEditing.availability(for: currentFormat(), sourceMode: mode == .source)
    }

    func refreshFormatToolbar() {
        guard !isRefreshingToolbar else { return }
        isRefreshingToolbar = true
        defer { isRefreshingToolbar = false }
        let format = currentFormat()
        let available = currentAvailability()
        let heading = max(0, min(6, format.headingLevel))
        if headingPopup?.indexOfSelectedItem != heading {
            headingPopup?.selectItem(at: heading)
        }
        headingPopup?.isEnabled = available.heading
        formatButtons[.bold]?.state = format.bold ? .on : .off
        formatButtons[.italic]?.state = format.italic ? .on : .off
        formatButtons[.strike]?.state = format.strike ? .on : .off
        formatButtons[.lists]?.state = (format.unorderedList || format.orderedList || format.taskList) ? .on : .off
        formatButtons[.link]?.state = format.link ? .on : .off
        formatButtons[.code]?.state = format.inlineCode ? .on : .off
        formatButtons[.bold]?.isEnabled = available.inline
        formatButtons[.italic]?.isEnabled = available.inline
        formatButtons[.strike]?.isEnabled = available.inline
        formatButtons[.lists]?.isEnabled = available.lists
        formatButtons[.link]?.isEnabled = available.link
        formatButtons[.code]?.isEnabled = available.inlineCode
        actionItems[.table]?.isEnabled = available.table
        actionItems[.image]?.isEnabled = available.image
    }

    func splitView(_ splitView: NSSplitView, canCollapse subview: NSView) -> Bool {
        subview === sidebar
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        sidebarDisplayWidth < 1
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        sidebarDisplayWidth < 1 ? 0 : 120
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        sidebarDisplayWidth < 1 ? 0 : min(proposedMaximumPosition, 240)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutSplitPanes()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !sidebarAnimating, sidebarDisplayWidth > 80, sidebar.frame.width > 80 {
            restoredSidebarWidth = sidebar.frame.width
            sidebarDisplayWidth = sidebar.frame.width
        }
    }

    func layoutSplitPanes() {
        let bounds = split.bounds
        let sideW = max(0, sidebarDisplayWidth)
        let divider: CGFloat = sideW < 1 ? 0 : split.dividerThickness
        sidebar.frame = NSRect(x: bounds.minX, y: bounds.minY, width: sideW, height: bounds.height)
        let x = bounds.minX + sideW + divider
        scroll.frame = NSRect(x: x, y: bounds.minY, width: max(0, bounds.maxX - x), height: bounds.height)
    }

    func applySidebarVisibility(animated: Bool = false) {
        let show = SettingsStore.shared.current.showSidebar
        if show {
            restoredSidebarWidth = max(restoredSidebarWidth, Self.sidebarOpenWidth)
        } else if sidebar.frame.width > 80 {
            restoredSidebarWidth = sidebar.frame.width
        }
        let target: CGFloat = show ? min(max(restoredSidebarWidth, 120), 240) : 0
        let from = max(0, sidebar.frame.width)
        sidebarAnimationTimer?.invalidate()
        sidebarAnimationTimer = nil
        if !animated || abs(from - target) < 0.5 {
            finishSidebarAnimation(width: target, shown: show)
            return
        }
        sidebar.isHidden = false
        sidebarAnimating = true
        sidebarAnimFrom = from
        sidebarAnimTo = target
        sidebarAnimStart = ProcessInfo.processInfo.systemUptime
        sidebarDisplayWidth = from
        layoutSplitPanes()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tickSidebarAnimation), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        sidebarAnimationTimer = timer
        tickSidebarAnimation()
    }

    @objc private func tickSidebarAnimation() {
        let duration = Self.sidebarAnimationDuration
        let t = min(1, CGFloat((ProcessInfo.processInfo.systemUptime - sidebarAnimStart) / duration))
        let eased = Self.easeInOut(t)
        sidebarDisplayWidth = sidebarAnimFrom + (sidebarAnimTo - sidebarAnimFrom) * eased
        layoutSplitPanes()
        applyFitWidthIfNeeded()
        split.needsDisplay = true
        if t >= 1 {
            finishSidebarAnimation(width: sidebarAnimTo, shown: sidebarAnimTo >= 1)
        }
    }

    private func finishSidebarAnimation(width: CGFloat, shown: Bool) {
        sidebarAnimationTimer?.invalidate()
        sidebarAnimationTimer = nil
        sidebarAnimating = false
        sidebarDisplayWidth = width
        sidebar.isHidden = !shown
        layoutSplitPanes()
        applyFitWidthIfNeeded()
        window?.invalidateCursorRects(for: split)
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    var testSidebarWidth: CGFloat { sidebar.frame.width }
    var testSidebarHidden: Bool { sidebar.isHidden }
    var testEditorFrame: NSRect { scroll.convert(scroll.bounds, to: split) }
    var testSplitBounds: NSRect { split.bounds }
    var testCodeHeaderCount: Int { canvas.codeHeaderCount }
    var testCodeBackgroundCount: Int { canvas.codeBackgroundCount }
    var testCodeBackgroundsStayOnPages: Bool { canvas.codeBackgroundsStayOnPages() }
    var testTableOverlayCount: Int { canvas.tableOverlayCount }
    var testPageCount: Int { canvas.pageCount }
    var testZoomMode: String { SettingsStore.shared.current.zoomMode }
    var testMagnification: CGFloat { scroll.magnification }
    var testCanvasWidth: CGFloat { canvas.bounds.width }
    var testScrollWidth: CGFloat { scroll.bounds.width }
    var testLinkCardVisible: Bool { canvas.isLinkCardVisible }
    var testLinkCardURL: String { canvas.linkCardURL }
    var testCopyPopupIsTopRight: Bool { canvas.copyPopupIsTopRight() }
    var testCopyButtonHitTestSucceeds: Bool { canvas.copyButtonHitTestSucceeds() }
    var testThumbnailBorderWidth: CGFloat { sidebar.testFirstPageBorderWidth }
    var testThumbnailAspect: CGFloat { sidebar.testFirstPageAspect }
    var testFormat: MarkdownEditing.FormatState { currentFormat() }
    var testHeadingPopupIndex: Int { headingPopup?.indexOfSelectedItem ?? -1 }
    var testBoldToolbarOn: Bool { formatButtons[.bold]?.state == .on }
    var testItalicToolbarOn: Bool { formatButtons[.italic]?.state == .on }
    var testStrikeToolbarOn: Bool { formatButtons[.strike]?.state == .on }
    var testListToolbarOn: Bool { formatButtons[.lists]?.state == .on }
    var testLinkToolbarOn: Bool { formatButtons[.link]?.state == .on }
    var testCodeToolbarOn: Bool { formatButtons[.code]?.state == .on }
    var testBoldToolbarEnabled: Bool { formatButtons[.bold]?.isEnabled ?? false }
    var testHeadingPopupEnabled: Bool { headingPopup?.isEnabled ?? false }
    var testTableToolbarEnabled: Bool { actionItems[.table]?.isEnabled ?? true }
    var testTablesStayOnPages: Bool { canvas.tablesStayOnPages() }
    var testZoomShowsPercent: Bool { false }
    var testZoomAutoOn: Bool { zoomAutoButton?.state == .on }
    var testFirstChipShowsRun: Bool { canvas.firstChipShowsRun }
    var testRunButtonHitTestSucceeds: Bool { canvas.runButtonHitTestSucceeds() }
    var testTableAddColumnChipHitTestSucceeds: Bool { canvas.tableAddColumnChipHitTestSucceeds() }
    var testTableChipsSitOnEdges: Bool { canvas.tableChipsSitOnEdges() }
    var testTableChipIdleAlphaIsTranslucent: Bool { canvas.tableChipIdleAlphaIsTranslucent() }

    func testRelayoutStable() -> Bool {
        let beforePages = canvas.pageCount
        let beforeSpacing = canvas.extraBlockSpacingSnapshot
        canvas.relayout()
        canvas.relayout()
        return canvas.pageCount == beforePages
            && canvas.spacingMatchesForTests(beforeSpacing, canvas.extraBlockSpacingSnapshot)
    }

    func testInsertTableColumn() {
        canvas.insertTableColumn(.right)
        canvas.relayout()
        canvas.restoreTableFieldFocusForTests()
    }

    func testInsertTableRow() {
        canvas.insertTableRow(.below)
        canvas.relayout()
        canvas.restoreTableFieldFocusForTests()
    }

    func testClickAddTableRow() { canvas.clickFirstTableAddRow() }
    func testClickAddTableColumn() { canvas.clickFirstTableAddColumn() }
    func testClickDeleteTableRow() { canvas.clickFirstTableDeleteRow() }
    func testClickDeleteTableColumn() { canvas.clickFirstTableDeleteColumn() }

    var testTableRowCount: Int { canvas.firstTableRowCount }
    var testTableColumnCount: Int { canvas.firstTableColumnCount }
    var testTableHasFieldFocus: Bool { canvas.firstTableHasFieldFocus }

    func testSetManualZoom(_ value: CGFloat) {
        setManualZoom(value)
        window?.layoutIfNeeded()
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    var testPageCenteredHorizontally: Bool {
        window?.layoutIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        scroll.reflectScrolledClipView(scroll.contentView)
        let paper = canvas.paperRect(page: 0)
        let clip = scroll.contentView
        let rect = canvas.convert(paper, to: clip)
        let left = rect.minX - clip.bounds.minX
        let right = clip.bounds.maxX - rect.maxX
        return abs(left - right) < 30
    }

    func testSelect(_ range: NSRange) {
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        canvas.refreshLinkCard()
        refreshFormatToolbar()
    }

    func testCopyFirstCodeBlock() {
        canvas.performFirstCopy()
    }

    func testCopyButtonHoverUsesPointingHand() -> Bool {
        canvas.simulateCopyButtonHover()
    }

    func testType(_ string: String) {
        window?.makeFirstResponder(textView)
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.setSelectedRange(end)
        textView.insertText(string, replacementRange: end)
    }

    func testTypeAtCaret(_ string: String) {
        window?.makeFirstResponder(textView)
        let range = textView.selectedRange()
        textView.insertText(string, replacementRange: range)
    }

    var testEditorIsFirstResponder: Bool { window?.firstResponder === textView }

    func testInsertTable(rows: Int, columns: Int) {
        textView.applyTable(rows: rows, columns: columns)
        canvas.relayout()
        canvas.focusInsertedTable()
        refreshFormatToolbar()
    }

    func testDeleteTableRow() {
        canvas.deleteTableRow()
        canvas.relayout()
    }

    func testDeleteTableColumn() {
        canvas.deleteTableColumn()
        canvas.relayout()
    }

    func testDeleteTable() {
        canvas.deleteTable()
        canvas.relayout()
    }

    func testBold() {
        boldAction()
        refreshFormatToolbar()
    }

    func testHeading(_ level: Int) {
        textView.applyHeading(level)
        refreshFormatToolbar()
    }

    @objc private func settingsChanged() { applySettings() }

    func applySettings() {
        let s = SettingsStore.shared.current
        textView.editorSettings = s
        canvas.geometry = s.geometry
        canvas.darkPaper = s.darkPaper
        let canvasColor = Theme.canvasColor(darkPaper: s.darkPaper)
        scroll.backgroundColor = canvasColor
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = canvasColor
        textView.applyStyles()
        applyZoomFromSettings(persist: false)
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
        refreshZoomLabel()
        window?.title = (document as? MarkdownDocument)?.displayName ?? "Marka"
    }

    @objc func toggleSidebar() {
        var s = SettingsStore.shared.current
        s.showSidebar.toggle()
        SettingsStore.shared.current = s
        applySidebarVisibility(animated: true)
    }

    @objc func headingChanged(_ sender: NSPopUpButton) {
        guard !isRefreshingToolbar else { return }
        textView.applyHeading(sender.indexOfSelectedItem)
        refreshFormatToolbar()
    }

    @objc func applyHeading1() { textView.applyHeading(1); refreshFormatToolbar() }
    @objc func applyHeading2() { textView.applyHeading(2); refreshFormatToolbar() }
    @objc func applyHeading3() { textView.applyHeading(3); refreshFormatToolbar() }

    @objc func boldAction() { textView.toggleBoldfaceMarkdown(nil) }
    @objc func italicAction() { textView.toggleItalicsMarkdown(nil) }
    @objc func strikeAction() { textView.toggleStrikethroughMarkdown(nil) }
    @objc func listAction() { textView.applyList(ordered: false, task: false) }
    @objc func orderedListAction() { textView.applyList(ordered: true, task: false) }
    @objc func taskListAction() { textView.applyList(ordered: false, task: true) }
    @objc func linkAction() { textView.applyLink() }
    @objc func codeAction() { textView.toggleInlineCodeMarkdown(nil) }
    @objc func codeBlockAction() { textView.applyCodeBlock() }
    @objc func tableAction(_ sender: Any? = nil) {
        showTableSizePicker(sender)
    }

    private func showTableSizePicker(_ sender: Any?) {
        let picker = TableSizePickerView(frame: NSRect(origin: .zero, size: TableSizePickerView.preferredSize))
        picker.onPick = { [weak self] columns, rows in
            self?.tablePickerPopover?.performClose(nil)
            self?.tablePickerPopover = nil
            self?.textView.applyTable(rows: rows, columns: columns)
            self?.canvas.relayout()
            self?.canvas.focusInsertedTable()
        }
        let controller = NSViewController()
        controller.view = picker
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = TableSizePickerView.preferredSize
        popover.behavior = .transient
        tablePickerPopover = popover
        if let view = sender as? NSView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let item = sender as? NSToolbarItem, let view = item.view {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            let caret = NSRect(x: 24, y: 24, width: 8, height: 8)
            popover.show(relativeTo: caret, of: textView, preferredEdge: .minY)
        }
    }
    @objc func imageAction() { textView.applyImage() }
    @objc func quoteAction() { textView.applyQuote() }
    @objc func ruleAction() { textView.applyRule() }
    @objc func pageBreakAction() { textView.applyPageBreak() }
    @objc func undoAction() {
        if let editor = window?.fieldEditor(false, for: nil), window?.firstResponder === editor, editor.undoManager?.canUndo == true {
            editor.undoManager?.undo()
            return
        }
        textView.undoMarkdown()
    }

    @objc func redoAction() {
        if let editor = window?.fieldEditor(false, for: nil), window?.firstResponder === editor, editor.undoManager?.canRedo == true {
            editor.undoManager?.redo()
            return
        }
        textView.redoMarkdown()
    }
    @objc func findAction() { window?.makeFirstResponder(textView); textView.performFindPanelAction(self) }

    @objc func toggleSourceMode() {
        mode = (mode == .wysiwyg) ? .source : .wysiwyg
    }

    @objc func zoomIn() { setManualZoom(PageLayout.stepZoom(from: scroll.magnification, delta: 1)) }
    @objc func zoomOut() { setManualZoom(PageLayout.stepZoom(from: scroll.magnification, delta: -1)) }
    @objc func zoomActual() { setManualZoom(1) }
    @objc func zoomFitWidth() { setZoomMode("auto") }
    @objc func zoomAuto() { setZoomMode("auto") }
    @objc func zoomWide() { setZoomMode("wide") }

    @objc private func windowResized() {
        applyFitWidthIfNeeded()
    }

    @objc private func windowWillCloseNote() {
        sidebarAnimationTimer?.invalidate()
        sidebarAnimationTimer = nil
        sidebarAnimating = false
    }

    func setZoomMode(_ mode: String) {
        var s = SettingsStore.shared.current
        s.zoomMode = mode
        if mode == "manual" {
            s.zoomFactor = scroll.magnification
        }
        SettingsStore.shared.current = s
    }

    func setManualZoom(_ value: CGFloat) {
        var s = SettingsStore.shared.current
        s.zoomMode = "manual"
        s.zoomFactor = value
        SettingsStore.shared.current = s
    }

    func applyZoomFromSettings(persist: Bool) {
        let s = SettingsStore.shared.current
        switch s.zoomMode {
        case "wide":
            canvas.horizontalPadding = 0
        case "auto":
            canvas.horizontalPadding = 8
        default:
            canvas.horizontalPadding = PageGeometry.canvasPadding
        }
        canvas.relayout()
        if s.zoomMode == "auto" || s.zoomMode == "wide" {
            scroll.hasHorizontalScroller = false
            let mag = fitWidthMagnification()
            scroll.magnification = mag
            zoomAutoButton?.state = s.zoomMode == "auto" ? .on : .off
        } else {
            scroll.hasHorizontalScroller = true
            scroll.magnification = max(0.25, min(4, s.zoomFactor))
            zoomAutoButton?.state = .off
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        refreshZoomLabel()
        if persist {
            var next = SettingsStore.shared.current
            next.zoomFactor = scroll.magnification
            SettingsStore.shared.current = next
        }
    }

    func applyFitWidthIfNeeded() {
        let mode = SettingsStore.shared.current.zoomMode
        guard mode == "auto" || mode == "wide" else { return }
        scroll.magnification = fitWidthMagnification()
        refreshZoomLabel()
    }

    func fitWidthMagnification() -> CGFloat {
        let scroller = scroll.hasVerticalScroller ? (scroll.verticalScroller?.frame.width ?? 0) : 0
        let available = max(1, scroll.bounds.width - scroller)
        let docWidth = max(1, canvas.bounds.width)
        return max(0.25, min(4, available / docWidth))
    }

    func refreshZoomLabel() {
        zoomAutoButton?.state = SettingsStore.shared.current.zoomMode == "auto" ? .on : .off
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

    @objc func insertTableRowAbove() { canvas.insertTableRow(.above) }
    @objc func insertTableRowBelow() { canvas.insertTableRow(.below) }
    @objc func insertTableColumnLeft() { canvas.insertTableColumn(.left) }
    @objc func insertTableColumnRight() { canvas.insertTableColumn(.right) }
    @objc func addTableRow() { canvas.insertTableRow(.below) }
    @objc func addTableColumn() { canvas.insertTableColumn(.right) }
    @objc func deleteTableRow() { canvas.deleteTableRow() }
    @objc func deleteTableColumn() { canvas.deleteTableColumn() }
    @objc func deleteTable() { canvas.deleteTable() }

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
        let format = currentFormat()
        let available = currentAvailability()
        switch menuItem.action {
        case #selector(boldAction):
            menuItem.state = format.bold ? .on : .off
            return available.inline
        case #selector(italicAction):
            menuItem.state = format.italic ? .on : .off
            return available.inline
        case #selector(strikeAction):
            menuItem.state = format.strike ? .on : .off
            return available.inline
        case #selector(codeAction):
            menuItem.state = format.inlineCode ? .on : .off
            return available.inlineCode
        case #selector(listAction):
            menuItem.state = format.unorderedList ? .on : .off
            return available.lists
        case #selector(orderedListAction):
            menuItem.state = format.orderedList ? .on : .off
            return available.lists
        case #selector(taskListAction):
            menuItem.state = format.taskList ? .on : .off
            return available.lists
        case #selector(quoteAction):
            menuItem.state = format.quote ? .on : .off
            return available.quote
        case #selector(linkAction):
            menuItem.state = format.link ? .on : .off
            return available.link
        case #selector(headingChanged(_:)),
             #selector(applyHeading1),
             #selector(applyHeading2),
             #selector(applyHeading3):
            return available.heading
        case #selector(tableAction(_:)):
            return available.table
        case #selector(imageAction):
            return available.image
        case #selector(codeBlockAction):
            return available.codeBlock
        case #selector(ruleAction):
            return available.rule
        case #selector(pageBreakAction):
            return available.pageBreak
        default:
            break
        }
        switch menuItem.action {
        case #selector(insertTableRowAbove),
             #selector(insertTableRowBelow),
             #selector(insertTableColumnLeft),
             #selector(insertTableColumnRight),
             #selector(addTableRow),
             #selector(addTableColumn):
            return canvas.isEditingTable
        case #selector(deleteTableRow):
            return canvas.canDeleteTableRow
        case #selector(deleteTableColumn):
            return canvas.canDeleteTableColumn
        case #selector(deleteTable):
            return canvas.canDeleteTable
        default:
            return true
        }
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

enum ZoomGlyph {
    static func autoImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            let glass = NSBezierPath(ovalIn: NSRect(x: 1.2, y: 4.6, width: 11.4, height: 11.4))
            glass.lineWidth = 1.35
            glass.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 11.4, y: 5.0))
            handle.line(to: NSPoint(x: 16.2, y: 1.2))
            handle.lineWidth = 1.55
            handle.lineCapStyle = .round
            handle.stroke()
            let letter = "A" as NSString
            letter.draw(
                in: NSRect(x: 3.1, y: 6.0, width: 8, height: 10),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 7.4, weight: .semibold),
                    .foregroundColor: NSColor.black
                ]
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}
