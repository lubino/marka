import AppKit
import Foundation
import MarkaCore
import MarkaUI

@main
@MainActor
enum MarkaUITests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        _ = app
        var failed = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                fputs("FAIL: \(message)\n", stderr)
                failed += 1
            }
        }
        func expectEqualPasteboard(_ got: String?, _ expected: String, _ message: String) {
            expect(got == expected, "\(message) — got \(got ?? "nil"), expected \(expected)")
        }

        expect(EditorWindowHarness.markdownClassRegistered(), "NSDocument subclass is visible as MarkdownDocument")
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AGENTS.md")
            try Data("# Title\n\nHello\n".utf8).write(to: url)
            let byName = try EditorWindowHarness.openMarkdownFile(at: url, typeName: "Markdown Document")
            expect(byName.contains("Hello"), "open using CFBundleTypeName Markdown Document")
            let byUTI = try EditorWindowHarness.openMarkdownFile(at: url, typeName: "net.daringfireball.markdown")
            expect(byUTI.contains("Title"), "open using markdown UTI")
        } catch {
            expect(false, "opening .md failed: \(error)")
        }

        let saved = SettingsStore.shared.current
        var start = saved
        start.showSidebar = true
        start.zoomMode = "auto"
        start.zoomFactor = 1
        SettingsStore.shared.current = start
        let harness = EditorWindowHarness()
        defer {
            harness.close()
            SettingsStore.shared.current = saved
        }

        expect(harness.zoomMode == "auto", "default zoom is Auto")
        expect(harness.zoomAutoOn, "Auto zoom button is on in Auto mode")
        expect(harness.pageCenteredHorizontally, "Auto zoom keeps the page centered")
        harness.pump(0.1)
        let filled = harness.canvasWidth * harness.magnification
        expect(
            abs(filled - harness.scrollWidth) < 120 || filled >= harness.scrollWidth - 40,
            "Auto fills window width (canvas \(harness.canvasWidth) × \(harness.magnification) vs scroll \(harness.scrollWidth))"
        )

        expect(harness.splitBounds.width > 400, "split view has width")
        expect(harness.sidebarHidden == false, "sidebar starts visible")
        expect(harness.sidebarWidth >= 120, "open sidebar has pane width, got \(harness.sidebarWidth)")
        expect(harness.editorFrame.minX >= 120, "editor sits to the right of sidebar, minX=\(harness.editorFrame.minX)")

        harness.toggleSidebar()
        expect(harness.sidebarHidden, "sidebar hidden after toggle")
        expect(harness.sidebarWidth < 2, "collapsed sidebar width is 0, got \(harness.sidebarWidth)")
        expect(harness.editorFrame.minX < 2, "editor fills split after collapse, minX=\(harness.editorFrame.minX)")
        expect(harness.editorFrame.width >= harness.splitBounds.width - 2, "editor uses full split width")

        harness.toggleSidebar()
        expect(harness.sidebarHidden == false, "sidebar shown again")
        expect(harness.sidebarWidth >= 120, "restored sidebar width \(harness.sidebarWidth)")
        expect(harness.editorFrame.minX >= 120, "editor returns beside sidebar")

        harness.loadMarkdown("""
        # Hello

        ```sh
        echo hi
        ```

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """)
        expect(harness.pageCount >= 1, "at least one page")
        expect(harness.codeHeaderCount == 1, "one copy chrome for fenced block, got \(harness.codeHeaderCount)")
        expect(harness.firstChipShowsRun, "shell fence shows a Terminal run chip")
        expect(harness.runButtonHitTestSucceeds, "run chip receives clicks")
        expect(harness.tableOverlayCount == 1, "one table overlay in WYSIWYG, got \(harness.tableOverlayCount)")
        let a4 = PageGeometry.a4PaperSize
        expect(
            abs(harness.thumbnailAspect - a4.width / a4.height) < 0.04,
            "thumbnail page matches A4 aspect, got \(harness.thumbnailAspect)"
        )
        expect(harness.thumbnailBorderWidth == 0, "thumbnail has no grey frame, border=\(harness.thumbnailBorderWidth)")

        harness.setSourceMode(true)
        expect(harness.tableOverlayCount == 0, "table overlay hidden in source mode")
        expect(harness.codeHeaderCount == 1, "copy chrome remains in source mode")

        harness.setSourceMode(false)
        expect(harness.tableOverlayCount == 1, "table overlay returns in WYSIWYG")
        expect(harness.codeBackgroundsStayOnPages, "short code chrome stays on the page")

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        expect(harness.copyButtonHoverUsesPointingHand(), "copy icon uses pointing-hand cursor")
        expect(harness.copyPopupIsTopRight, "copy popup sits in the top-right of the block")
        expect(harness.copyButtonHitTestSucceeds, "copy popup receives clicks above the text")
        harness.copyFirstCodeBlock()
        expectEqualPasteboard(pasteboard.string(forType: .string), "echo hi", "copy button writes fenced inner text")
        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        let lines = (1...70).map { "echo line \($0)" }.joined(separator: "\n")
        harness.loadMarkdown("# Long\n\n```sh\n\(lines)\n```\n")
        expect(harness.pageCount >= 2, "tall fenced block spans pages, got \(harness.pageCount)")
        expect(harness.codeHeaderCount == 1, "one copy header for the split block")
        expect(harness.codeBackgroundCount >= 2, "code chrome is cut per page, got \(harness.codeBackgroundCount)")
        expect(harness.codeBackgroundsStayOnPages, "code chrome does not paint the page gutter")

        harness.loadMarkdown("See [GitHub](https://github.com) now\n")
        let github = ("See [GitHub](https://github.com) now\n" as NSString).range(of: "GitHub")
        harness.select(github)
        expect(harness.linkCardVisible, "Word-style card appears on a link")
        expect(harness.linkCardURL == "https://github.com", "card shows the URL, got \(harness.linkCardURL)")
        harness.select(NSRange(location: 0, length: 0))
        expect(harness.linkCardVisible == false, "card hides off the link")

        let githubLabel = ("See [GitHub](https://github.com) now\n" as NSString).range(of: "GitHub")
        harness.select(NSRange(location: githubLabel.location + githubLabel.length, length: 0))
        expect(harness.linkCardVisible, "card stays while the caret is in the label")
        expect(harness.editorIsFirstResponder, "caret stays in the document so the label can be typed")
        harness.typeAtCaret("s")
        expect(harness.markdown.contains("[GitHubs](https://github.com)"), "typing edits the link label, got \(harness.markdown)")

        harness.loadMarkdown("[`README.md`](./README.md)\n")
        let readme = ("[`README.md`](./README.md)\n" as NSString).range(of: "README.md")
        harness.select(readme)
        expect(harness.linkCardVisible, "code-styled markdown link is clickable")
        expect(harness.linkCardURL == "./README.md", "card shows relative markdown path, got \(harness.linkCardURL)")
        let docs = URL(fileURLWithPath: "/tmp/marka-doc", isDirectory: true)
        if case .markdown(let url) = Hyperlink.destination("./README.md", relativeTo: docs) {
            expect(url.lastPathComponent == "README.md", "relative .md opens as a Marka document")
        } else {
            expect(false, "relative README.md should resolve to a markdown destination")
        }
        if case .remote(let url) = Hyperlink.destination("https://github.com", relativeTo: docs) {
            expect(url.host == "github.com", "https links stay remote")
        } else {
            expect(false, "https URL should be remote")
        }
        if case .file = Hyperlink.destination("./photo.png", relativeTo: docs) {
            expect(true, "non-markdown files open with the system")
        } else {
            expect(false, "png should be a file destination")
        }

        pasteboard.clearContents()
        harness.loadMarkdown("> hello quote\n")
        expect(harness.codeHeaderCount == 1, "quote block has a copy chip, got \(harness.codeHeaderCount)")
        harness.copyFirstCodeBlock()
        expectEqualPasteboard(pasteboard.string(forType: .string), "hello quote", "quote copy strips the > marker")
        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        harness.loadMarkdown("")
        expect(harness.editorIsFirstResponder, "untitled window focuses the editor")
        harness.typeText("Hello")
        expect(harness.markdown.contains("Hello"), "empty document accepts typing, got \(harness.markdown)")

        harness.loadMarkdown("# Title\n\n")
        let gap = ("# Title\n\n" as NSString).range(of: "\n\n")
        harness.select(NSRange(location: gap.location + 1, length: 0))
        harness.typeAtCaret("X")
        expect(harness.markdown.contains("# TitleX") == false, "typing does not append onto the heading through the rule")
        expect(harness.markdown.contains("X"), "text after a heading lands below the rule, got \(harness.markdown)")

        harness.loadMarkdown("Hi")
        harness.typeText("!")
        expect(harness.markdown.contains("Hi!"), "typed text is in the document, got \(harness.markdown)")
        harness.undo()
        expect(harness.markdown.contains("!") == false, "undo removes typed text, got \(harness.markdown)")
        expect(harness.markdown.contains("Hi"), "undo keeps original text")

        harness.loadMarkdown("Intro")
        harness.insertTable(rows: 2, columns: 3)
        expect(harness.tableOverlayCount == 1, "Pages-style insert shows a table overlay")
        expect(harness.markdown.contains("Column") == false, "new table cells start empty")
        harness.undo()
        expect(harness.tableOverlayCount == 0, "undo removes the inserted table")
        expect(harness.markdown.contains("Intro"), "undo restores text around the table")

        harness.loadMarkdown("Grid")
        harness.insertTable(rows: 2, columns: 3)
        expect(harness.tableCoversHiddenSource, "Pages table paints paper over the hidden GFM source")
        expect(harness.pagesTableChromeIsNative, "column letters and row numbers sit in Pages-style header bars")
        expect(harness.tableAddColumnChipHitTestSucceeds, "green add-column control receives clicks")
        expect(harness.tableSliceCount == 1, "a short table is a single page slice, got \(harness.tableSliceCount)")
        expect(harness.relayoutStable, "table layout does not keep relayouting")
        expect(harness.tableHasFieldFocus, "insert table focuses a cell")
        let rows0 = harness.tableRowCount
        let cols0 = harness.tableColumnCount
        harness.clickAddTableRow()
        expect(harness.tableRowCount == rows0 + 1, "green add-row appends a data row, got \(harness.tableRowCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after add row")
        harness.clickAddTableColumn()
        expect(harness.tableColumnCount == cols0 + 1, "green add-column appends a column, got \(harness.tableColumnCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after add column")
        harness.clickDeleteTableColumn()
        expect(harness.tableColumnCount == cols0, "delete-column removes a column, got \(harness.tableColumnCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after delete column")
        harness.clickDeleteTableRow()
        expect(harness.tableRowCount == rows0, "delete-row removes a data row, got \(harness.tableRowCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after delete row")

        harness.loadMarkdown("Tab")
        harness.insertTable(rows: 2, columns: 2)
        let tabRows = harness.tableRowCount
        harness.focusTableCell(row: 2, column: 1)
        harness.pressTableTab()
        expect(harness.tableRowCount == tabRows + 1, "Tab in the last cell inserts a row, got \(harness.tableRowCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after Tab insert")

        harness.loadMarkdown("Return")
        harness.insertTable(rows: 2, columns: 2)
        let returnRows = harness.tableRowCount
        harness.focusTableCell(row: 2, column: 0)
        harness.pressTableReturn()
        expect(harness.tableRowCount == returnRows + 1, "Return on the last row inserts a row, got \(harness.tableRowCount)")

        harness.loadMarkdown("Select")
        harness.insertTable(rows: 3, columns: 3)
        let selectCols = harness.tableColumnCount
        harness.selectTableColumn(1)
        harness.clickDeleteTableColumn()
        expect(harness.tableColumnCount == selectCols - 1, "selecting a column then − deletes it, got \(harness.tableColumnCount)")
        let selectRows = harness.tableRowCount
        harness.selectTableRow(2)
        harness.clickDeleteTableRow()
        expect(harness.tableRowCount == selectRows - 1, "selecting a row then − deletes it, got \(harness.tableRowCount)")
        expect(harness.tableOverlayCount == 1, "table remains when another data row is left")

        harness.loadMarkdown("""
        Keep

        | A | B |
        | --- | --- |
        | 1 | 2 |
        | 3 | 4 |
        """)
        harness.select((harness.markdown as NSString).range(of: "3"))
        harness.deleteTableRow()
        expect(harness.markdown.contains("3") == false, "delete row removes the selected data row")
        expect(harness.tableOverlayCount == 1, "table remains after deleting one of two rows")
        harness.deleteTableColumn()
        expect(harness.markdown.contains("|") , "table still present after one column")
        harness.deleteTable()
        expect(harness.tableOverlayCount == 0, "Delete Table removes the overlay")
        expect(harness.markdown.contains("|") == false, "Delete Table removes GFM pipes")
        expect(harness.markdown.contains("Keep"), "text around the table is kept")

        harness.loadMarkdown("""
        Stay

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """)
        harness.select((harness.markdown as NSString).range(of: "1"))
        harness.deleteTableRow()
        expect(harness.tableOverlayCount == 0, "deleting the last data row removes the table")
        expect(harness.markdown.contains("Stay"), "surrounding text remains")

        harness.loadMarkdown("Hello **world** today\n\n# Title\n\nPara\n")
        let world = ("Hello **world** today\n\n# Title\n\nPara\n" as NSString).range(of: "world")
        harness.select(world)
        expect(harness.format.bold, "format state is bold in **world**")
        expect(harness.boldToolbarOn, "Bold toolbar highlights when the caret is in bold")
        expect(harness.headingPopupIndex == 0, "heading popup is Paragraph in a body line")
        harness.toggleBold()
        expect(harness.markdown.contains("**world**") == false, "Bold click unwraps, got \(harness.markdown)")
        expect(harness.boldToolbarOn == false, "Bold toolbar turns off after unbold")
        let title = (harness.markdown as NSString).range(of: "Title")
        harness.select(title)
        expect(harness.format.headingLevel == 1, "caret in heading 1")
        expect(harness.headingPopupIndex == 1, "heading popup tracks Heading 1")
        harness.applyHeading(0)
        expect(harness.format.headingLevel == 0, "Paragraph strips the heading")
        expect(harness.headingPopupIndex == 0, "heading popup returns to Paragraph")
        let codeSrc = "use `code` here"
        harness.loadMarkdown(codeSrc)
        harness.select((codeSrc as NSString).range(of: "code"))
        expect(harness.format.inlineCode, "inline code format at caret")
        expect(harness.codeToolbarOn, "inline code is active at the caret")
        expect(harness.codePopupEnabled, "Code popup stays enabled so inline code can unwrap")

        harness.loadMarkdown("```python\nprint(1)\n```\n")
        expect(harness.firstChipShowsRun == false, "python fence has copy only")
        harness.loadMarkdown("```bash\necho hi\n```\n")
        expect(harness.firstChipShowsRun, "bash fence has a Terminal chip")
        expect(harness.copyPopupIsTopRight, "copy chip stays top-right next to the run chip")
        let echo = (harness.markdown as NSString).range(of: "echo")
        harness.select(echo)
        expect(harness.format.inCodeBlock, "caret in a bash fence")
        expect(harness.boldToolbarEnabled == false, "Bold is disabled inside a fence")
        expect(harness.headingPopupEnabled == false, "Heading is disabled inside a fence")
        expect(harness.tableToolbarEnabled == false, "Insert Table is disabled inside a fence")

        harness.loadMarkdown("Hello world\n")
        harness.select(NSRange(location: 1, length: 0))
        expect(harness.boldToolbarEnabled, "Bold is enabled in a paragraph")
        expect(harness.headingPopupEnabled, "Heading is enabled in a paragraph")
        expect(harness.codePopupEnabled, "Code popup is enabled in a paragraph")

        harness.loadMarkdown("Start")
        harness.select(NSRange(location: 5, length: 0))
        harness.insertCodeBlock(language: "bash")
        expect(harness.markdown.contains("```bash"), "bash popup inserts a fenced block, got \(harness.markdown)")
        expect(harness.markdown.contains("`Start`") == false, "code popup does not wrap the line in inline backticks")
        expect(harness.format.inCodeBlock, "caret is inside the empty bash fence")
        expect(harness.format.codeBlockLanguage == "bash", "inserted fence is bash, got \(harness.format.codeBlockLanguage ?? "nil")")
        let beforeType = harness.markdown
        harness.typeAtCaret("echo hi")
        expect(harness.markdown.contains("```bash\necho hi\n```"), "typing lands on the empty inner line, got \(harness.markdown)")
        expect(beforeType.contains("echo hi") == false, "the inserted fence started empty")

        harness.loadMarkdown("Note")
        harness.select(NSRange(location: 4, length: 0))
        harness.insertCodeBlock(language: "")
        expect(harness.markdown.contains("```\n"), "Text inserts a plain fence")
        expect(harness.format.inCodeBlock, "caret is inside the empty text fence")

        harness.loadMarkdown("Intro\n")
        harness.insertTable(rows: 28, columns: 2)
        expect(harness.pageCount >= 2, "tall table continues on the next page, got \(harness.pageCount)")
        expect(harness.tableSliceCount >= 2, "tall table is split into one slice per page, got \(harness.tableSliceCount)")
        expect(harness.tableRepeatsHeaderOnContinuations, "continuation slices repeat the header row")
        expect(harness.tablesStayOnPages, "table chrome does not paint the page gutter")
        expect(harness.tableOverlayCount == 1, "one Pages table owns every page slice")

        harness.loadMarkdown("Wide\n")
        harness.insertTable(rows: 2, columns: 8)
        let pagesBefore = harness.pageCount
        for _ in 0..<4 { harness.insertTableColumn() }
        expect(harness.tableOverlayCount == 1, "wide table stays a single overlay")
        expect(harness.pageCount < pagesBefore + 8, "adding columns that wrap the page does not explode page count, got \(harness.pageCount)")
        expect(harness.relayoutStable, "wide table relayout settles")

        harness.setManualZoom(0.5)
        expect(harness.pageCenteredHorizontally, "zoomed-out page is centered, not stuck to the left")
        harness.setManualZoom(1.0)

        do {
            let url = CrashReporter.writeDiagnostic(title: "test", body: "synthetic")
            let text = try String(contentsOf: url, encoding: .utf8)
            expect(text.contains("synthetic"), "crash log contains the diagnostic body")
            expect(FileManager.default.fileExists(atPath: CrashReporter.pendingFlagURL.path), "pending crash flag is set")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.removeItem(at: CrashReporter.pendingFlagURL)
        } catch {
            expect(false, "crash log write failed: \(error)")
        }

        if failed > 0 {
            fputs("\(failed) UI test(s) failed.\n", stderr)
            exit(1)
        }
        print("All UI tests passed")
    }
}