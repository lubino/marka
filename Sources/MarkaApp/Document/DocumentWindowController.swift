import AppKit
import MarkaCore
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSToolbarDelegate, MarkdownTextViewDelegate,
    NSSharingServicePickerToolbarItemDelegate, FindReplaceTarget {
    /// Preview-style layout: a real sidebar split item gives the full-height (Liquid Glass on macOS 26+)
    /// thumbnail pane with the traffic lights on it, and lets `.sidebarTrackingSeparator` track the divider.
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var lastSidebarWidth: CGFloat = 0
    private let sidebar = ThumbnailSidebar()
    private let scroll = NSScrollView()
    private var pageButton: PageNumberButton?
    private var infoPopover: NSPopover?
    private var infoController: DocumentInfoViewController?
    private var cachedStats: (source: String, stats: DocumentStats)?
    /// Caret's on-screen offset captured before an edit; restored after restyle + relayout settle so
    /// edits (e.g. retyping a fence language) never move the view. TextKit 2 briefly lays out from
    /// estimated heights after a full restyle, which used to drift the view by a line per edit.
    private var editAnchor: CGFloat?
    private var editAnchorTime: TimeInterval = 0
    private let textView: MarkdownTextView
    private let canvas: PagedEditorView
    private var zoomPopup: NSPopUpButton?
    private var sidebarButton: NSButton?
    private var tableButton: NSButton?
    private var findButton: NSButton?
    private var findPopover: NSPopover?
    private lazy var findController: FindReplaceViewController = {
        let controller = FindReplaceViewController()
        controller.target = self
        return controller
    }()
    private var findHighlights: [NSRange] = []
    private var headingPopup: NSPopUpButton?
    private var codePopup: NSPopUpButton?
    private var formatButtons: [NSToolbarItem.Identifier: NSButton] = [:]
    private var actionItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var settingsController: SettingsWindowController?
    private var tablePickerPopover: NSPopover?
    private var isRefreshingToolbar = false
    private static let sidebarOpenWidth: CGFloat = 160
    /// Below ~140 pt the toolbar pushes the thumbnails toggle (it shares the pane with the window
    /// controls) into the overflow menu. 150 pt keeps it visible with a margin.
    static let sidebarMinWidth: CGFloat = 150
    private static let sidebarMaxWidth: CGFloat = 240
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
            self?.restoreEditAnchor()
            self?.refreshThumbnails(debounce: true)
            self?.refreshStatus()
        }
        canvas.onEditContextChanged = { [weak self] in
            self?.refreshFormatToolbar()
            self?.refreshInfoPopover()
        }
        let contentSize = NSSize(width: 1100, height: 760)
        let window = DocumentWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.title = "Marka"
        window.toolbarStyle = .unified
        // Native window tabs: on macOS 26+ the system tab bar already has Preview's rounded glass look.
        // `.preferred`: new documents always join the current window as a tab (Preview-like),
        // regardless of System Settings → "Prefer tabs when opening documents".
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "sk.lubino.marka.document"
        self.window = window
        buildSplit(size: contentSize)
        window.contentViewController = splitController
        window.setContentSize(contentSize)
        configureToolbar(window)
        _ = window.toolbar?.items
        applySettings()
        applySidebarVisibility(animated: false)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: SettingsStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized), name: NSSplitView.didResizeSubviewsNotification, object: splitController.splitView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        // Auto zoom follows the editor's own width (sidebar slide, divider drag, window resize).
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorFrameChanged), name: NSView.frameDidChangeNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(syncTabBar), name: NSWindow.didBecomeKeyNotification, object: window)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4
        window.initialFirstResponder = textView
        DispatchQueue.main.async { [weak self] in
            self?.applyZoomFromSettings(persist: false)
            self?.focusEditor()
            self?.syncTabBar()
        }
    }

    /// New documents join the frontmost document window as a tab (Preview-like). AppKit's automatic
    /// tabbing depends on System Settings and on key-window timing, so attach explicitly.
    override func showWindow(_ sender: Any?) {
        if let window, window.tabbedWindows == nil || window.tabbedWindows?.count == 1,
           let host = Self.tabHost(excluding: window) {
            host.addTabbedWindow(window, ordered: .above)
        }
        super.showWindow(sender)
        DocumentWindow.syncAllTabBars()
    }

    private static func tabHost(excluding window: NSWindow) -> NSWindow? {
        let candidates = NSApp.orderedWindows.filter {
            $0 !== window && $0 is DocumentWindow && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier
        }
        if let main = NSApp.mainWindow, candidates.contains(where: { $0 === main }) { return main }
        return candidates.first
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

    func markdownTextViewWillChange(_ view: MarkdownTextView) {
        // A fresh edit takes a new anchor unless one from this same burst is still settling.
        let now = ProcessInfo.processInfo.systemUptime
        if editAnchor != nil, now - editAnchorTime < 1 { return }
        editAnchor = nil
        let offset = caretScreenOffset()
        let visibleHeight = scroll.contentView.bounds.height * scroll.magnification
        // Only anchor when the caret is on screen; otherwise there is nothing the user is looking at.
        if offset >= 0, offset <= visibleHeight {
            editAnchor = offset
            editAnchorTime = now
        }
    }

    /// Caret line's distance from the top of the clip view, in screen points.
    private func caretScreenOffset() -> CGFloat {
        let y = canvas.caretY(at: textView.selectedRange().location)
        let inCanvas = textView.convert(NSPoint(x: 0, y: y), to: canvas)
        return (inCanvas.y - scroll.contentView.bounds.minY) * scroll.magnification
    }

    private func restoreEditAnchor() {
        guard let anchor = editAnchor else { return }
        if !canvas.hasPendingRelayout { editAnchor = nil }
        let delta = caretScreenOffset() - anchor
        guard abs(delta) > 0.5 else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y += delta / scroll.magnification
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    func markdownTextView(_ view: MarkdownTextView, didRequestRelayout: Void) {
        canvas.queueRelayout()
    }

    func markdownTextViewDidChangeSelection(_ view: MarkdownTextView) {
        canvas.refreshLinkCard()
        refreshFormatToolbar()
        refreshInfoPopover()
    }

    func markdownTextViewDidRequestLinkCard(_ view: MarkdownTextView) {
        canvas.pendingLinkCardFocus = true
        canvas.refreshLinkCard()
    }

    private func buildSplit(size: NSSize) {
        splitController.view.frame = NSRect(origin: .zero, size: size)
        let split = splitController.splitView
        split.isVertical = true
        split.dividerStyle = .thin
        sidebar.provider = { [weak self] page, size in
            self?.canvas.snapshot(page: page, size: size)
        }
        sidebar.onSelectPage = { [weak self] page in
            guard let self else { return }
            self.canvas.scrollToPage(page, in: self.scroll)
        }
        let sidebarController = NSViewController()
        sidebar.frame = NSRect(x: 0, y: 0, width: Self.sidebarOpenWidth, height: size.height)
        sidebarController.view = sidebar
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = Self.sidebarMinWidth
        sidebarItem.maximumThickness = Self.sidebarMaxWidth
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        self.sidebarItem = sidebarItem

        let editorController = NSViewController()
        editorController.view = buildEditorColumn()
        editorController.view.frame = NSRect(x: 0, y: 0, width: size.width - Self.sidebarOpenWidth, height: size.height)
        let editorItem = NSSplitViewItem(viewController: editorController)
        editorItem.minimumThickness = 320

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(editorItem)
        splitController.view.layoutSubtreeIfNeeded()
        split.setPosition(Self.sidebarOpenWidth, ofDividerAt: 0)
    }

    private func buildEditorColumn() -> NSView {
        let root = NSView()
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
        // The editor runs under the (semi-transparent) toolbar; insets keep the first page below it.
        scroll.automaticallyAdjustsContentInsets = true

        // No bottom status bar: page, counts and file info live in the toolbar page-number popover.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return root
    }

    private func configureToolbar(_ window: NSWindow) {
        let toolbar = NSToolbar(identifier: "sk.lubino.marka.toolbar.v7")
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
            .flexibleSpace, .pageInfo, .undo, .redo, .find, .share, .print, .zoom, .exportPDF
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: .sidebarTrackingSeparator,
                splitView: splitController.splitView,
                dividerIndex: 0
            )
        case .sidebar:
            // Lives over the thumbnail pane, next to the window controls: it is placed *before*
            // `.sidebarTrackingSeparator`. Do NOT mark it `isNavigational` — macOS 26 moves navigational
            // items to the leading edge of the content area (the document header).
            let button = NSButton(
                image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Thumbnails") ?? NSImage(),
                target: self,
                action: #selector(toggleSidebar)
            )
            button.bezelStyle = .toolbar
            button.refusesFirstResponder = true
            button.toolTip = "Show or hide thumbnails"
            sidebarButton = button
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Thumbnails"
            item.paletteLabel = "Thumbnails"
            item.visibilityPriority = .user
            return item
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
            let popup = NSPopUpButton()
            popup.pullsDown = true
            popup.bezelStyle = .texturedRounded
            popup.imagePosition = .imageLeading
            popup.refusesFirstResponder = true
            popup.target = self
            popup.action = #selector(codeKindChanged(_:))
            popup.toolTip = "Insert code"
            popup.addItem(withTitle: "")
            popup.item(at: 0)?.image = Self.symbol("curlybraces.square", fallback: "chevron.left.forwardslash.chevron.right")
            let kinds: [(String, String, String)] = [
                ("Inline Code", "chevron.left.forwardslash.chevron.right", "chevron.left.forwardslash.chevron.right"),
                ("Text", "doc.plaintext", "doc.text"),
                ("Bash", "terminal", "terminal"),
                ("Python", "chevron.left.slash.chevron.right", "chevron.left.forwardslash.chevron.right"),
                ("Swift", "swift", "curlybraces"),
                ("JSON", "curlybraces", "curlybraces")
            ]
            for kind in kinds {
                popup.addItem(withTitle: kind.0)
                popup.lastItem?.image = Self.symbol(kind.1, fallback: kind.2)
            }
            codePopup = popup
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = popup
            item.label = "Code"
            item.paletteLabel = "Insert Code"
            item.toolTip = "Insert inline code or a fenced block"
            popup.sizeToFit()
            popup.frame.size = NSSize(width: max(52, popup.frame.width), height: 24)
            return item
        case .table:
            // View-based so the Pages-style gallery can anchor under the button.
            let button = NSButton(
                image: NSImage(systemSymbolName: "tablecells", accessibilityDescription: "Table") ?? NSImage(),
                target: self,
                action: #selector(tableAction(_:))
            )
            button.bezelStyle = .toolbar
            button.refusesFirstResponder = true
            button.toolTip = "Insert table"
            tableButton = button
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Table"
            item.paletteLabel = "Table"
            actionItems[itemIdentifier] = item
            return item
        case .image:
            return buttonItem(itemIdentifier, title: "Image", symbol: "photo", action: #selector(imageAction))
        case .undo:
            return buttonItem(itemIdentifier, title: "Undo", symbol: "arrow.uturn.backward", action: #selector(undoAction))
        case .redo:
            return buttonItem(itemIdentifier, title: "Redo", symbol: "arrow.uturn.forward", action: #selector(redoAction))
        case .find:
            // View-based so the search & replace popover anchors under the button.
            let button = NSButton(
                image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find") ?? NSImage(),
                target: self,
                action: #selector(findAction)
            )
            button.bezelStyle = .toolbar
            button.refusesFirstResponder = true
            button.toolTip = "Find and Replace (⌘F)"
            findButton = button
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Find"
            item.paletteLabel = "Find"
            return item
        case .share:
            // The system share item: AppKit anchors the picker under the button and runs it exactly
            // like Finder / Preview (services, AirDrop, recent people, "Edit Extensions…").
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Share"
            item.paletteLabel = "Share"
            item.toolTip = "Share this document"
            item.delegate = self
            return item
        case .zoom:
            // One Keynote-style pull-down: the title shows the current zoom ("70 %"), the menu lists
            // the presets, then the fit modes with a checkmark on the active one.
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.bezelStyle = .toolbar
            popup.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            popup.refusesFirstResponder = true
            popup.toolTip = "Zoom"
            let menu = popup.menu ?? NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "100 %", action: nil, keyEquivalent: "")   // pull-down title item
            for step in PageGeometry.zoomSteps {
                let item = menu.addItem(withTitle: Self.percentString(step), action: #selector(zoomPresetChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: Double(step))
            }
            menu.addItem(.separator())
            let auto = menu.addItem(withTitle: "Auto", action: #selector(zoomAuto), keyEquivalent: "")
            auto.target = self
            auto.identifier = NSUserInterfaceItemIdentifier("zoom.auto")
            popup.menu = menu
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
            zoomPopup = popup
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = popup
            item.label = "Zoom"
            item.paletteLabel = "Zoom"
            item.visibilityPriority = .high
            refreshZoomLabel()
            return item
        case .pageInfo:
            let button = PageNumberButton(target: self, action: #selector(showDocumentInfo(_:)))
            pageButton = button
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Page"
            item.paletteLabel = "Page & Document Info"
            item.toolTip = "Page number — click for document info"
            item.visibilityPriority = .high
            return item
        case .print:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Print"
            item.paletteLabel = "Print"
            item.toolTip = "Print (⌘P)"
            item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "Print")
            item.action = #selector(NSDocument.printDocument(_:))   // responder chain → the document
            item.isBordered = true
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
        formatButtons[.bold]?.isEnabled = available.inline
        formatButtons[.italic]?.isEnabled = available.inline
        formatButtons[.strike]?.isEnabled = available.inline
        formatButtons[.lists]?.isEnabled = available.lists
        formatButtons[.link]?.isEnabled = available.link
        codePopup?.isEnabled = available.inlineCode || available.codeBlock
        actionItems[.table]?.isEnabled = available.table
        tableButton?.isEnabled = available.table
        actionItems[.image]?.isEnabled = available.image
    }

    private static func symbol(_ name: String, fallback: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
    }

    private var lastEditorWidth: CGFloat = 0

    @objc private func editorFrameChanged() {
        let width = scroll.frame.width
        guard abs(width - lastEditorWidth) > 0.5 else { return }
        lastEditorWidth = width
        applyFitWidthIfNeeded()
    }

    @objc private func splitResized() {
        let width = sidebarItem.isCollapsed ? 0 : sidebar.frame.width
        guard abs(width - lastSidebarWidth) > 0.5 else { return }
        lastSidebarWidth = width
        // Auto zoom follows the editor width while the sidebar slides or is dragged.
        // Thumbnails are NOT re-rendered here: the sidebar scales its cached bitmaps on the GPU
        // and re-renders once at the new size after the drag settles.
        applyFitWidthIfNeeded()
    }

    func applySidebarVisibility(animated: Bool = false) {
        let collapse = !SettingsStore.shared.current.showSidebar
        guard sidebarItem.isCollapsed != collapse else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.sidebarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                sidebarItem.animator().isCollapsed = collapse
            } completionHandler: { [weak self] in
                self?.applyFitWidthIfNeeded()
            }
        } else {
            sidebarItem.isCollapsed = collapse
            splitController.view.layoutSubtreeIfNeeded()
            applyFitWidthIfNeeded()
        }
    }

    var testSidebarWidth: CGFloat { sidebarItem.isCollapsed ? 0 : sidebar.frame.width }
    var testSidebarHidden: Bool { sidebarItem.isCollapsed }
    var testEditorFrame: NSRect { scroll.convert(scroll.bounds, to: splitController.splitView) }
    var testSplitBounds: NSRect { splitController.splitView.bounds }
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
    var testTextViewPointerOverCopyIcon: Bool { canvas.textViewUsesPointerOverCopyIcon() }
    var testCopyButtonSize: CGSize { canvas.firstCopyButtonSize }
    var testInlineCodeBoxes: [CGRect] { textView.inlineCodeBoxRects() }
    func testPDFLinks(documentDirectory: URL?) -> [(page: Int, url: String, rect: CGRect)] {
        canvas.documentDirectory = documentDirectory
        guard let data = PDFExporter.data(from: canvas) else { return [] }
        return PDFExporter.linkAnnotations(in: data)
    }
    /// Characters in `range` that would be visible in the text view (not clear, or a real font size).
    func testVisibleSourceCharacters(in range: NSRange) -> [String] {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return ["<range>"] }
        var visible: [String] = []
        let ns = storage.string as NSString
        for i in range.location..<NSMaxRange(range) {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if ch == "\n" { continue }
            let color = storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
            let font = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            let clear = (color?.alphaComponent ?? 1) < 0.01
            let tiny = (font?.pointSize ?? 12) < 1
            if !(clear && tiny) { visible.append(ch) }
        }
        return visible
    }
    /// (bold, italic, monospaced) of the font at a source offset.
    func testFontTraits(at location: Int) -> (bold: Bool, italic: Bool, mono: Bool) {
        guard let font = textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont else { return (false, false, false) }
        let traits = font.fontDescriptor.symbolicTraits
        return (traits.contains(.bold), traits.contains(.italic), traits.contains(.monoSpace))
    }
    /// Rendered brightness (0…1) at a point in text-view coordinates (draws the canvas off-screen).
    func testRenderedLuminance(atTextViewPoint point: NSPoint) -> CGFloat? {
        let inCanvas = textView.convert(point, to: canvas)
        let area = NSRect(x: inCanvas.x - 4, y: inCanvas.y - 4, width: 8, height: 8)
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: area) else { return nil }
        canvas.cacheDisplay(in: area, to: rep)
        let px = rep.pixelsWide / 2, py = rep.pixelsHigh / 2
        guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
    /// Foreground colour at a source offset, as sRGB hex ("CF222E").
    func testForegroundHex(at location: Int) -> String? {
        guard let storage = textView.textStorage, location < storage.length,
              let color = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor,
              let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    var testCopyButtonIsBorderless: Bool { canvas.firstCopyButtonIsBorderless }
    var testThumbnailBorderWidth: CGFloat { sidebar.testFirstPageBorderWidth }
    var testThumbnailAspect: CGFloat { sidebar.testFirstPageAspect }
    var testThumbnailSelectionCornerRadius: CGFloat { sidebar.testSelectionCornerRadius }
    var testThumbnailSelectionUsesAccentStroke: Bool { sidebar.testSelectionUsesAccentStroke }
    var testHasFullSizeContent: Bool { window?.styleMask.contains(.fullSizeContentView) ?? false }
    var testUsesSplitViewController: Bool { window?.contentViewController === splitController }
    var testSidebarIsSystemSidebar: Bool { sidebarItem.behavior == .sidebar }
    var testThumbnailSelectionContainsNumber: Bool { sidebar.testSelectionContainsNumber }
    var testPageButtonTitle: String? { pageButton?.title }
    var testHasStatusBar: Bool { scroll.superview?.subviews.contains { $0 !== scroll } ?? false }
    func testDocumentInfo() -> DocumentInfoViewController {
        let controller = documentInfoController()
        controller.update(makeDocumentInfo())
        return controller
    }
    var testHighlightedThumbnails: [Int] { sidebar.testHighlightedPages }
    func testScrollEditorToPage(_ page: Int) { canvas.scrollToPage(page, in: scroll) }
    /// Top edge of `view` in window coordinates reaches the window's top (under the titlebar).
    private func reachesWindowTop(_ view: NSView) -> Bool {
        guard let window else { return false }
        let frame = view.convert(view.bounds, to: nil)
        return frame.maxY >= window.frame.height - 1.5
    }
    var testSidebarReachesWindowTop: Bool { reachesWindowTop(sidebar) }
    var testEditorRunsUnderToolbar: Bool { reachesWindowTop(scroll) }
    var testEditorTopInset: CGFloat { scroll.contentInsets.top }
    var testThumbnailBelowTitlebar: Bool {
        guard let window else { return false }
        let page = sidebar.firstPageRectInView(sidebar)
        let inWindow = sidebar.convert(page, to: nil)
        return inWindow.maxY <= window.contentLayoutRect.maxY + 1.5
    }
    var testThumbnailCenteredInPane: Bool { sidebar.testPageCenteredInUsableWidth }
    var testThumbnailUsesSystemScrollers: Bool { sidebar.testUsesSystemScrollerStyle }
    var testThumbnailHorizontalOverflow: CGFloat { sidebar.testHorizontalOverflow }
    var testWindowSupportsNativeTabs: Bool {
        guard let window else { return false }
        return window.tabbingMode == .preferred && window.tabbingIdentifier == "sk.lubino.marka.document"
    }
    var testTabBarVisible: Bool { window?.tabGroup?.isTabBarVisible ?? false }
    var testHasPageControl: Bool { window?.toolbar?.items.contains { $0.itemIdentifier == .pageInfo } ?? false }
    var testCaretPage: Int { canvas.pageIndex(forCharacterAt: textView.selectedRange().location) + 1 }
    var testVisiblePage: Int { canvas.visiblePageIndex(in: scroll.contentView.bounds) + 1 }
    var testThumbnailRenderCount: Int { sidebar.renderCount }
    func testSetSidebarWidth(_ width: CGFloat) {
        splitController.splitView.setPosition(width, ofDividerAt: 0)
        splitController.splitView.layoutSubtreeIfNeeded()
    }
    func testBeginSidebarLiveResize() { sidebar.viewWillStartLiveResize() }
    func testEndSidebarLiveResize() { sidebar.viewDidEndLiveResize() }
    var testThumbnailPageWidth: CGFloat { sidebar.testFirstPageWidth }
    var testThumbnailHasImage: Bool { sidebar.testFirstPageHasImage }
    var testHasSidebarTrackingSeparator: Bool {
        window?.toolbar?.items.contains { $0.itemIdentifier == .sidebarTrackingSeparator } ?? false
    }
    var testTitleFollowsSidebarSeparator: Bool {
        let ids = window?.toolbar?.items.map(\.itemIdentifier) ?? []
        guard let side = ids.firstIndex(of: .sidebar),
              let sep = ids.firstIndex(of: .sidebarTrackingSeparator) else { return false }
        return sep == side + 1
    }
    var testSidebarItemIsNavigational: Bool {
        window?.toolbar?.items.first { $0.itemIdentifier == .sidebar }?.isNavigational ?? true
    }
    /// The sidebar button is the only item in the toolbar's sidebar section (before the tracking separator).
    /// Sidebar toggle is on screen (not in the overflow menu), right of the traffic lights and not under them.
    var testSidebarButtonVisibleNextToWindowControls: (visible: Bool, gap: CGFloat) {
        guard let window, let button = sidebarButton, button.window === window, !button.isHiddenOrHasHiddenAncestor,
              let zoom = window.standardWindowButton(.zoomButton) else { return (false, .infinity) }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let zoomFrame = zoom.convert(zoom.bounds, to: nil)
        return (buttonFrame.width > 1 && buttonFrame.minX >= zoomFrame.maxX - 0.5, buttonFrame.minX - zoomFrame.maxX)
    }
    var testSidebarButtonInSidebarSection: Bool {
        let ids = window?.toolbar?.items.map(\.itemIdentifier) ?? []
        guard let separator = ids.firstIndex(of: .sidebarTrackingSeparator) else { return false }
        return Array(ids[..<separator]) == [.sidebar]
    }
    var testInterPageGap: CGFloat { canvas.geometry.interPageGap }
    var testSettingsWindowShowsFontControls: Bool {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        return settingsController?.hasFontControls ?? false
    }
    var testFormat: MarkdownEditing.FormatState { currentFormat() }
    var testHeadingPopupIndex: Int { headingPopup?.indexOfSelectedItem ?? -1 }
    var testBoldToolbarOn: Bool { formatButtons[.bold]?.state == .on }
    var testItalicToolbarOn: Bool { formatButtons[.italic]?.state == .on }
    var testStrikeToolbarOn: Bool { formatButtons[.strike]?.state == .on }
    var testListToolbarOn: Bool { formatButtons[.lists]?.state == .on }
    var testLinkToolbarOn: Bool { formatButtons[.link]?.state == .on }
    var testCodeToolbarOn: Bool { currentFormat().inlineCode }
    var testCodePopupEnabled: Bool { codePopup?.isEnabled ?? false }
    var testBoldToolbarEnabled: Bool { formatButtons[.bold]?.isEnabled ?? false }
    var testHeadingPopupEnabled: Bool { headingPopup?.isEnabled ?? false }
    var testTableToolbarEnabled: Bool { actionItems[.table]?.isEnabled ?? true }
    var testTablesStayOnPages: Bool { canvas.tablesStayOnPages() }
    var testZoomShowsPercent: Bool { false }
    var testZoomAutoOn: Bool { zoomCheckedTitle == "Auto" }
    var testZoomTitle: String { zoomPopup?.itemArray.first?.title ?? "" }
    var testZoomMenuTitles: [String] { zoomPopup?.itemArray.dropFirst().map(\.title) ?? [] }
    var zoomCheckedTitle: String? { zoomPopup?.itemArray.dropFirst().first { $0.state == .on }?.title }
    func testChooseZoomMenuItem(_ title: String) {
        guard let item = zoomPopup?.itemArray.dropFirst().first(where: { $0.title == title }),
              let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    var testFirstChipShowsRun: Bool { canvas.firstChipShowsRun }
    var testRunButtonHitTestSucceeds: Bool { canvas.runButtonHitTestSucceeds() }
    var testTableHasOnlyGitHubGrid: Bool { canvas.tableHasOnlyGitHubGrid() }
    var testTableEditChromeVisible: Bool { canvas.firstTable?.isEditingChromeVisible ?? false }
    func testTableCellDisplay(row: Int, column: Int) -> (text: String, bold: Bool)? { canvas.firstTable?.testCellDisplay(row: row, column: column) }
    var testTableGripsVisible: (row: Bool, column: Bool) { canvas.firstTable?.testGripsVisible ?? (false, false) }
    var testTableBarButtonHit: Bool { canvas.firstTable?.testBarButtonHit(in: canvas) ?? false }
    func testTableBar(_ command: TableEditBar.Command) { canvas.firstTable?.editBar.perform(command) }
    func testDragTableRow(before row: Int) { canvas.firstTable?.testDragRow(beforeStorageRow: row) }
    func testDragTableColumn(before column: Int) { canvas.firstTable?.testDragColumn(beforeColumn: column) }
    var testTableButtonIsViewBased: Bool { tableButton != nil }
    var testTableCoversHiddenSource: Bool { canvas.tableCoversHiddenSource() }
    var testTableSliceCount: Int { canvas.firstTableSliceCount }
    var testTableRepeatsHeader: Bool { canvas.firstTableRepeatsHeader }

    func testInsertCodeBlock(language: String) {
        insertFence(language)
    }

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

    func testPressTableTab() { canvas.pressFirstTableTab() }
    func testPressTableReturn() { canvas.pressFirstTableReturn() }
    func testFocusTableCell(row: Int, column: Int) { canvas.focusFirstTableCell(row: row, column: column) }

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

    /// Caret line's distance from the top of the visible editor area, in screen points.
    var testCaretScreenOffset: CGFloat {
        let y = canvas.caretY(at: textView.selectedRange().location)
        let inCanvas = textView.convert(NSPoint(x: 0, y: y), to: canvas)
        return (inCanvas.y - scroll.contentView.bounds.minY) * scroll.magnification
    }
    /// Scroll so the caret sits `offset` screen points below the top of the clip view.
    func testScrollCaret(toScreenOffset offset: CGFloat) {
        let y = canvas.caretY(at: textView.selectedRange().location)
        let inCanvas = textView.convert(NSPoint(x: 0, y: y), to: canvas)
        let clip = scroll.contentView
        let origin = NSPoint(x: clip.bounds.minX, y: inCanvas.y - offset / scroll.magnification)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }
    /// Replace `range` the way typing does (one undoable edit through the text view).
    func testReplace(_ range: NSRange, with string: String) {
        window?.makeFirstResponder(textView)
        textView.insertText(string, replacementRange: range)
    }

    var testEditorIsFirstResponder: Bool { window?.firstResponder === textView }
    var testSelectedRange: NSRange { textView.selectedRange() }

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
        applyPageControlVisibility()
        applyZoomFromSettings(persist: false)
        refreshStatus()
    }

    @objc private func scrollChanged() {
        refreshStatus()
        sidebar.showCurrentPage(canvas.visiblePageIndex(in: scroll.contentView.bounds))
    }

    func refreshThumbnails(debounce: Bool) {
        sidebar.reload(
            pageCount: canvas.pageCount,
            currentPage: canvas.visiblePageIndex(in: scroll.contentView.bounds),
            debounce: debounce
        )
    }

    func refreshStatus() {
        let page = canvas.visiblePageIndex(in: scroll.contentView.bounds) + 1
        pageButton?.show(page: page, of: canvas.pageCount)
        refreshInfoPopover()
        refreshZoomLabel()
        window?.title = (document as? MarkdownDocument)?.displayName ?? "Marka"
    }

    // MARK: - Page number / document info popover

    /// Counts are only computed while the popover is open, and cached per source string.
    private func currentStats() -> DocumentStats {
        let source = textView.string
        if let cached = cachedStats, cached.source == source { return cached.stats }
        let stats = DocumentStats.compute(source)
        cachedStats = (source, stats)
        return stats
    }

    @objc private func syncTabBar() {
        DocumentWindow.syncAllTabBars()
    }

    /// Adds or removes the toolbar page control to match Settings.
    private func applyPageControlVisibility() {
        guard let toolbar = window?.toolbar else { return }
        let show = SettingsStore.shared.current.showPageControl
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .pageInfo }
        if !show, let index {
            toolbar.removeItem(at: index)
            pageButton = nil
        } else if show, index == nil {
            let before = toolbar.items.firstIndex { $0.itemIdentifier == .undo } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .pageInfo, at: before)
            refreshStatus()
        }
    }

    func makeDocumentInfo() -> DocumentInfo {
        let doc = document as? MarkdownDocument
        let url = doc?.fileURL
        var size: Int64?
        if let url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = (attrs[.size] as? NSNumber)?.int64Value
        }
        let selected = textView.selectedRanges
            .map(\.rangeValue)
            .filter { $0.length > 0 }
            .map { (textView.string as NSString).substring(with: $0) }
            .joined(separator: " ")
        let page = canvas.visiblePageIndex(in: scroll.contentView.bounds) + 1
        let caret = textView.selectedRange().location
        let pageRanges = canvas.pageTextRanges()
        var pageWords = 0
        if pageRanges.indices.contains(page - 1) {
            let range = pageRanges[page - 1]
            let ns = textView.string as NSString
            if NSMaxRange(range) <= ns.length {
                pageWords = TextMetrics.wordCount(ns.substring(with: range))
            }
        }
        return DocumentInfo(
            page: page,
            pageCount: canvas.pageCount,
            stats: currentStats(),
            selectionWords: TextMetrics.wordCount(selected),
            selectionCharacters: TextMetrics.characterCount(selected),
            fileURL: url,
            codec: doc?.codec ?? FileCodec(),
            isEdited: doc?.isDocumentEdited ?? false,
            fileSize: size,
            modified: doc?.fileModificationDate,
            pageWords: pageWords,
            caretPage: canvas.pageIndex(forCharacterAt: caret) + 1,
            wordGoal: SettingsStore.shared.current.wordGoal
        )
    }

    private func documentInfoController() -> DocumentInfoViewController {
        if let infoController { return infoController }
        let controller = DocumentInfoViewController()
        controller.onGoToPage = { [weak self] page in
            self?.goToPage(page)
        }
        infoController = controller
        return controller
    }

    private func refreshInfoPopover() {
        guard infoPopover?.isShown == true else { return }
        infoController?.update(makeDocumentInfo())
    }

    func goToPage(_ page: Int) {
        let index = min(max(1, page), canvas.pageCount) - 1
        canvas.scrollToPage(index, in: scroll)
        refreshStatus()
    }

    @objc func showDocumentInfo(_ sender: Any?) {
        if let popover = infoPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let controller = documentInfoController()
        controller.update(makeDocumentInfo())
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.behavior = .transient
        infoPopover = popover
        let anchor: NSView? = (sender as? NSView) ?? pageButton.flatMap { $0.window == nil ? nil : $0 }
        if let anchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            let rect = NSRect(x: scroll.bounds.midX, y: scroll.bounds.maxY - 8, width: 1, height: 1)
            popover.show(relativeTo: rect, of: scroll, preferredEdge: .minY)
        }
        // Menu / shortcut entry ("Go to Page…") lands in the page field.
        if !(sender is NSButton) {
            controller.focusPageField()
        }
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
    @objc func codeBlockAction() { insertFence("") }
    @objc func insertPlainCodeBlock() { insertFence("") }
    @objc func insertBashCodeBlock() { insertFence("bash") }
    @objc func insertPythonCodeBlock() { insertFence("python") }
    @objc func insertSwiftCodeBlock() { insertFence("swift") }
    @objc func insertJSONCodeBlock() { insertFence("json") }

    @objc func codeKindChanged(_ sender: NSPopUpButton) {
        guard !isRefreshingToolbar else { return }
        let title = sender.titleOfSelectedItem ?? ""
        sender.selectItem(at: 0)
        switch title {
        case "Inline Code":
            textView.toggleInlineCodeMarkdown(nil)
        case "Text":
            insertFence("")
        case "Bash":
            insertFence("bash")
        case "Python":
            insertFence("python")
        case "Swift":
            insertFence("swift")
        case "JSON":
            insertFence("json")
        default:
            break
        }
        refreshFormatToolbar()
    }

    private func insertFence(_ language: String) {
        textView.applyCodeBlock(language: language)
        canvas.relayout()
        window?.makeFirstResponder(textView)
        refreshFormatToolbar()
    }
    @objc func tableAction(_ sender: Any? = nil) {
        showTableSizePicker(sender)
    }

    /// Pages-style: the Table button opens a gallery of table shapes; one click inserts it.
    private func showTableSizePicker(_ sender: Any?) {
        let picker = makeTablePicker()
        let controller = NSViewController()
        controller.view = picker
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = TableStylePickerView.preferredSize
        popover.behavior = .transient
        tablePickerPopover = popover
        // Toolbar button → under the button; menu (Format → Insert Table) → at the caret.
        if let view = (sender as? NSView) ?? (tableButton?.window != nil ? tableButton : nil) {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            let local = textView.window.map { textView.convert($0.convertFromScreen(caret), from: nil) }
                ?? NSRect(x: 24, y: 24, width: 8, height: 8)
            popover.show(relativeTo: local.insetBy(dx: 0, dy: -2), of: textView, preferredEdge: .maxY)
        }
    }

    private func makeTablePicker() -> TableStylePickerView {
        let picker = TableStylePickerView(frame: NSRect(origin: .zero, size: TableStylePickerView.preferredSize))
        picker.darkPaper = SettingsStore.shared.current.darkPaper
        picker.onPick = { [weak self] preset in
            self?.tablePickerPopover?.performClose(nil)
            self?.tablePickerPopover = nil
            self?.insertTable(preset)
        }
        return picker
    }

    private func insertTable(_ preset: TableStylePickerView.Preset) {
        // `applyTable` counts the header as a row.
        textView.applyTable(rows: preset.rows + 1, columns: preset.columns)
        canvas.relayout()
        canvas.focusInsertedTable()
        refreshFormatToolbar()
    }

    /// Picks gallery tile `index` exactly as a click would.
    func testPickTablePreset(_ index: Int) {
        makeTablePicker().pick(index)
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
    // MARK: - Find & replace

    @objc func findAction() { showFindReplace(focusReplace: false) }
    @objc func findAndReplaceAction() { showFindReplace(focusReplace: true) }
    @objc func findNextAction() { findController.findNext() }
    @objc func findPreviousAction() { findController.findPrevious() }

    func showFindReplace(focusReplace: Bool) {
        if let popover = findPopover, popover.isShown {
            focusReplace ? findController.focusReplace() : findController.focusFind()
            return
        }
        let popover = NSPopover()
        popover.contentViewController = findController
        popover.behavior = .semitransient
        popover.delegate = findController
        findPopover = popover
        // Seed with the selected text, like the system find bar.
        let selected = textView.selectedRange()
        if selected.length > 0, selected.length < 200 {
            findController.view.layoutSubtreeIfNeeded()
            findController.findField.stringValue = (textView.string as NSString).substring(with: selected)
        }
        if let anchor = findButton, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            let rect = NSRect(x: scroll.bounds.maxX - 40, y: scroll.bounds.maxY - 8, width: 1, height: 1)
            popover.show(relativeTo: rect, of: scroll, preferredEdge: .minY)
        }
        focusReplace ? findController.focusReplace() : findController.focusFind()
        findController.search(keepCurrent: false)
    }

    var findSource: String { textView.string }
    var findCaret: Int { textView.selectedRange().location }

    func showFindMatches(_ matches: [NSRange], current: NSRange?) {
        clearFindHighlights()
        let length = (textView.string as NSString).length
        let valid = matches.filter { NSMaxRange($0) <= length }
        let color = NSColor.findHighlightColor.withAlphaComponent(0.45)
        if let lm = textView.layoutManager, textView.textLayoutManager == nil {
            for range in valid { lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range) }
        } else if let tlm = textView.textLayoutManager, let content = textView.textContentStorage {
            for range in valid {
                guard let start = content.location(tlm.documentRange.location, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end) else { continue }
                tlm.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
            }
        }
        findHighlights = valid
        if let current, NSMaxRange(current) <= length {
            textView.setSelectedRange(current)
            textView.scrollRangeToVisible(current)
            textView.showFindIndicator(for: current)
        }
    }

    private func clearFindHighlights() {
        guard !findHighlights.isEmpty else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        if let lm = textView.layoutManager, textView.textLayoutManager == nil {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        } else if let tlm = textView.textLayoutManager {
            tlm.removeRenderingAttribute(.backgroundColor, for: tlm.documentRange)
        }
        findHighlights = []
    }

    func replaceFindMatch(_ range: NSRange, with replacement: String) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        // One undoable edit through the normal typing path (keeps the view anchored too).
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
    }

    func replaceAllFindMatches(with text: String, count: Int) {
        let caret = min(textView.selectedRange().location, (text as NSString).length)
        textView.applyEdit(EditResult(text: text, selected: NSRange(location: caret, length: 0)))
        canvas.relayout()
    }

    func endFind() {
        clearFindHighlights()
        findPopover = nil
        window?.makeFirstResponder(textView)
    }

    /// Drives the find popover's logic without showing it (UI tests).
    func testFind(_ query: String, replace: String? = nil, caseSensitive: Bool = false, wholeWord: Bool = false) -> FindReplaceViewController {
        let controller = findController
        controller.testSetOptions(caseSensitive: caseSensitive, wholeWord: wholeWord)
        controller.findField.stringValue = query
        if let replace { controller.replaceField.stringValue = replace }
        controller.search(keepCurrent: false)
        return controller
    }
    var testFindHighlightCount: Int { findHighlights.count }
    var testFindQuery: String { findController.findField.stringValue }
    var testEditAnchor: CGFloat? { editAnchor }
    var testHasPendingRelayout: Bool { canvas.hasPendingRelayout }
    var testFindButtonIsViewBased: Bool { findButton != nil }

    @objc func toggleSourceMode() {
        mode = (mode == .wysiwyg) ? .source : .wysiwyg
    }

    @objc func zoomIn() { setManualZoom(PageLayout.stepZoom(from: scroll.magnification, delta: 1)) }
    @objc func zoomOut() { setManualZoom(PageLayout.stepZoom(from: scroll.magnification, delta: -1)) }
    @objc func zoomActual() { setManualZoom(1) }
    @objc func zoomAuto() { setZoomMode("auto") }

    @objc private func windowResized() {
        applyFitWidthIfNeeded()
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
        canvas.horizontalPadding = s.zoomMode == "auto" ? 8 : PageGeometry.canvasPadding
        canvas.relayout()
        if s.zoomMode == "auto" {
            scroll.hasHorizontalScroller = false
            let mag = fitWidthMagnification()
            scroll.magnification = mag
        } else {
            scroll.hasHorizontalScroller = true
            scroll.magnification = max(0.25, min(4, s.zoomFactor))
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
        guard mode == "auto" else { return }
        scroll.magnification = fitWidthMagnification()
        refreshZoomLabel()
    }

    func fitWidthMagnification() -> CGFloat {
        let scroller = scroll.hasVerticalScroller ? (scroll.verticalScroller?.frame.width ?? 0) : 0
        let available = max(1, scroll.bounds.width - scroller)
        let docWidth = max(1, canvas.bounds.width)
        return max(0.25, min(4, available / docWidth))
    }

    static let autoZoomTitle = "Auto %"

    static func percentString(_ magnification: CGFloat) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        let text = formatter.string(from: NSNumber(value: Double(magnification))) ?? "\(Int((magnification * 100).rounded())) %"
        // NSMenuItem turns no-break spaces ("70 %" in many locales) into plain ones; match that.
        return text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Title follows the live magnification (also during pinch); the checkmark marks the active mode.
    func refreshZoomLabel() {
        guard let popup = zoomPopup else { return }
        let items = popup.itemArray
        // Auto shows "Auto %" — the percentage changes with the window, the mode is what matters.
        let title = SettingsStore.shared.current.zoomMode == "auto" ? Self.autoZoomTitle : Self.percentString(scroll.magnification)
        if items.first?.title != title { items.first?.title = title }
        let s = SettingsStore.shared.current
        for item in items.dropFirst() {
            let on: Bool
            switch item.identifier?.rawValue {
            case "zoom.auto": on = s.zoomMode == "auto"
            default:
                let step = (item.representedObject as? NSNumber).map { CGFloat($0.doubleValue) }
                on = s.zoomMode == "manual" && step.map { abs($0 - scroll.magnification) < 0.005 } == true
            }
            item.state = on ? .on : .off
        }
    }

    @objc func zoomPresetChosen(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        setManualZoom(CGFloat(number.doubleValue))
    }

    /// Pinch-zoom ends in manual mode at whatever magnification the user chose.
    @objc private func liveMagnifyEnded() {
        setManualZoom(max(0.25, min(4, scroll.magnification)))
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

    func makePrintOperation(printInfo: NSPrintInfo) -> NSPrintOperation {
        PrintController.operation(canvas: canvas, title: window?.title, printInfo: printInfo)
    }

    /// Kept for callers without a document (tests); the menu and toolbar use `NSDocument.printDocument(_:)`.
    @objc func printDocumentAction() {
        let op = makePrintOperation(printInfo: NSPrintInfo.shared)
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    // MARK: - Share

    /// What gets shared: the document's own `.md` file, like any document app.
    /// Unsaved edits are autosaved first (the service reads the file only after the user picks it).
    /// An untitled document is shared as a temporary `<name>.md` holding the current text.
    func shareItems() -> [Any] {
        let doc = document as? MarkdownDocument
        if let doc, let url = doc.fileURL {
            if doc.isDocumentEdited {
                doc.autosave(withImplicitCancellability: false) { _ in }
            }
            return [url]
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Marka Share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let title = doc?.displayName ?? "Untitled"
        let name = title.hasSuffix(".md") ? title : title + ".md"
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(markdownString().utf8).write(to: url)
            return [url]
        } catch {
            return [markdownString()]
        }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        shareItems()
    }

    /// File → Share: the standard system Share submenu for this document.
    func makeShareMenuItem() -> NSMenuItem {
        let picker = NSSharingServicePicker(items: shareItems())
        return picker.standardShareMenuItem
    }

    var testShareToolbarItemIsSystem: Bool {
        window?.toolbar?.items.contains { $0.itemIdentifier == .share && $0 is NSSharingServicePickerToolbarItem } ?? false
    }

    private static let tableEditActions: Set<Selector> = [
        #selector(insertTableRowAbove), #selector(insertTableRowBelow),
        #selector(insertTableColumnLeft), #selector(insertTableColumnRight),
        #selector(addTableRow), #selector(addTableColumn),
        #selector(deleteTableRow), #selector(deleteTableColumn), #selector(deleteTable)
    ]

    var testTableMenuEnabled: Bool {
        let item = NSMenuItem(title: "Delete Row", action: #selector(deleteTableRow), keyEquivalent: "")
        return validateMenuItem(item)
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
        // Format → Table row/column commands only apply with the cursor in a table cell.
        if let action = menuItem.action, Self.tableEditActions.contains(action) {
            return canvas.isEditingTable
        }
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
        case #selector(codeBlockAction),
             #selector(insertPlainCodeBlock),
             #selector(insertBashCodeBlock),
             #selector(insertPythonCodeBlock),
             #selector(insertSwiftCodeBlock),
             #selector(insertJSONCodeBlock):
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
    static let pageInfo = NSToolbarItem.Identifier("pageInfo")
    static let print = NSToolbarItem.Identifier("print")
}
