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
    public var thumbnailBorderWidth: CGFloat { controller.testThumbnailBorderWidth }
    public var thumbnailAspect: CGFloat { controller.testThumbnailAspect }
    public var firstChipShowsRun: Bool { controller.testFirstChipShowsRun }
    public var runButtonHitTestSucceeds: Bool { controller.testRunButtonHitTestSucceeds }
    public var format: MarkdownEditing.FormatState { controller.testFormat }
    public var headingPopupIndex: Int { controller.testHeadingPopupIndex }
    public var boldToolbarOn: Bool { controller.testBoldToolbarOn }
    public var italicToolbarOn: Bool { controller.testItalicToolbarOn }
    public var listToolbarOn: Bool { controller.testListToolbarOn }
    public var codeToolbarOn: Bool { controller.testCodeToolbarOn }
    public var boldToolbarEnabled: Bool { controller.testBoldToolbarEnabled }
    public var headingPopupEnabled: Bool { controller.testHeadingPopupEnabled }
    public var tableToolbarEnabled: Bool { controller.testTableToolbarEnabled }
    public var tablesStayOnPages: Bool { controller.testTablesStayOnPages }
    public var zoomAutoOn: Bool { controller.testZoomAutoOn }
    public var tableAddColumnChipHitTestSucceeds: Bool { controller.testTableAddColumnChipHitTestSucceeds }
    public var tableChipsSitOnEdges: Bool { controller.testTableChipsSitOnEdges }
    public var tableChipIdleAlphaIsTranslucent: Bool { controller.testTableChipIdleAlphaIsTranslucent }
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

    public func clickAddTableRow() {
        controller.testClickAddTableRow()
        pump(0.15)
    }

    public func clickAddTableColumn() {
        controller.testClickAddTableColumn()
        pump(0.15)
    }

    public func clickDeleteTableRow() {
        controller.testClickDeleteTableRow()
        pump(0.15)
    }

    public func clickDeleteTableColumn() {
        controller.testClickDeleteTableColumn()
        pump(0.15)
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
        controller.layoutSplitPanes()
    }
}