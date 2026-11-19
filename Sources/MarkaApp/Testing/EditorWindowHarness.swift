import AppKit
import MarkaCore

/// Off-screen AppKit harness for `swift run MarkaUITests` (no XCTest).
@MainActor
public final class EditorWindowHarness {
    let controller: DocumentWindowController

    public init() {
        controller = DocumentWindowController()
        guard let window = controller.window else { return }
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: -4800, y: -4800, width: 1100, height: 760), display: true)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        controller.applySidebarVisibility(animated: false)
        pump()
    }

    public func close() {
        controller.window?.orderOut(nil)
        controller.close()
    }

    public func loadMarkdown(_ string: String) {
        controller.setMarkdown(string)
        pump(0.25)
    }

    public func toggleSidebar() {
        controller.toggleSidebar()
        pump(0.4)
    }

    public func setSourceMode(_ source: Bool) {
        controller.mode = source ? .source : .wysiwyg
        pump(0.2)
    }

    public var sidebarWidth: CGFloat { controller.testSidebarWidth }
    public var sidebarHidden: Bool { controller.testSidebarHidden }
    public var editorFrame: NSRect { controller.testEditorFrame }
    public var splitBounds: NSRect { controller.testSplitBounds }
    public var codeHeaderCount: Int { controller.testCodeHeaderCount }
    public var codeBackgroundCount: Int { controller.testCodeBackgroundCount }
    public var codeBackgroundsStayOnPages: Bool { controller.testCodeBackgroundsStayOnPages }
    public var tableOverlayCount: Int { controller.testTableOverlayCount }
    public var pageCount: Int { controller.testPageCount }
    public var zoomMode: String { controller.testZoomMode }
    public var magnification: CGFloat { controller.testMagnification }
    public var canvasWidth: CGFloat { controller.testCanvasWidth }
    public var scrollWidth: CGFloat { controller.testScrollWidth }
    public var linkCardVisible: Bool { controller.testLinkCardVisible }
    public var linkCardURL: String { controller.testLinkCardURL }

    public func select(_ range: NSRange) {
        controller.testSelect(range)
        pump(0.05)
    }

    public func copyFirstCodeBlock() {
        controller.testCopyFirstCodeBlock()
    }

    public func copyButtonHoverUsesPointingHand() -> Bool {
        controller.testCopyButtonHoverUsesPointingHand()
    }

    public var copyPopupIsTopRight: Bool { controller.testCopyPopupIsTopRight }
    public var copyButtonHitTestSucceeds: Bool { controller.testCopyButtonHitTestSucceeds }
    public var textViewPointerOverCopyIcon: Bool { controller.testTextViewPointerOverCopyIcon }
    public var copyButtonSize: CGSize { controller.testCopyButtonSize }
    public func foregroundHex(at location: Int) -> String? { controller.testForegroundHex(at: location) }
    public var inlineCodeBoxes: [CGRect] { controller.testInlineCodeBoxes }
    public var renderedFrames: [CGRect] { controller.testRenderedFrames }
    public func pageSnapshot(_ page: Int, height: CGFloat, to path: String) { controller.testPageSnapshot(page, height: height, to: URL(fileURLWithPath: path)) }
    public func pdfPageSnapshot(_ page: Int, to path: String) { controller.testPDFPageSnapshot(page, to: URL(fileURLWithPath: path)) }
    public func canvasY(of location: Int) -> CGFloat { controller.testCanvasY(of: location) }
    public func pageContentRect(containing y: CGFloat) -> CGRect? { controller.testPageContentRect(containing: y) }
    public func editRenderedBlock(_ index: Int, newSource: String) { controller.testEditRenderedBlock(index, newSource: newSource); pump(0.3) }
    public var inlineMathPlacements: [CGRect] { controller.testInlineMathPlacements }
    public var pdfPageCount: Int { controller.testPDFPageCount }
    public var visibleTopY: CGFloat { controller.testVisibleTopY }
    public func scrollVisibleTop(to y: CGFloat) { controller.testScrollVisibleTop(to: y); pump(0.05) }
    public var tableScreenTop: CGFloat? { controller.testTableScreenTop }
    public func reapplyZoom() { controller.applyZoomFromSettings(persist: false); pump(0.1) }
    public func setZoom(manual value: CGFloat?) {
        var s = SettingsStore.shared.current
        if let value { s.zoomMode = "manual"; s.zoomFactor = value } else { s.zoomMode = "auto" }
        SettingsStore.shared.current = s
        pump(0.15)
    }
    /// A second document window, as File → New / Open makes it, and its frame.
    public static func newWindowFrame() -> NSRect {
        let controller = DocumentWindowController()
        let frame = controller.window?.frame ?? .zero
        controller.window?.isReleasedWhenClosed = false
        controller.close()
        return frame
    }
    public func moveWindow(to frame: NSRect) {
        controller.window?.setFrame(frame, display: false)
        pump(0.1)
    }
    public static func clearSavedWindowFrame() { DocumentWindowController.forgetSavedFrame() }
    public func pdfLinks(documentDirectory: URL? = nil) -> [(page: Int, url: String, rect: CGRect)] {
        controller.testPDFLinks(documentDirectory: documentDirectory)
    }
    public func visibleSourceCharacters(in range: NSRange) -> [String] { controller.testVisibleSourceCharacters(in: range) }
    /// Runs a search through the find popover's logic; returns its "n of m" label.
    @discardableResult
    public func find(_ query: String, caseSensitive: Bool = false, wholeWord: Bool = false) -> String {
        let result = controller.testFind(query, caseSensitive: caseSensitive, wholeWord: wholeWord).testCountText
        pump(0.05)
        return result
    }
    public func findNext() { controller.findNextAction(); pump(0.05) }
    public func findPrevious() { controller.findPreviousAction(); pump(0.05) }
    public func replaceCurrent(with text: String) {
        let finder = controller.testFind(controller.testFindQuery, replace: text)
        finder.replaceCurrent()
        pump(0.3)
    }
    public func replaceAll(_ query: String, with text: String) -> String {
        let finder = controller.testFind(query, replace: text)
        finder.replaceAll()
        pump(0.3)
        return finder.testCountText
    }
    public var findHighlightCount: Int { controller.testFindHighlightCount }
    public var editAnchor: CGFloat? { controller.testEditAnchor }
    public var findButtonIsViewBased: Bool { controller.testFindButtonIsViewBased }
    public var findLayoutAligned: Bool { controller.testFindLayoutAligned }
    public func findSnapshot(to path: String) { controller.testFindSnapshot(to: URL(fileURLWithPath: path)) }
    public func fontTraits(at location: Int) -> (bold: Bool, italic: Bool, mono: Bool) { controller.testFontTraits(at: location) }
    public func renderedLuminance(atTextViewPoint point: NSPoint) -> CGFloat? { controller.testRenderedLuminance(atTextViewPoint: point) }
    public var caretScreenOffset: CGFloat { controller.testCaretScreenOffset }
    public func scrollCaret(toScreenOffset offset: CGFloat) {
        controller.testScrollCaret(toScreenOffset: offset)
        pump(0.1)
    }
    public func replace(_ range: NSRange, with string: String) {
        controller.testReplace(range, with: string)
        pump(0.5)
    }
    public var copyButtonIsBorderless: Bool { controller.testCopyButtonIsBorderless }
    public var thumbnailBorderWidth: CGFloat { controller.testThumbnailBorderWidth }
    public var thumbnailAspect: CGFloat { controller.testThumbnailAspect }
    public var thumbnailSelectionCornerRadius: CGFloat { controller.testThumbnailSelectionCornerRadius }
    public var thumbnailSelectionUsesAccentStroke: Bool { controller.testThumbnailSelectionUsesAccentStroke }
    public var hasFullSizeContent: Bool { controller.testHasFullSizeContent }
    public var usesSplitViewController: Bool { controller.testUsesSplitViewController }
    public var sidebarIsSystemSidebar: Bool { controller.testSidebarIsSystemSidebar }
    public var thumbnailSelectionContainsNumber: Bool { controller.testThumbnailSelectionContainsNumber }
    public var highlightedThumbnails: [Int] { controller.testHighlightedThumbnails }
    public var pageButtonTitle: String? { controller.testPageButtonTitle }
    public var hasStatusBar: Bool { controller.testHasStatusBar }
    public func documentInfoValue(_ key: String) -> String? { controller.testDocumentInfo().testValue(key) }
    public var documentInfoPath: String { controller.testDocumentInfo().testPath }
    public func enterPageInInfo(_ page: Int) {
        controller.testDocumentInfo().testEnterPage(page)
        pump(0.2)
    }
    public func scrollEditorToPage(_ page: Int) {
        controller.testScrollEditorToPage(page)
        pump(0.2)
    }
    public var sidebarReachesWindowTop: Bool { controller.testSidebarReachesWindowTop }
    public var editorRunsUnderToolbar: Bool { controller.testEditorRunsUnderToolbar }
    public var editorTopInset: CGFloat { controller.testEditorTopInset }
    public var thumbnailBelowTitlebar: Bool { controller.testThumbnailBelowTitlebar }
    public var thumbnailCenteredInPane: Bool { controller.testThumbnailCenteredInPane }
    public var thumbnailUsesSystemScrollers: Bool { controller.testThumbnailUsesSystemScrollers }
    public var thumbnailHorizontalOverflow: CGFloat { controller.testThumbnailHorizontalOverflow }
    public var windowSupportsNativeTabs: Bool { controller.testWindowSupportsNativeTabs }
    public var tabBarVisible: Bool { controller.testTabBarVisible }
    public var hasPageControl: Bool { controller.testHasPageControl }
    public var caretPage: Int { controller.testCaretPage }
    public var visiblePage: Int { controller.testVisiblePage }
    public var thumbnailRenderCount: Int { controller.testThumbnailRenderCount }
    public var thumbnailPageWidth: CGFloat { controller.testThumbnailPageWidth }
    public var thumbnailHasImage: Bool { controller.testThumbnailHasImage }
    public func setSidebarWidth(_ width: CGFloat, pump seconds: TimeInterval = 0) {
        controller.testSetSidebarWidth(width)
        if seconds > 0 { pump(seconds) }
    }
    public func beginSidebarLiveResize() { controller.testBeginSidebarLiveResize() }
    public func endSidebarLiveResize() { controller.testEndSidebarLiveResize() }
    public var documentInfoPageDetail: String { controller.testDocumentInfo().testPageDetail }
    public var documentInfoPathWraps: Bool { controller.testDocumentInfo().testPathWraps }
    public var documentInfoPathHasSideInsets: Bool { controller.testDocumentInfo().testPathHasSideInsets }
    public struct SecondTabResult {
        public var tabCount = 0
        public var barVisibleWithTwoTabs = false
        public var barVisibleAfterClosing = true
        public var tabCountAfterClosing = 0
    }

    /// Opens a second document as File → New would, then closes it again.
    public func openAndCloseSecondDocument() -> SecondTabResult {
        var result = SecondTabResult()
        let second = DocumentWindowController()
        guard let first = controller.window, let window = second.window else { return result }
        window.isReleasedWhenClosed = false
        first.makeKeyAndOrderFront(nil)
        second.showWindow(nil)
        pump(0.3)
        result.tabCount = first.tabbedWindows?.count ?? 1
        result.barVisibleWithTwoTabs = first.tabGroup?.isTabBarVisible ?? false
        window.close()
        pump(0.3)
        result.tabCountAfterClosing = first.tabbedWindows?.count ?? 1
        result.barVisibleAfterClosing = first.tabGroup?.isTabBarVisible ?? true
        return result
    }
    public var documentInfoGoalVisible: Bool { controller.testDocumentInfo().testGoalVisible }
    public var documentInfoGoalProgress: Double { controller.testDocumentInfo().testGoalProgress }
    public var hasSidebarTrackingSeparator: Bool { controller.testHasSidebarTrackingSeparator }
    public var titleFollowsSidebarSeparator: Bool { controller.testTitleFollowsSidebarSeparator }
    public var sidebarItemIsNavigational: Bool { controller.testSidebarItemIsNavigational }
    public var sidebarButtonInSidebarSection: Bool { controller.testSidebarButtonInSidebarSection }
    public var sidebarButtonPlacement: (visible: Bool, gap: CGFloat) { controller.testSidebarButtonVisibleNextToWindowControls }
    public var interPageGap: CGFloat { controller.testInterPageGap }
    public var settingsWindowShowsFontControls: Bool { controller.testSettingsWindowShowsFontControls }
    public var firstChipShowsRun: Bool { controller.testFirstChipShowsRun }
    public var runButtonHitTestSucceeds: Bool { controller.testRunButtonHitTestSucceeds }
    public var format: MarkdownEditing.FormatState { controller.testFormat }
    public var headingPopupIndex: Int { controller.testHeadingPopupIndex }
    public var boldToolbarOn: Bool { controller.testBoldToolbarOn }
    public var boldEnabled: Bool { controller.testBoldEnabled }
    public var lastEditLength: Int { controller.testLastEditLength }
    public func measureRestyle() -> Double { controller.testMeasureRestyle() }
    public var styleSignature: String { controller.testStyleSignature }
    public func measureColdParse() -> Double { controller.testMeasureColdParse() }
    public func measureRelayout() -> Double { controller.testMeasureRelayout() }
    public func fullRestyle() { controller.testFullRestyle(); pump(0.05) }
    public func boldMarkersHiddenImmediately(at range: NSRange) -> (hidden: Bool, ms: Double) { controller.testBoldMarkersHiddenImmediately(at: range) }
    public var lastContentPage: Int { controller.testLastContentPage }
    public var italicToolbarOn: Bool { controller.testItalicToolbarOn }
    public var listToolbarOn: Bool { controller.testListToolbarOn }
    public var codeToolbarOn: Bool { controller.testCodeToolbarOn }
    public var boldToolbarEnabled: Bool { controller.testBoldToolbarEnabled }
    public var headingPopupEnabled: Bool { controller.testHeadingPopupEnabled }
    public var tableToolbarEnabled: Bool { controller.testTableToolbarEnabled }
    public var tablesStayOnPages: Bool { controller.testTablesStayOnPages }
    public var zoomAutoOn: Bool { controller.testZoomAutoOn }
    public var zoomTitle: String { controller.testZoomTitle }
    public var fitMagnification: CGFloat { controller.fitWidthMagnification() }
    public var zoomMenuTitles: [String] { controller.testZoomMenuTitles }
    public var zoomCheckedTitle: String? { controller.zoomCheckedTitle }
    public func chooseZoom(_ title: String) {
        controller.testChooseZoomMenuItem(title)
        pump(0.15)
    }
    public func zoomInStep() {
        controller.zoomIn()
        pump(0.15)
    }
    public var shareToolbarItemIsSystem: Bool { controller.testShareToolbarItemIsSystem }
    public var shareItems: [Any] { controller.shareItems() }
    /// The system item fills its submenu lazily, so check it is AppKit's item and enabled, not a placeholder.
    public var shareMenuItemIsSystem: Bool {
        let item = controller.makeShareMenuItem()
        return !item.title.isEmpty && item.isEnabled && (item.submenu != nil || item.action != nil)
    }
    public var tableHasOnlyGitHubGrid: Bool { controller.testTableHasOnlyGitHubGrid }
    public var tableEditChromeVisible: Bool { controller.testTableEditChromeVisible }
    public func tableCellDisplay(row: Int, column: Int) -> (text: String, bold: Bool)? { controller.testTableCellDisplay(row: row, column: column) }
    public func clickTableCell(row: Int, column: Int) { controller.testClickTableCell(row: row, column: column); pump(0.1) }
    public var selectedTableCell: (row: Int, column: Int)? { controller.testSelectedTableCell }
    public var tableGripsFollowSelection: Bool { controller.testTableGripsFollowSelection }
    /// "up", "down", "left", "right".
    public func cellArrow(_ direction: String) {
        let map: [String: Selector] = [
            "up": #selector(NSResponder.moveUp(_:)), "down": #selector(NSResponder.moveDown(_:)),
            "left": #selector(NSResponder.moveLeft(_:)), "right": #selector(NSResponder.moveRight(_:))
        ]
        if let selector = map[direction] { controller.testCellKey(selector) }
        pump(0.15)
    }
    public var cellEditorState: (text: String, markerHidden: Bool, contentBold: Bool)? { controller.testCellEditorState }
    public func typeInCell(_ text: String, at location: Int) { controller.testTypeInCell(text, at: location); pump(0.1) }
    public func selectInCell(_ range: NSRange) { controller.testSelectInCell(range); pump(0.05) }
    public var tableGripsVisible: (row: Bool, column: Bool) { controller.testTableGripsVisible }
    public var tableBarButtonHit: Bool { controller.testTableBarButtonHit }
    public var tableControlLayout: (visible: Set<String>, placedOnEdges: Bool)? { controller.testTableControlLayout }
    public func tableSnapshot(to path: String) { controller.testTableSnapshot(to: URL(fileURLWithPath: path)) }
    /// "rowAbove", "rowBelow", "columnLeft", "columnRight", "deleteRow", "deleteColumn".
    public func tableBar(_ command: String) {
        let map: [String: PagesTableView.Command] = [
            "rowAbove": .rowAbove, "rowBelow": .rowBelow, "columnLeft": .columnLeft,
            "columnRight": .columnRight, "deleteRow": .deleteRow, "deleteColumn": .deleteColumn
        ]
        if let command = map[command] { controller.testTableBar(command) }
        pump(0.2)
    }
    public func dragTableRow(before row: Int) { controller.testDragTableRow(before: row); pump(0.2) }
    public func dragTableColumn(before column: Int) { controller.testDragTableColumn(before: column); pump(0.2) }
    public var tableButtonIsViewBased: Bool { controller.testTableButtonIsViewBased }
    public var tableMenuEnabled: Bool { controller.testTableMenuEnabled }
    public func retypeCodeBlock(_ language: String) {
        controller.testInsertCodeBlock(language: language)
        pump(0.5)
    }
    /// An untouched untitled document gives way to an opened file; anything typed keeps it.
    public static func pristineUntitledRule() -> (fresh: Bool, typed: Bool) {
        let fresh = MarkdownDocument()
        let typed = MarkdownDocument()
        typed.pendingString = "notes"
        return (MarkaDocumentController.isPristineUntitled(fresh), MarkaDocumentController.isPristineUntitled(typed))
    }
    public static var tablePresets: [(title: String, columns: Int, rows: Int)] {
        TableStylePickerView.presets.map { ($0.title, $0.columns, $0.rows) }
    }
    public func pickTablePreset(_ index: Int) {
        controller.testPickTablePreset(index)
        pump(0.2)
    }
    public var tableCoversHiddenSource: Bool { controller.testTableCoversHiddenSource }
    public var tableSliceCount: Int { controller.testTableSliceCount }
    public var tableRepeatsHeaderOnContinuations: Bool { controller.testTableRepeatsHeader }
    public var codePopupEnabled: Bool { controller.testCodePopupEnabled }
    public var relayoutStable: Bool { controller.testRelayoutStable() }

    public var markdown: String { controller.markdownString() }

    public func typeText(_ string: String) {
        controller.testType(string)
        pump(0.05)
    }

    public func typeAtCaret(_ string: String) {
        controller.testTypeAtCaret(string)
        pump(0.05)
    }

    public var editorIsFirstResponder: Bool { controller.testEditorIsFirstResponder }

    public func undo() {
        controller.undoAction()
        pump(0.1)
    }

    public func insertTable(rows: Int, columns: Int) {
        controller.testInsertTable(rows: rows, columns: columns)
        pump(0.2)
    }

    public func insertCodeBlock(language: String) {
        controller.testInsertCodeBlock(language: language)
        pump(0.15)
    }

    public var selectedRange: NSRange { controller.testSelectedRange }

    public func deleteTableRow() {
        controller.testDeleteTableRow()
        pump(0.15)
    }

    public func deleteTableColumn() {
        controller.testDeleteTableColumn()
        pump(0.15)
    }

    public func insertTableColumn() {
        controller.testInsertTableColumn()
        pump(0.15)
    }

    public func insertTableRow() {
        controller.testInsertTableRow()
        pump(0.15)
    }

    /// Format → Table menu commands (they act on the focused cell).
    public func menuTable(_ command: String) {
        switch command {
        case "rowAbove": controller.insertTableRowAbove()
        case "rowBelow": controller.insertTableRowBelow()
        case "columnLeft": controller.insertTableColumnLeft()
        case "columnRight": controller.insertTableColumnRight()
        case "deleteRow": controller.deleteTableRow()
        case "deleteColumn": controller.deleteTableColumn()
        default: controller.deleteTable()
        }
        pump(0.15)
    }

    public func pressTableTab() {
        controller.testPressTableTab()
        pump(0.15)
    }

    public func pressTableReturn() {
        controller.testPressTableReturn()
        pump(0.15)
    }


    public func focusTableCell(row: Int, column: Int) {
        controller.testFocusTableCell(row: row, column: column)
        pump(0.05)
    }

    public var tableRowCount: Int { controller.testTableRowCount }
    public var tableColumnCount: Int { controller.testTableColumnCount }
    public var tableHasFieldFocus: Bool { controller.testTableHasFieldFocus }
    public var pageCenteredHorizontally: Bool { controller.testPageCenteredHorizontally }

    public func setManualZoom(_ value: CGFloat) {
        controller.testSetManualZoom(value)
        pump(0.1)
    }

    public func deleteTable() {
        controller.testDeleteTable()
        pump(0.15)
    }

    public func toggleBold() {
        controller.testBold()
        pump(0.05)
    }

    public func applyHeading(_ level: Int) {
        controller.testHeading(level)
        pump(0.05)
    }

    public static func markdownClassRegistered() -> Bool {
        NSClassFromString("MarkdownDocument") != nil
    }

    public static func openMarkdownFile(at url: URL, typeName: String) throws -> String {
        let document = try MarkdownDocument(contentsOf: url, ofType: typeName)
        return document.pendingString ?? document.loadedString
    }

    public func pump(_ seconds: TimeInterval = 0.05) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: until)
        }
        controller.window?.layoutIfNeeded()
    }

    /// Renders formulas (one per row) to a PNG sheet — visual checks of the math typesetting.
    public static func renderMathSheet(_ formulas: [String], to path: String, display: Bool = true) -> [Bool] {
        let rendered = formulas.map { MathRenderer.render($0, fontSize: 22, color: .black, display: display) }
        let width = (rendered.map(\.image.size.width).max() ?? 100) + 40
        let height = rendered.reduce(CGFloat(20)) { $0 + $1.image.size.height + 18 }
        let sheet = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var y: CGFloat = 10
            for r in rendered {
                r.image.draw(in: NSRect(x: 20, y: y, width: r.image.size.width, height: r.image.size.height))
                NSColor(calibratedRed: 1, green: 0.3, blue: 0.3, alpha: 0.35).setFill()
                NSRect(x: 12, y: y + r.image.size.height - r.baseline, width: 5, height: 1).fill()   // baseline tick
                y += r.image.size.height + 18
            }
            return true
        }
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        return rendered.map { !$0.hasErrors && $0.image.size.width > 4 }
    }

    /// Renders Mermaid sources (stacked) to a PNG sheet — visual checks of the diagrams.
    public static func renderMermaidSheet(_ sources: [String], to path: String, dark: Bool = false) -> [CGSize] {
        let images = sources.map { MermaidRenderer.render($0, fontSize: 13, dark: dark) }
        let width = (images.map(\.size.width).max() ?? 100) + 40
        let height = images.reduce(CGFloat(20)) { $0 + $1.size.height + 30 }
        let sheet = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var y: CGFloat = 15
            for image in images {
                image.draw(in: NSRect(x: 20, y: y, width: image.size.width, height: image.size.height))
                y += image.size.height + 30
            }
            return true
        }
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        return images.map(\.size)
    }
}
