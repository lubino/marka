import AppKit

/// Localized percentage exactly as the zoom combo formats it.
func Self_percent(_ value: CGFloat) -> String {
    let f = NumberFormatter()
    f.numberStyle = .percent
    f.maximumFractionDigits = 0
    return (f.string(from: NSNumber(value: Double(value))) ?? "")
        .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}
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
        start.darkPaper = false
        SettingsStore.shared.current = start
        let harness = EditorWindowHarness()
        defer {
            harness.close()
            SettingsStore.shared.current = saved
        }

        // Window position: remembered between windows/launches, never the bottom-left corner.
        EditorWindowHarness.clearSavedWindowFrame()
        let fresh = EditorWindowHarness.newWindowFrame()
        if let screen = NSScreen.main?.visibleFrame {
            expect(abs(fresh.midX - screen.midX) < 2 && fresh.minY > screen.minY + 1, "first window is centred, not in the bottom-left corner, got \(fresh)")
            let placed = NSRect(x: screen.minX + 120, y: screen.minY + 90, width: 900, height: 640)
            harness.moveWindow(to: placed)
            let next = EditorWindowHarness.newWindowFrame()
            expect(next.size == placed.size && abs(next.minX - placed.minX) < 40 && abs(next.maxY - placed.maxY) < 40, "a new window reopens where the last one was, got \(next) vs \(placed)")
        }
        harness.moveWindow(to: NSRect(x: -4800, y: -4800, width: 1100, height: 760))
        EditorWindowHarness.clearSavedWindowFrame()

        expect(harness.zoomMode == "auto", "default zoom is Auto")
        expect(harness.zoomAutoOn, "Auto is checked in the zoom menu in Auto mode")
        expect(harness.zoomTitle == "Auto", "zoom combo shows just Auto while Auto is selected, got \(harness.zoomTitle)")
        expect(harness.zoomMenuTitles.count == 11, "zoom menu: 9 presets, separator, Auto — got \(harness.zoomMenuTitles)")
        expect(harness.zoomMenuTitles.last == "Auto" && !harness.zoomMenuTitles.contains("Wide"), "one Auto entry closes the menu")
        harness.chooseZoom(Self_percent(1.5))
        expect(harness.zoomMode == "manual", "choosing a preset switches to manual zoom")
        expect(abs(harness.magnification - 1.5) < 0.01, "150 % preset applies, got \(harness.magnification)")
        expect(harness.zoomTitle == Self_percent(1.5), "combo title follows the preset, got \(harness.zoomTitle)")
        expect(harness.zoomCheckedTitle == Self_percent(1.5), "chosen preset is checked, got \(harness.zoomCheckedTitle ?? "nil")")
        harness.zoomInStep()
        expect(abs(harness.magnification - 2.0) < 0.01, "⌘+ steps through the same presets, got \(harness.magnification)")
        expect(harness.zoomTitle == Self_percent(2.0), "title updates after ⌘+, got \(harness.zoomTitle)")
        harness.chooseZoom("Auto")
        expect(harness.zoomMode == "auto" && harness.zoomAutoOn, "Auto returns to auto zoom")
        expect(harness.zoomTitle == "Auto", "title is Auto again in Auto")

        expect(harness.shareToolbarItemIsSystem, "Share uses the system share toolbar item (anchored under the button)")
        expect(harness.shareMenuItemIsSystem, "File → Share is the standard system Share menu item")
        if let shared = harness.shareItems.first as? URL {
            expect(shared.pathExtension == "md", "untitled documents share as a .md file, got \(shared.lastPathComponent)")
            let text = (try? String(contentsOf: shared, encoding: .utf8)) ?? "<missing>"
            expect(text == harness.markdown, "shared file holds the current text")
            try? FileManager.default.removeItem(at: shared.deletingLastPathComponent())
        } else {
            expect(false, "share items should be a file URL, got \(harness.shareItems)")
        }
        expect(harness.pageCenteredHorizontally, "Auto zoom keeps the page centered")
        harness.pump(0.1)
        let filled = harness.canvasWidth * harness.magnification
        expect(
            abs(filled - harness.scrollWidth) < 120 || filled >= harness.scrollWidth - 40,
            "Auto fills window width (canvas \(harness.canvasWidth) × \(harness.magnification) vs scroll \(harness.scrollWidth))"
        )

        expect(harness.splitBounds.width > 400, "split view has width")
        expect(harness.sidebarHidden == false, "sidebar starts visible")
        expect(harness.sidebarWidth >= 150, "open sidebar has pane width, got \(harness.sidebarWidth)")
        expect(harness.editorFrame.minX >= 120, "editor sits to the right of sidebar, minX=\(harness.editorFrame.minX)")
        expect(harness.hasFullSizeContent, "full-size content: the document runs under the toolbar like Preview")
        expect(harness.usesSplitViewController, "window content is an NSSplitViewController")
        expect(harness.sidebarIsSystemSidebar, "thumbnail pane is a system sidebar split item (glass on macOS 26+)")
        expect(harness.sidebarReachesWindowTop, "thumbnail pane starts at the top, next to the window controls")
        expect(harness.editorRunsUnderToolbar, "editor scroll view extends under the semi-transparent toolbar")
        expect(harness.editorTopInset > 20, "first page starts below the toolbar via content insets, got \(harness.editorTopInset)")
        expect(harness.windowSupportsNativeTabs, "plain NSWindow with native tabbing (no tab-bar suppression)")
        expect(harness.tabBarVisible == false, "no tab bar while only one tab is open")
        expect(harness.hasPageControl, "toolbar has the page-number control")
        let pristine = EditorWindowHarness.pristineUntitledRule()
        expect(pristine.fresh, "an untouched Untitled is replaced when a file opens (no empty first tab)")
        expect(pristine.typed == false, "an Untitled with text is never replaced")
        expect(harness.windowSupportsNativeTabs, "new documents prefer tabs")
        let tabs = harness.openAndCloseSecondDocument()
        expect(tabs.tabCount == 2, "a new document opens as a tab in the current window, got \(tabs.tabCount) tab(s)")
        expect(tabs.barVisibleWithTwoTabs, "tab bar appears with two tabs")
        expect(tabs.tabCountAfterClosing == 1, "closing the second tab leaves one, got \(tabs.tabCountAfterClosing)")
        expect(tabs.barVisibleAfterClosing == false, "tab bar hides again when back to one tab")
        expect(harness.hasSidebarTrackingSeparator, "tracking separator keeps the document title after the sidebar")
        expect(harness.titleFollowsSidebarSeparator, "document name starts after the sidebar, not over the thumbnails")
        expect(harness.sidebarItemIsNavigational == false, "sidebar button is not navigational (that moves it into the document header)")
        expect(harness.sidebarButtonInSidebarSection, "sidebar button is in the thumbnail-pane section, next to the window controls")
        harness.setSidebarWidth(80, pump: 0.15)
        expect(harness.sidebarWidth >= 150, "sidebar cannot be dragged narrower than 150 pt, got \(harness.sidebarWidth)")
        let atMin = harness.sidebarButtonPlacement
        expect(atMin.visible, "sidebar toggle stays visible at the minimum sidebar width")
        expect(atMin.gap < 40, "sidebar toggle sits right after the window controls, gap \(atMin.gap)")
        harness.setSidebarWidth(160, pump: 0.15)
        expect(harness.interPageGap <= 12, "page gaps are Preview-tight, got \(harness.interPageGap)")
        expect(harness.settingsWindowShowsFontControls, "Settings (⌘,) exposes default font and size")

        harness.toggleSidebar()
        expect(harness.sidebarHidden, "sidebar hidden after toggle")
        let collapsed = harness.sidebarButtonPlacement
        expect(collapsed.visible, "sidebar toggle stays visible while thumbnails are hidden")
        expect(collapsed.gap < 40, "with the sidebar off the toggle sits next to the window controls, gap \(collapsed.gap)")
        expect(harness.sidebarWidth < 2, "collapsed sidebar width is 0, got \(harness.sidebarWidth)")
        expect(harness.editorFrame.minX < 2, "editor fills split after collapse, minX=\(harness.editorFrame.minX)")
        expect(harness.editorFrame.width >= harness.splitBounds.width - 2, "editor uses full split width")

        expect(abs(harness.magnification - harness.fitMagnification) < 0.01, "Auto zoom refits after the sidebar closes (\(harness.magnification) vs \(harness.fitMagnification))")
        harness.toggleSidebar()
        expect(abs(harness.magnification - harness.fitMagnification) < 0.01, "Auto zoom refits after the sidebar opens (\(harness.magnification) vs \(harness.fitMagnification))")
        expect(harness.sidebarHidden == false, "sidebar shown again")
        expect(harness.sidebarWidth >= 150, "restored sidebar width \(harness.sidebarWidth)")
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
        expect(harness.thumbnailSelectionCornerRadius >= 6, "selected thumbnail uses a rounded box, radius=\(harness.thumbnailSelectionCornerRadius)")
        expect(harness.thumbnailSelectionUsesAccentStroke == false, "selected thumbnail is a gray-blue fill, not an accent ring")
        expect(harness.thumbnailSelectionContainsNumber, "page number sits inside the rounded selection box")
        expect(harness.thumbnailCenteredInPane, "thumbnail page is centered in the pane")
        expect(harness.thumbnailUsesSystemScrollers, "thumbnail pane uses the system scroller style (overlay), not a legacy lane")
        expect(
            harness.thumbnailHorizontalOverflow <= 0.5,
            "thumbnail table fits its clip view, overflow=\(harness.thumbnailHorizontalOverflow)"
        )
        expect(harness.thumbnailBelowTitlebar, "first thumbnail sits below the titlebar")

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
        expect(harness.textViewPointerOverCopyIcon, "text view keeps the pointing hand (not the I-beam) over the copy icon")
        expect(harness.copyButtonSize.width <= 23 && harness.copyButtonSize.height <= 23, "chip icons are small, got \(harness.copyButtonSize)")
        expect(harness.copyButtonIsBorderless, "chip icon has no extra border tile")
        harness.copyFirstCodeBlock()
        expectEqualPasteboard(pasteboard.string(forType: .string), "echo hi", "copy button writes fenced inner text")
        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        let highlighted = "Intro\n\n```swift\nlet n = 42 // answer\n```\n\n```\nlet plain = 1\n```\n"
        harness.loadMarkdown(highlighted)
        let hns = highlighted as NSString
        expect(harness.foregroundHex(at: hns.range(of: "let n").location) == "CF222E", "swift keyword is GitHub red, got \(harness.foregroundHex(at: hns.range(of: "let n").location) ?? "nil")")
        expect(harness.foregroundHex(at: hns.range(of: "42").location) == "0550AE", "number is GitHub blue")
        expect(harness.foregroundHex(at: hns.range(of: "// answer").location) == "6E7781", "comment is GitHub gray")
        let plainLet = hns.range(of: "let plain").location
        expect(harness.foregroundHex(at: plainLet) != "CF222E", "a fence without a language is not highlighted")
        expect(harness.foregroundHex(at: hns.range(of: "Intro").location) != "CF222E", "body text keeps its colour")

        // Math typesetting: every formula of the supported subset renders without errors.
        let formulas = [
            "E = mc^2",
            "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}",
            "\\sum_{k=1}^{n} k^2 = \\frac{n(n+1)(2n+1)}{6}",
            "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}",
            "\\left( \\frac{a}{b} \\right)^2 \\leq \\alpha + \\beta_i",
            "\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix} \\cdot \\vec{v} = \\begin{bmatrix} a \\\\ b \\end{bmatrix}",
            "f(x) = \\begin{cases} x^2 & x \\geq 0 \\\\ -x & \\text{otherwise} \\end{cases}",
            "\\lim_{n \\to \\infty} \\left(1 + \\frac{1}{n}\\right)^n = e",
            "\\mathbb{R}^n, \\mathcal{L}, \\mathbf{F} = m\\mathbf{a}, \\sin\\theta, \\sqrt[3]{x}, \\hat{x}, \\overline{AB}",
            "\\begin{aligned} a &= b + c \\\\ &= d \\end{aligned}"
        ]
        let mathPath = ProcessInfo.processInfo.environment["MARKA_MATH_SHEET"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("marka-math.png").path
        let mathOK = EditorWindowHarness.renderMathSheet(formulas, to: mathPath)
        if let probe = ProcessInfo.processInfo.environment["MARKA_MATH_PROBE"] {
            _ = EditorWindowHarness.renderMathSheet(["\\int_0^\\infty e^{-x^2}\\,dx", "e^{-x^2}", "a e b"], to: probe)
        }
        expect(mathOK.allSatisfy { $0 }, "every supported formula renders without errors, results \(mathOK)")
        expect(EditorWindowHarness.renderMathSheet(["\\unknowncommand x"], to: mathPath + ".err.png") == [false], "unknown commands are reported (shown in red)")

        // Mermaid diagrams render natively.
        let diagrams = [
            "flowchart TD\n  A[Open file] --> B{Is it Markdown?}\n  B -->|yes| C(Edit in Marka)\n  B -->|no| D[Open with system]\n  C --> E((Save))\n  E -.-> A\n  C ==> F[(Assets)]",
            "graph LR\n  Write --> Review --> Publish\n  Review -- changes --> Write",
            "sequenceDiagram\n  actor U as User\n  participant M as Marka\n  participant F as File\n  U->>M: Type text\n  M->>F: Autosave\n  F-->>M: Saved\n  Note over M,F: identity save keeps bytes\n  M->>M: Restyle\n  M-->>U: Updated page",
            "pie title Time spent\n  \"Writing\" : 55\n  \"Editing\" : 25\n  \"Formatting\" : 12\n  \"Other\" : 8",
            "gantt\n  title Not drawn"
        ]
        let mermaidPath = ProcessInfo.processInfo.environment["MARKA_MERMAID_SHEET"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("marka-mermaid.png").path
        let sizes = EditorWindowHarness.renderMermaidSheet(diagrams, to: mermaidPath)
        expect(sizes.allSatisfy { $0.width > 60 && $0.height > 30 }, "every diagram renders at a real size, got \(sizes)")
        if let dark = ProcessInfo.processInfo.environment["MARKA_MERMAID_DARK"] { _ = EditorWindowHarness.renderMermaidSheet(diagrams, to: dark, dark: true) }

        if let dir = ProcessInfo.processInfo.environment["MARKA_TESTMD_SNAPSHOT_DIR"],
           let sample = try? String(contentsOfFile: "TEST.md", encoding: .utf8) {
            harness.loadMarkdown(sample)
            for page in 0..<harness.pageCount { harness.pageSnapshot(page, height: 2000, to: dir + "/testmd-\(page).png") }
        }
        // Math and Mermaid in the document: drawn over hidden source, edited in a popover.
        let renderedDoc = "Intro with $E=mc^2$ inline.\n\n```math\n\\frac{a}{b}\n```\n\n$$\n\\sum_{k=1}^{n} k\n$$\n\n```mermaid\ngraph TD\n  A[Start] --> B[End]\n```\n\nAfter the diagrams.\n"
        harness.loadMarkdown(renderedDoc)
        let rns = renderedDoc as NSString
        if let dir = ProcessInfo.processInfo.environment["MARKA_RENDER_SNAPSHOT_DIR"] {
            harness.pageSnapshot(0, height: 520, to: dir + "/page.png")
            harness.pdfPageSnapshot(0, to: dir + "/pdf.png")
        }
        let frames = harness.renderedFrames
        expect(frames.count == 3, "```math, $$ and ```mermaid are drawn, got \(frames.count)")
        expect(harness.codeHeaderCount == 0, "drawn blocks get no code copy chips")
        for name in ["\\frac{a}{b}", "\\sum_{k=1}^{n} k", "A[Start] --> B[End]"] {
            let leaked = harness.visibleSourceCharacters(in: rns.range(of: name))
            expect(leaked.isEmpty, "the source of \(name) is hidden in WYSIWYG, visible: \(leaked.joined())")
        }
        let afterY = harness.canvasY(of: rns.range(of: "After the diagrams").location)
        expect(frames.allSatisfy { $0.maxY <= afterY + 1 }, "text after the drawings starts below them (after \(afterY), frames \(frames))")
        expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxY <= $1.minY + 0.5 }, "drawings never overlap each other")
        let inlineMath = harness.inlineMathPlacements
        expect(inlineMath.count == 1 && (inlineMath.first?.width ?? 0) > 20, "inline $E=mc^2$ is drawn in the line, got \(inlineMath)")
        expect(harness.visibleSourceCharacters(in: rns.range(of: "$E=mc^2$")).isEmpty, "inline math source is hidden")
        harness.select(NSRange(location: rns.range(of: "mc^2").location, length: 0))
        harness.pump(0.1)
        expect(!harness.visibleSourceCharacters(in: rns.range(of: "$E=mc^2$")).isEmpty, "with the caret inside, the formula's source shows for editing")
        expect(harness.inlineMathPlacements.isEmpty, "…and the drawn formula steps aside")
        harness.select(NSRange(location: 0, length: 0))
        harness.pump(0.1)
        expect(harness.inlineMathPlacements.count == 1, "leaving the formula draws it again")
        harness.editRenderedBlock(0, newSource: "\\sqrt{2}")
        expect(harness.markdown.contains("```math\n\\sqrt{2}\n```"), "the equation popover writes the new source between the fences, got \(harness.markdown)")
        harness.undo()
        expect(harness.markdown.contains("```math\n\\frac{a}{b}\n```"), "an equation edit is one undo step")
        expect(harness.pdfPageCount == harness.pageCount, "PDF export includes the drawings on the same pages (\(harness.pdfPageCount) vs \(harness.pageCount))")
        harness.setSourceMode(true)
        expect(harness.renderedFrames.isEmpty && harness.inlineMathPlacements.isEmpty, "source mode shows the raw Markdown")
        harness.setSourceMode(false)

        // A drawing that would cross a page break moves to the next page.
        let pushFiller = (1...40).map { "Filler line \($0) to reach the bottom of the page." }.joined(separator: "\n\n")
        harness.loadMarkdown(pushFiller + "\n\n```mermaid\ngraph TD\n  A --> B\n  B --> C\n  C --> D\n  D --> E\n```\n\nTail.\n")
        if let frame = harness.renderedFrames.first, let page = harness.pageContentRect(containing: frame.midY) {
            expect(frame.minY >= page.minY - 1 && frame.maxY <= page.maxY + 1, "a diagram sits wholly inside one page's content area, frame \(frame) page \(page)")
            let tailY = harness.canvasY(of: (harness.markdown as NSString).range(of: "Tail.").location)
            expect(tailY >= frame.maxY - 1 && tailY - frame.maxY < 40, "text after a pushed diagram follows it directly (gap \(tailY - frame.maxY))")
        } else {
            expect(false, "the pushed diagram is drawn")
        }

        // Search & replace popover.
        let findDoc = "Alpha beta alpha.\n\nGamma ALPHA alphabet.\n"
        harness.loadMarkdown(findDoc)
        expect(harness.findButtonIsViewBased, "search button anchors the popover under itself")
        expect(harness.findLayoutAligned, "find popover: fields share edges and size, controls share edges and size, rows centred")
        if let path = ProcessInfo.processInfo.environment["MARKA_FIND_SNAPSHOT"] { harness.findSnapshot(to: path) }
        expect(harness.find("alpha") == "1 of 4", "finds every alpha (case-insensitive), got \(harness.find("alpha"))")
        expect(harness.findHighlightCount == 4, "all matches are highlighted, got \(harness.findHighlightCount)")
        expect(harness.selectedRange == NSRange(location: 0, length: 5), "first match is selected")
        harness.findNext()
        expect(harness.selectedRange.location == (findDoc as NSString).range(of: "alpha.").location, "next match")
        harness.findPrevious()
        harness.findPrevious()
        expect(harness.selectedRange.location == (findDoc as NSString).range(of: "alphabet").location, "previous wraps to the last match")
        expect(harness.find("alpha", wholeWord: true) == "1 of 3", "whole words skip alphabet")
        expect(harness.find("ALPHA", caseSensitive: true) == "1 of 1", "match case")
        expect(harness.find("zeta") == "Not found", "missing text reports Not found")
        harness.find("beta")
        harness.replaceCurrent(with: "BETA")
        expect(harness.markdown.contains("Alpha BETA alpha."), "Replace swaps the current match, got \(harness.markdown)")
        harness.undo()
        expect(harness.markdown.contains("Alpha beta alpha."), "Replace is one undo step")
        let replacedLabel = harness.replaceAll("alpha", with: "omega")
        expect(replacedLabel == "4 replaced", "Replace All reports the count, got \(replacedLabel)")
        expect(!harness.markdown.lowercased().contains("alpha"), "Replace All replaces every match, got \(harness.markdown)")
        harness.undo()
        expect(harness.markdown == findDoc, "Replace All is a single undo step")

        // PDF export keeps links clickable (URL annotations over the link labels).
        let filler2 = (1...45).map { "Line \($0) of filler text." }.joined(separator: "\n\n")
        harness.loadMarkdown("Visit [GitHub](https://github.com) and [the notes](notes/plan.md).\n\n\(filler2)\n\nLater [Apple](https://apple.com).\n\n| T |\n| --- |\n| [in table](https://table.example) |\n")
        let pdfLinks = harness.pdfLinks(documentDirectory: URL(fileURLWithPath: "/tmp/marka-docs", isDirectory: true))
        let urls = pdfLinks.map(\.url)
        expect(urls.contains("https://github.com"), "PDF has the GitHub link, got \(urls)")
        expect(urls.contains("file:///tmp/marka-docs/notes/plan.md"), "relative .md link becomes an absolute file link, got \(urls)")
        expect(pdfLinks.first { $0.url == "https://apple.com" }.map { $0.page >= 1 } == true, "a link on a later page is annotated on that page, got \(pdfLinks.map { ($0.page, $0.url) })")
        expect(!urls.contains("https://table.example"), "links inside tables are not mapped onto hidden source")
        if let gh = pdfLinks.first(where: { $0.url == "https://github.com" }) {
            expect(gh.rect.width > 10 && gh.rect.height > 5 && gh.rect.minY > 600, "link rect sits over the first line near the top of the page, got \(gh.rect)")
        }

        // The hidden GFM source of a table must stay invisible, even with Markdown in its cells.
        let tableSource = "| Name | Notes |\n| --- | --- |\n| **Bold** | `code` and [link](https://x.y) |\n| *it* | ~~old~~ |"
        harness.loadMarkdown("Before\n\n\(tableSource)\n\nAfter\n")
        let tableRange = (harness.markdown as NSString).range(of: tableSource)
        let leaked = harness.visibleSourceCharacters(in: tableRange)
        expect(leaked.isEmpty, "no table source shows behind the table, visible: \(leaked.joined())")
        expect(harness.inlineCodeBoxes.isEmpty, "no inline-code boxes are drawn for hidden table source, got \(harness.inlineCodeBoxes.count)")

        // Markdown inside table cells: rendered when idle, raw while editing, raw kept on commit.
        let boldCell = harness.tableCellDisplay(row: 2, column: 0)
        expect(boldCell?.text == "Bold" && boldCell?.bold == true, "cell **Bold** renders bold without markers, got \(String(describing: boldCell))")
        expect(harness.tableCellDisplay(row: 2, column: 1)?.text == "code and link", "code and link render without markers, got \(String(describing: harness.tableCellDisplay(row: 2, column: 1)))")
        harness.focusTableCell(row: 2, column: 0)
        expect(harness.tableCellDisplay(row: 2, column: 0)?.text == "**Bold**", "editing a cell shows its Markdown source, got \(String(describing: harness.tableCellDisplay(row: 2, column: 0)))")
        harness.focusTableCell(row: 3, column: 0)
        expect(harness.markdown.contains("| **Bold**") || harness.markdown.contains("|**Bold**"), "leaving the cell keeps its Markdown in the file, got \(harness.markdown)")
        expect(harness.tableCellDisplay(row: 2, column: 0)?.text == "Bold", "the left cell is rendered again")

        // No empty last page: pages follow the content, also when it shrinks.
        harness.loadMarkdown("Hello\n\n\n")
        expect(harness.pageCount == 1, "a short document is one page, got \(harness.pageCount)")
        let fill = (1...140).map { "Line \($0) of text that fills the pages." }.joined(separator: "\n\n")
        harness.loadMarkdown(fill + "\n\n\n\n")
        expect(harness.pageCount == harness.lastContentPage + 1, "trailing blank lines add no page (pages \(harness.pageCount), content ends on \(harness.lastContentPage + 1))")
        harness.select(NSRange(location: 0, length: (harness.markdown as NSString).length))
        harness.typeAtCaret("Short again")
        harness.pump(0.4)
        expect(harness.pageCount == 1, "deleting content removes the now-empty pages, got \(harness.pageCount)")

        // Bold / italic are instant: markers are hidden before the next frame, restyle is fast.
        let richParagraph = "Some **bold**, *italic*, `code`, a [link](https://x.y) and ~~old~~ text in paragraph"
        let perfDoc = (1...200).map { "\(richParagraph) \($0)." }.joined(separator: "\n\n")
            + "\n\n```swift\nlet x = 1 // code\n```\n"
        harness.loadMarkdown(perfDoc)
        var restyles: [Double] = []
        for _ in 0..<3 { restyles.append(harness.measureRestyle()) }
        let restyleMs = restyles.sorted()[1]
        print("PERF restyle of a 200-paragraph document: \(String(format: "%.1f", restyleMs)) ms")
        print("PERF cold parse of a 200-paragraph document: \(String(format: "%.1f", harness.measureColdParse())) ms")
        print("PERF page relayout of a 200-paragraph document: \(String(format: "%.1f", harness.measureRelayout())) ms")
        let target = (perfDoc as NSString).range(of: "paragraph 150")
        let immediate = harness.boldMarkersHiddenImmediately(at: NSRange(location: target.location, length: 9))
        print("PERF Bold action: \(String(format: "%.1f", immediate.ms)) ms, markers hidden before drawing: \(immediate.hidden)")
        expect(immediate.hidden, "Bold hides its ** before the next frame (no visible asterisks)")
        // Timings vary a lot with machine load (and debug builds); this is a regression guard only.
        expect(immediate.ms < 250, "Bold stays well under a quarter second on a 200-paragraph document, took \(immediate.ms) ms")
        _ = restyleMs

        // Incremental restyles must produce exactly what a full restyle would.
        let structureDoc = "# Title\n\nIntro paragraph with words.\n\nSetext\n\nMore text here.\n\n```swift\nlet a = 1\n```\n\nTail **bold** and `code`.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nEnd.\n"
        let edits: [(String, (EditorWindowHarness) -> Void)] = [
            ("type in a paragraph", { h in h.select(NSRange(location: (h.markdown as NSString).range(of: "words").location, length: 0)); h.typeAtCaret("many ") }),
            ("start inline code", { h in h.select(NSRange(location: (h.markdown as NSString).range(of: "More").location, length: 0)); h.typeAtCaret("`x` ") }),
            ("setext underline", { h in h.select(NSRange(location: NSMaxRange((h.markdown as NSString).range(of: "Setext")), length: 0)); h.typeAtCaret("\n===") }),
            ("remove a fence backtick", { h in let r = (h.markdown as NSString).range(of: "```\n\nTail"); h.select(NSRange(location: r.location, length: 1)); h.typeAtCaret("") }),
            ("bold a word", { h in h.select((h.markdown as NSString).range(of: "Intro")); h.toggleBold() }),
            ("unbold", { h in h.select((h.markdown as NSString).range(of: "bold")); h.toggleBold() }),
            ("type in code", { h in h.select(NSRange(location: (h.markdown as NSString).range(of: "let a").location, length: 0)); h.typeAtCaret("var ") })
        ]
        for (name, apply) in edits {
            harness.loadMarkdown(structureDoc)
            apply(harness)
            harness.pump(0.15)
            let incremental = harness.styleSignature
            harness.fullRestyle()
            let full = harness.styleSignature
            expect(incremental == full, "incremental restyle matches a full restyle after: \(name)")
            if incremental != full {
                let a = incremental.components(separatedBy: "\n"), b = full.components(separatedBy: "\n")
                if let first = zip(a, b).first(where: { $0 != $1 }) { print("STYLE DIFF \(name): \(first.0)  vs  \(first.1)") }
            }
        }

        // Bold / italic must not disturb scrolling.
        let boldDoc = (1...80).map { "Paragraph \($0) with a word to format." }.joined(separator: "\n\n")
        harness.loadMarkdown(boldDoc)
        let wordAt = (boldDoc as NSString).range(of: "Paragraph 40 with a ")
        harness.select(NSRange(location: NSMaxRange(wordAt), length: 4))
        harness.scrollCaret(toScreenOffset: 300)
        let boldBefore = harness.caretScreenOffset
        harness.toggleBold()
        var boldDrift: [Int] = []
        for _ in 0..<12 { harness.pump(0.1); boldDrift.append(Int((harness.caretScreenOffset - boldBefore).rounded())) }
        expect(boldDrift.allSatisfy { abs($0) <= 3 }, "Bold keeps the view still, drift over time \(boldDrift)")
        expect(harness.markdown.contains("**word**"), "Bold applied")
        expect(harness.lastEditLength <= 16, "Bold edits only the word, not the whole document (replaced \(harness.lastEditLength) chars)")
        harness.toggleBold()
        harness.pump(0.1)
        harness.scrollVisibleTop(to: 200)       // the user scrolls away right after formatting
        let scrolledTo = harness.visibleTopY
        harness.pump(1.2)
        expect(abs(harness.visibleTopY - scrolledTo) < 3, "a scroll right after formatting is not pulled back (\(scrolledTo) → \(harness.visibleTopY))")

        // Formatting buttons work in table cells and in link labels.
        harness.loadMarkdown("See [the docs](https://x.y) now.\n\n| A | B |\n| --- | --- |\n| plain | cell |\n")
        let docsLabel = (harness.markdown as NSString).range(of: "docs")
        harness.select(docsLabel)
        expect(harness.boldEnabled, "Bold is available inside a link label")
        harness.toggleBold()
        expect(harness.markdown.contains("[the **docs**](https://x.y)"), "Bold wraps text inside a link label, got \(harness.markdown)")
        harness.clickTableCell(row: 2, column: 0)
        expect(harness.boldEnabled, "Bold is available while editing a table cell")
        harness.selectInCell(NSRange(location: 0, length: 5))
        harness.toggleBold()
        harness.clickTableCell(row: 2, column: 1)
        expect(harness.markdown.contains("**plain**"), "Bold in a table cell wraps the cell selection, got \(harness.markdown)")

        // Opening a document starts at the top, and zoom changes keep the top line in place.
        let longOpen = (1...90).map { "Paragraph \($0) of a long document." }.joined(separator: "\n\n")
        harness.setZoom(manual: 1.0)
        harness.loadMarkdown(longOpen)
        harness.setZoom(manual: nil)          // Auto zoom kicks in after open, as it does at launch
        expect(abs(harness.visibleTopY) < 2, "an opened document shows its top after Auto zoom, top y \(harness.visibleTopY)")
        harness.scrollVisibleTop(to: 1500)
        let anchoredTop = harness.visibleTopY
        harness.setZoom(manual: 0.75)
        expect(abs(harness.visibleTopY - anchoredTop) < 4, "zooming keeps the top line in place (\(anchoredTop) → \(harness.visibleTopY))")
        harness.setZoom(manual: nil)
        expect(abs(harness.visibleTopY - anchoredTop) < 4, "Auto refit keeps the top line in place (\(anchoredTop) → \(harness.visibleTopY))")

        // Table edits keep the table where it is on screen and never select hidden source text.
        let tableMiddle = (1...30).map { "Intro \($0)." }.joined(separator: "\n\n")
            + "\n\n| A | B |\n| --- | --- |\n| a1 | b1 |\n| a2 | b2 |\n\n"
            + (1...30).map { "Outro \($0)." }.joined(separator: "\n\n")
        harness.loadMarkdown(tableMiddle)
        harness.select(NSRange(location: 0, length: 0))   // the text cursor stays far above
        harness.pump(0.2)
        if let tableY = harness.tableScreenTop {
            harness.scrollVisibleTop(to: harness.visibleTopY + tableY / harness.magnification - 200 / harness.magnification)
        }
        let tableTopBefore = harness.tableScreenTop ?? 0
        harness.clickTableCell(row: 2, column: 0)
        harness.tableBar("rowBelow")
        let tableTopAfter = harness.tableScreenTop ?? 0
        expect(abs(tableTopAfter - tableTopBefore) < 3, "inserting a row keeps the table in place (\(tableTopBefore) → \(tableTopAfter) pt)")
        harness.typeInCell("x", at: 2)
        harness.clickTableCell(row: 3, column: 1)
        expect(abs((harness.tableScreenTop ?? 0) - tableTopBefore) < 3, "committing a cell keeps the table in place, moved \((harness.tableScreenTop ?? 0) - tableTopBefore) pt")
        expect(harness.selectedRange.length == 0, "table edits never select hidden source text, got \(harness.selectedRange)")

        // Combined inline Markdown and GitHub-style inline code boxes.
        let inline = "See **[readme](README.md)** and **`Marka.dmg`** or *`Marka.dmg`* in `~/Library/Logs/Marka`.\n"
        harness.loadMarkdown(inline)
        let ins = inline as NSString
        let readmeAt = ins.range(of: "readme").location
        expect(harness.fontTraits(at: readmeAt).bold, "bold link label is bold")
        expect(harness.foregroundHex(at: readmeAt) != nil, "bold link label is styled")
        let boldCodeAt = ins.range(of: "Marka.dmg").location
        let boldCode = harness.fontTraits(at: boldCodeAt)
        expect(boldCode.bold && boldCode.mono, "**`code`** is bold and monospaced, got \(boldCode)")
        let italicCodeAt = ins.range(of: "Marka.dmg", options: .backwards, range: NSRange(location: 0, length: ins.range(of: "in `").location)).location
        let italicCode = harness.fontTraits(at: italicCodeAt)
        expect(italicCode.mono, "*`code`* stays monospaced, got \(italicCode)")
        let boxes = harness.inlineCodeBoxes
        expect(boxes.count == 3, "one rounded box per inline code span, got \(boxes.count)")
        if let box = boxes.last {
            expect(box.height >= 10 && box.height <= 24, "inline code box hugs the text, height \(box.height)")
            let inside = harness.renderedLuminance(atTextViewPoint: NSPoint(x: box.minX + 1.5, y: box.midY)) ?? 1
            let outside = harness.renderedLuminance(atTextViewPoint: NSPoint(x: box.minX + 1.5, y: box.minY - 4)) ?? 0
            expect(inside < outside - 0.02, "box fill is drawn in the left padding (inside \(inside) vs paper \(outside))")
        }

        // Changing a code block's language while editing must not move the view.
        let before = (1...80).map { "Paragraph \($0) before the code." }.joined(separator: "\n\n")
        let after = (1...40).map { "Paragraph \($0) after the code." }.joined(separator: "\n\n")
        let fenced = "\(before)\n\n```bash\necho hello\n```\n\n\(after)\n"
        harness.loadMarkdown(fenced)
        let echoHello = (fenced as NSString).range(of: "echo hello")
        harness.select(NSRange(location: echoHello.location + 4, length: 0))
        expect(harness.editAnchor == nil, "no stale edit anchor survives earlier edits, got \(harness.editAnchor.map { "\($0)" } ?? "nil")")
        harness.scrollCaret(toScreenOffset: 260)
        let offsetBefore = harness.caretScreenOffset
        let info = (fenced as NSString).range(of: "bash")
        harness.replace(info, with: "python")
        harness.select(NSRange(location: echoHello.location + 6, length: 0))
        harness.pump(0.3)
        let offsetAfter = harness.caretScreenOffset
        for (from, to) in [("python", "swift"), ("swift", "zsh"), ("zsh", "bash")] {
            let r = (harness.markdown as NSString).range(of: "```" + from)
            let b = harness.caretScreenOffset
            harness.replace(NSRange(location: r.location + 3, length: from.utf16.count), with: to)
            let e = (harness.markdown as NSString).range(of: "echo hello")
            harness.select(NSRange(location: e.location + 4, length: 0))
            harness.pump(0.3)
            expect(abs(harness.caretScreenOffset - b) < 3, "retyping ```\(from) → \(to) keeps the view, moved \(harness.caretScreenOffset - b) pt")
        }
        let retypeAt = (harness.markdown as NSString).range(of: "echo hello")
        harness.select(NSRange(location: retypeAt.location + 2, length: 0))
        harness.pump(0.2)
        let beforeRetype = harness.caretScreenOffset
        harness.retypeCodeBlock("python")
        expect(harness.markdown.contains("```python"), "Code menu retypes the block the cursor is in")
        expect(abs(harness.caretScreenOffset - beforeRetype) < 3, "Code menu retype keeps the view, moved \(harness.caretScreenOffset - beforeRetype) pt")
        let plainAt = (harness.markdown as NSString).range(of: "Paragraph 79 before").location
        let b2 = harness.caretScreenOffset
        harness.replace(NSRange(location: plainAt, length: 0), with: "x")
        harness.pump(0.3)
        expect(abs(harness.caretScreenOffset - b2) < 3, "typing in a paragraph above keeps the view, moved \(harness.caretScreenOffset - b2) pt")
        expect(abs(offsetAfter - offsetBefore) < 3, "changing the fence language keeps the view (caret moved \(offsetAfter - offsetBefore) pt)")

        let lines = (1...70).map { "echo line \($0)" }.joined(separator: "\n")
        harness.loadMarkdown("# Long\n\n```sh\n\(lines)\n```\n")
        expect(harness.pageCount >= 2, "tall fenced block spans pages, got \(harness.pageCount)")
        expect(harness.codeHeaderCount == 1, "one copy header for the split block")
        expect(harness.codeBackgroundCount >= 2, "code chrome is cut per page, got \(harness.codeBackgroundCount)")
        expect(harness.codeBackgroundsStayOnPages, "code chrome does not paint the page gutter")
        harness.pump(0.4)
        harness.scrollEditorToPage(harness.pageCount - 1)
        expect(
            harness.highlightedThumbnails == [harness.pageCount - 1],
            "thumbnail highlight follows editor scrolling, got \(harness.highlightedThumbnails)"
        )
        harness.scrollEditorToPage(0)
        expect(harness.highlightedThumbnails == [0], "highlight returns to page 1, got \(harness.highlightedThumbnails)")

        expect(harness.hasStatusBar == false, "bottom status bar is gone")
        expect(harness.pageButtonTitle == "1", "toolbar page control shows only the page number, got \(harness.pageButtonTitle ?? "nil")")
        let last = harness.pageCount
        harness.enterPageInInfo(last)
        expect(harness.pageButtonTitle == "\(last)", "typing a page in the popover jumps there, got \(harness.pageButtonTitle ?? "nil")")
        expect(harness.highlightedThumbnails == [last - 1], "thumbnail follows popover navigation")
        harness.enterPageInInfo(999)
        expect(harness.pageButtonTitle == "\(last)", "out-of-range page clamps to the last page")
        harness.enterPageInInfo(1)
        expect(harness.documentInfoValue("Code blocks") == "1", "info popover counts code blocks, got \(harness.documentInfoValue("Code blocks") ?? "nil")")
        expect(harness.documentInfoValue("Headings") == "1", "info popover counts headings")
        expect((harness.documentInfoValue("Words") ?? "0") != "0", "info popover shows words")
        expect(harness.documentInfoValue("Line endings")?.hasPrefix("LF") == true, "info popover shows line endings")
        expect(harness.documentInfoPath.contains("Untitled"), "unsaved document path reads Untitled, got \(harness.documentInfoPath)")
        expect(harness.documentInfoPathWraps, "path wraps onto several lines instead of overflowing")
        expect(harness.documentInfoPathHasSideInsets, "path keeps the popover's left and right padding")
        expect(harness.documentInfoPageDetail.hasPrefix("This page:"), "popover shows words on this page, got \(harness.documentInfoPageDetail)")
        expect(harness.documentInfoGoalVisible == false, "word goal row hidden when no goal is set")

        // Thumbnails: no re-render while the pane is being dragged, crisp again once it settles.
        harness.pump(0.4)
        expect(harness.thumbnailHasImage, "first thumbnail has a rendered bitmap")
        let rendersBefore = harness.thumbnailRenderCount
        let widthBefore = harness.thumbnailPageWidth
        harness.beginSidebarLiveResize()
        for width in stride(from: 140, through: 236, by: 8) {
            harness.setSidebarWidth(CGFloat(width), pump: 0.01)
        }
        expect(harness.thumbnailPageWidth > widthBefore + 40, "thumbnails follow the pane width immediately, \(widthBefore) → \(harness.thumbnailPageWidth)")
        expect(harness.thumbnailRenderCount == rendersBefore, "no thumbnail re-render during live resize (\(harness.thumbnailRenderCount - rendersBefore) renders)")
        harness.endSidebarLiveResize()
        harness.pump(0.5)
        expect(harness.thumbnailRenderCount > rendersBefore, "thumbnails re-render at the new size after the resize settles")
        let afterGrow = harness.thumbnailRenderCount
        harness.setSidebarWidth(220, pump: 0.5)
        expect(harness.thumbnailRenderCount == afterGrow, "shrinking slightly reuses cached bitmaps")
        harness.setSidebarWidth(140, pump: 0.3)

        let filler = (1...60).map { "Paragraph \($0) with some words." }.joined(separator: "\n\n")
        let longDoc = "# First\n\n\(filler)\n\n## Second\n\nTail words here.\n"
        harness.loadMarkdown(longDoc)
        harness.select(NSRange(location: (longDoc as NSString).range(of: "## Second").location, length: 0))
        expect(harness.pageCount >= 3 && harness.caretPage >= 2, "caret page is the heading's later page, got \(harness.caretPage) of \(harness.pageCount)")
        harness.select(NSRange(location: 0, length: 0))
        expect(harness.caretPage == 1, "caret page follows the caret")
        harness.scrollEditorToPage(harness.pageCount - 1)
        expect(harness.documentInfoPageDetail.contains("Cursor on page 1"), "popover notes when the cursor is on another page, got \(harness.documentInfoPageDetail)")
        var goalSettings = SettingsStore.shared.current
        goalSettings.wordGoal = 1000
        SettingsStore.shared.current = goalSettings
        expect(harness.documentInfoGoalVisible, "word goal row appears when a goal is set")
        expect(harness.documentInfoGoalProgress > 0 && harness.documentInfoGoalProgress < 1, "goal progress is partial, got \(harness.documentInfoGoalProgress)")
        goalSettings.wordGoal = 0
        goalSettings.showPageControl = false
        SettingsStore.shared.current = goalSettings
        harness.pump(0.1)
        expect(harness.hasPageControl == false, "page control can be hidden in Settings")
        goalSettings.showPageControl = true
        SettingsStore.shared.current = goalSettings
        harness.pump(0.1)
        expect(harness.hasPageControl, "page control comes back")

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

        if case .markdown(let spaced) = Hyperlink.destination("new%20idea.md", relativeTo: docs) {
            expect(spaced.lastPathComponent == "new idea.md", "percent-encoded link names decode, got \(spaced.lastPathComponent)")
        } else {
            expect(false, "percent-encoded .md link should be markdown")
        }

        // Links to Markdown files that do not exist yet: create an empty file (and folders) on click.
        let linkRoot = FileManager.default.temporaryDirectory.appendingPathComponent("marka-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linkRoot) }
        if case .markdown(let missing) = Hyperlink.destination("notes/new idea.md", relativeTo: linkRoot) {
            let created = (try? Hyperlink.createMarkdownFileIfMissing(missing)) ?? false
            expect(missing.path.hasPrefix(linkRoot.path + "/"), "link resolves inside the document folder, got \(missing.path)")
            expect(created, "missing linked .md file is created")
            let data = FileManager.default.contents(atPath: missing.path)
            expect(data != nil && data!.isEmpty, "created file is empty")
            try? Data("keep me".utf8).write(to: missing)
            let again = (try? Hyperlink.createMarkdownFileIfMissing(missing)) ?? true
            expect(again == false, "an existing linked file is not recreated")
            expect(FileManager.default.contents(atPath: missing.path) == Data("keep me".utf8), "existing content is never overwritten")
        } else {
            expect(false, "relative path with a space should resolve to a markdown destination")
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
        expect(harness.tableHasOnlyGitHubGrid, "table shows only the GitHub grid: no letters, numbers, or +/− chips")
        expect(harness.tableSliceCount == 1, "a short table is a single page slice, got \(harness.tableSliceCount)")
        expect(harness.relayoutStable, "table layout does not keep relayouting")
        expect(harness.tableHasFieldFocus, "insert table focuses a cell")
        let rows0 = harness.tableRowCount
        let cols0 = harness.tableColumnCount
        harness.focusTableCell(row: 2, column: 0)
        harness.menuTable("rowBelow")
        expect(harness.tableRowCount == rows0 + 1, "Format → Table → Insert Row Below adds a row, got \(harness.tableRowCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after add row")
        harness.menuTable("rowAbove")
        expect(harness.tableRowCount == rows0 + 2, "Insert Row Above adds a row, got \(harness.tableRowCount)")
        harness.menuTable("columnRight")
        expect(harness.tableColumnCount == cols0 + 1, "Insert Column Right adds a column, got \(harness.tableColumnCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after add column")
        harness.menuTable("columnLeft")
        expect(harness.tableColumnCount == cols0 + 2, "Insert Column Left adds a column, got \(harness.tableColumnCount)")
        harness.menuTable("deleteColumn")
        harness.menuTable("deleteColumn")
        expect(harness.tableColumnCount == cols0, "Delete Column removes the focused column, got \(harness.tableColumnCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after delete column")
        harness.menuTable("deleteRow")
        harness.menuTable("deleteRow")
        expect(harness.tableRowCount == rows0, "Delete Row removes the focused row, got \(harness.tableRowCount)")
        expect(harness.tableHasFieldFocus, "caret stays in the table after delete row")
        expect(harness.tableHasOnlyGitHubGrid, "editing never brings chips back")

        // Pages-style insert: the gallery inserts the preset's shape with the cursor in the first cell.
        expect(harness.tableButtonIsViewBased, "Table toolbar button can anchor the gallery under itself")
        let presets = EditorWindowHarness.tablePresets
        expect(presets.count >= 6 && presets.first?.title == "Basic", "gallery offers table presets, got \(presets.map(\.title))")
        for (index, preset) in presets.enumerated() where ["Basic", "Wide"].contains(preset.title) {
            harness.loadMarkdown("Preset")
            harness.pickTablePreset(index)
            expect(harness.tableColumnCount == preset.columns, "\(preset.title) preset has \(preset.columns) columns, got \(harness.tableColumnCount)")
            expect(harness.tableRowCount == preset.rows + 2, "\(preset.title) preset has header + delimiter + \(preset.rows) rows, got \(harness.tableRowCount)")
            expect(harness.tableHasFieldFocus, "\(preset.title): cursor lands in the new table")
        }

        harness.select(NSRange(location: (harness.markdown as NSString).range(of: "Preset").location + 1, length: 0))
        expect(harness.tableMenuEnabled == false, "Format → Table commands are disabled outside a table")
        harness.focusTableCell(row: 2, column: 0)
        expect(harness.tableMenuEnabled, "Format → Table commands are enabled in a table cell")

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
        harness.focusTableCell(row: 2, column: 1)
        harness.menuTable("deleteColumn")
        expect(harness.tableColumnCount == selectCols - 1, "Delete Column on a focused cell deletes its column, got \(harness.tableColumnCount)")
        let selectRows = harness.tableRowCount
        harness.focusTableCell(row: 2, column: 0)
        harness.menuTable("deleteRow")
        expect(harness.tableRowCount == selectRows - 1, "Delete Row on a focused cell deletes its row, got \(harness.tableRowCount)")
        expect(harness.tableOverlayCount == 1, "table remains when another data row is left")

        // In-table controls: edit bar + drag grips while the cursor is in a cell.
        harness.loadMarkdown("""
        Moves

        | A | B | C |
        | --- | --- | --- |
        | a1 | b1 | c1 |
        | a2 | b2 | c2 |
        | a3 | b3 | c3 |
        """)
        expect(harness.tableEditChromeVisible == false, "no table controls until the cursor is in the table")
        expect(harness.tableHasOnlyGitHubGrid, "idle table shows only the GitHub grid")
        harness.focusTableCell(row: 4, column: 0)
        expect(harness.tableEditChromeVisible, "table controls appear when the cursor is in a cell")
        expect(harness.tableGripsVisible.row && harness.tableGripsVisible.column, "row and column grips appear next to the focused cell")
        expect(harness.tableBarButtonHit, "the + / − controls receive clicks (they hang outside the table)")
        let bodyControls = harness.tableControlLayout
        expect(bodyControls?.visible == ["rowAbove", "rowBelow", "deleteRow", "columnLeft", "columnRight", "deleteColumn"],
               "a body cell shows + above/below, − row, + left/right, − column, got \(String(describing: bodyControls?.visible))")
        expect(bodyControls?.placedOnEdges == true, "each + sits on the edge where the new row/column appears, − beside its grip")
        if let path = ProcessInfo.processInfo.environment["MARKA_TABLE_SNAPSHOT"] { harness.tableSnapshot(to: path) }
        harness.dragTableRow(before: 2)
        func bodyOrder(_ md: String) -> [String] {
            md.components(separatedBy: "\n").compactMap { line in
                ["a1", "a2", "a3"].first { line.contains($0) }
            }
        }
        expect(bodyOrder(harness.markdown) == ["a3", "a1", "a2"], "dragging row a3 above a1 moves it, got \(bodyOrder(harness.markdown))")
        let intactRows = harness.markdown.components(separatedBy: "\n").filter { $0.contains("a1") || $0.contains("a2") || $0.contains("a3") }
        expect(intactRows.allSatisfy { line in ["1", "2", "3"].contains { n in line.contains("a\(n)") && line.contains("b\(n)") && line.contains("c\(n)") } },
               "no cell gets stale text from the old layout, got \(intactRows)")
        expect(harness.tableHasFieldFocus && harness.tableEditChromeVisible, "cursor and controls stay with the moved row")
        harness.focusTableCell(row: 2, column: 0)
        harness.dragTableColumn(before: 3)
        let header = harness.markdown.components(separatedBy: "\n").first { $0.contains("| B") || $0.contains("|B") || $0.contains("A |") } ?? ""
        let headerCells = header.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        expect(headerCells == ["B", "C", "A"], "dragging column A to the end moves it, got \(headerCells)")
        harness.undo()
        let undone = harness.markdown.components(separatedBy: "\n").first { $0.contains("A") && $0.contains("|") } ?? ""
        expect(undone.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } == ["A", "B", "C"], "a column move is one undo step")
        harness.focusTableCell(row: 2, column: 1)
        let barRows = harness.tableRowCount
        harness.tableBar("rowBelow")
        expect(harness.tableRowCount == barRows + 1, "bar: Insert Row Below, got \(harness.tableRowCount)")
        harness.tableBar("rowAbove")
        expect(harness.tableRowCount == barRows + 2, "bar: Insert Row Above")
        let barCols = harness.tableColumnCount
        harness.tableBar("columnRight")
        harness.tableBar("columnLeft")
        expect(harness.tableColumnCount == barCols + 2, "bar: Insert Column Right/Left, got \(harness.tableColumnCount)")
        harness.tableBar("deleteColumn")
        harness.tableBar("deleteRow")
        expect(harness.tableColumnCount == barCols + 1 && harness.tableRowCount == barRows + 1, "bar: Delete Column / Delete Row")
        harness.clickTableCell(row: 0, column: 1)
        let headerControls = harness.tableControlLayout
        expect(headerControls?.visible == ["rowBelow", "columnLeft", "columnRight", "deleteColumn"],
               "the header shows only + below for rows (it never moves or goes away), got \(String(describing: headerControls?.visible))")
        harness.select(NSRange(location: 1, length: 0))
        harness.pump(0.2)
        expect(harness.tableEditChromeVisible == false, "controls hide when the cursor leaves the table")

        // Cell editing as a user does it: clicks (no keystroke), arrows, WYSIWYG source editing.
        harness.loadMarkdown("""
        Cells

        | **Name** | Note |
        | --- | --- |
        | **Bold** | one |
        | two | three |
        | four | five |
        """)
        harness.clickTableCell(row: 3, column: 1)
        expect(harness.selectedTableCell.map { $0.row == 3 && $0.column == 1 } == true, "a click selects the clicked cell, got \(String(describing: harness.selectedTableCell))")
        expect(harness.tableEditChromeVisible, "a click shows the table controls")
        expect(harness.tableGripsFollowSelection, "grips sit at the clicked cell")
        harness.clickTableCell(row: 4, column: 0)
        expect(harness.selectedTableCell.map { $0.row == 4 && $0.column == 0 } == true, "clicking another cell moves the selection, got \(String(describing: harness.selectedTableCell))")
        expect(harness.tableGripsFollowSelection, "grips move with the clicked cell (no stale handles)")
        harness.menuTable("rowAbove")
        let afterInsert = harness.markdown.components(separatedBy: "\n")
        let twoIndex = afterInsert.firstIndex { $0.contains("two") } ?? -1
        let fourIndex = afterInsert.firstIndex { $0.contains("four") } ?? -1
        expect(fourIndex - twoIndex == 2, "Insert Row Above acts on the clicked row (four), got \(afterInsert)")
        harness.undo()
        harness.clickTableCell(row: 2, column: 0)
        harness.cellArrow("down")
        expect(harness.selectedTableCell.map { $0.row == 3 && $0.column == 0 } == true, "↓ moves to the cell below, got \(String(describing: harness.selectedTableCell))")
        harness.cellArrow("up")
        harness.cellArrow("up")
        expect(harness.selectedTableCell.map { $0.row == 0 } == true, "↑ from the first body row reaches the header (skips the delimiter), got \(String(describing: harness.selectedTableCell))")
        harness.cellArrow("up")
        expect(harness.selectedTableCell.map { $0.row == 0 } == true, "↑ stops at the header")
        harness.cellArrow("down")
        harness.cellArrow("right")
        expect(harness.selectedTableCell.map { $0.row == 2 && $0.column == 0 } == true, "→ inside text moves the caret, not the cell")
        harness.typeInCell("", at: 8)
        harness.cellArrow("right")
        expect(harness.selectedTableCell.map { $0.row == 2 && $0.column == 1 } == true, "→ at the end of the text moves to the next cell, got \(String(describing: harness.selectedTableCell))")
        harness.cellArrow("left")
        expect(harness.selectedTableCell.map { $0.column == 0 } == true, "← at the start moves to the previous cell")
        harness.clickTableCell(row: 2, column: 0)
        let editing = harness.cellEditorState
        expect(editing?.text == "**Bold**", "the cell keeps its Markdown source while edited, got \(String(describing: editing))")
        expect(editing?.markerHidden == true && editing?.contentBold == true, "editing is WYSIWYG: ** hidden, text bold, got \(String(describing: editing))")
        harness.typeInCell("!", at: 6)
        expect(harness.cellEditorState?.contentBold == true && harness.cellEditorState?.markerHidden == true, "styling holds while typing")
        harness.clickTableCell(row: 3, column: 0)
        expect(harness.markdown.contains("**Bold!**"), "typed text is saved inside the Markdown, got \(harness.markdown)")

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
        expect(harness.firstChipShowsRun, "python fence also has the Run in Terminal icon")
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

        // LaTeX / Mermaid source popover: same padding around the buttons on every side.
        for mermaid in [false, true] {
            let frames = PublishPopoverHarness.renderedEditorDoneFrame(mermaid: mermaid)
            let right = frames.bounds.maxX - frames.done.maxX
            let bottom = frames.done.minY - frames.bounds.minY
            expect(right >= 15 && right <= 17, "source popover: Done keeps 16 pt from the right edge, got \(right)")
            expect(bottom >= 15 && bottom <= 17, "source popover: Done keeps 16 pt from the bottom edge, got \(bottom)")
        }

        // Insert menu: Table / Code Block | Equation / Matrix | four Mermaid kinds; galleries insert blocks.
        do {
            let menus = InsertHarness.menuTitles()
            expect(menus.insert == ["Table", "Image…", "Code Block", "-", "Equation", "Matrix", "-", "Flowchart", "Left-to-right flow", "Sequence Diagram", "Pie chart",
                                  "-", "Note", "Tip", "Important", "Warning", "Caution"],
                   "Insert menu items and separators, got \(menus.insert)")
            expect(!menus.format.contains("Insert Table"), "Insert Table moved out of Format")
            expect(menus.format.contains("Code Block"), "Format keeps Code Block")
            for kind in InsertKind.allCases {
                let sizes = InsertHarness.previewSizes(kind)
                expect(sizes.allSatisfy { $0.width > 4 && $0.height > 4 }, "\(kind.title) gallery previews render, got \(sizes)")
                if let dir = ProcessInfo.processInfo.environment["MARKA_PUBLISH_SNAPSHOT_DIR"] {
                    InsertHarness.snapshot(kind, to: "\(dir)/insert-\(kind.rawValue).png")
                }
            }
            let insert = EditorWindowHarness()
            insert.loadMarkdown("Intro\n")
            insert.select(NSRange(location: 6, length: 0))
            insert.insertTemplate(.equation, 0)
            insert.insertTemplate(.flowchart, 0)
            insert.insertTemplate(.pie, 0)
            expect(insert.markdown.contains("```math\nx = \\frac") && insert.markdown.contains("```mermaid\nflowchart TD") && insert.markdown.contains("pie title"),
                   "templates inserted in order, got \(insert.markdown)")
            expect(insert.renderedFrames.count == 3, "three inserted blocks are drawn, got \(insert.renderedFrames.count)")
            insert.insertTemplate(.codeBlock, 2)
            expect(insert.markdown.hasSuffix("```python\n\n```"), "code tile inserts an empty Python fence")
            insert.close()
        }

        // Newer published version prompt texts.
        do {
            let update = PublishedUpdate(root: URL(fileURLWithPath: "/tmp/r"), path: "docs/page.md", upstream: "origin/main", commits: [
                GitCommit(hash: "a", author: "Ada", date: Date(), subject: "Fix typo"),
                GitCommit(hash: "b", author: "Bob", date: Date().addingTimeInterval(-3600), subject: "Older")
            ])
            let texts = InsertHarness.publishedUpdateTexts(update)
            expect(texts.title == "A newer version of “page.md” has been published", "update prompt title, got \(texts.title)")
            expect(texts.text.contains("Ada published “Fix typo”") && texts.text.contains("2 newer changes") && texts.text.hasSuffix("from origin/main?"),
                   "update prompt text, got \(texts.text)")
        }

        // Link card: one row — address field, then Choose File / Open / Copy / Remove icons.
        do {
            let sizes = FileReferenceHarness.linkCardSizes()
            expect(sizes.button == sizes.codeIcon && sizes.symbolPoints == 10, "card icons are code-block size (22 pt, 10 pt symbols)")
            expect(sizes.fieldFont == 10, "card field uses the document's body size, got \(sizes.fieldFont)")
            let layout = FileReferenceHarness.linkCardLayout(width: 300, url: "file.md")
            expect(layout.buttons.count == 4 && layout.buttons.allSatisfy { abs($0.midY - layout.bounds.midY) < 1 },
                   "link card icons sit on one row, vertically centred")
            expect(abs(layout.field.midY - layout.bounds.midY) < 1, "address field centred in the card")
            expect(layout.buttons.allSatisfy { $0.maxX <= layout.bounds.maxX - 4 && $0.minY >= 3 && $0.maxY <= layout.bounds.maxY - 3 },
                   "icons keep the card padding")
            expect(layout.field.maxX < layout.buttons[0].minX - 4, "field ends before the icons")
            expect(zip(layout.buttons, layout.buttons.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "icons do not overlap")
            expect(layout.tips[0].contains("Choose") && layout.tips[1].contains("Open") && layout.tips[2].contains("Copy") && layout.tips[3].contains("Remove"),
                   "icon order Choose File, Open, Copy, Remove, got \(layout.tips)")
            if let dir = ProcessInfo.processInfo.environment["MARKA_PUBLISH_SNAPSHOT_DIR"] {
                FileReferenceHarness.linkCardSnapshot(to: "\(dir)/linkcard.png")
                FileReferenceHarness.linkCardSnapshot(to: "\(dir)/linkcard-dark.png", dark: true)
            }
        }

        // File references: inside the repository → relative path; outside → ask (copy or original).
        do {
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent("marka-ref-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: base) }
            let repo = base.appendingPathComponent("repo"), docs = repo.appendingPathComponent("docs")
            try fm.createDirectory(at: docs.appendingPathComponent("img"), withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("shared"), withIntermediateDirectories: true)
            let local = docs.appendingPathComponent("img/a b.png"), sibling = repo.appendingPathComponent("shared/logo (1).png")
            let outside = base.appendingPathComponent("Downloads photo.png")
            for f in [local, sibling, outside] { try Data([1, 2, 3]).write(to: f) }
            expect(FileReferenceHarness.decide(local, image: true, documentDirectory: docs, trackedRoot: repo) == "inside:img/a%20b.png",
                   "inside: relative, escaped path")
            expect(FileReferenceHarness.decide(sibling, image: true, documentDirectory: docs, trackedRoot: repo) == "inside:../shared/logo%20%281%29.png",
                   "inside the repository but beside the document: ../ path, got \(FileReferenceHarness.decide(sibling, image: true, documentDirectory: docs, trackedRoot: repo))")
            expect(FileReferenceHarness.decide(sibling, image: true, documentDirectory: docs, trackedRoot: nil) == "outside:assets/logo (1).png",
                   "not tracked: home is the document folder, so the sibling is outside")
            expect(FileReferenceHarness.decide(outside, image: false, documentDirectory: docs, trackedRoot: repo) == "outside:Downloads photo.png",
                   "linked file outside: suggests its name next to the document")
            expect(FileReferenceHarness.decide(outside, image: true, documentDirectory: nil, trackedRoot: nil).hasPrefix("absolute:/"),
                   "untitled document: absolute path")
            let copy = try FileReferenceHarness.copy(outside, named: "assets/photo.png", into: docs)
            expect(copy.path.hasSuffix("docs/assets/photo.png") && fm.contentsEqual(atPath: copy.path, andPath: outside.path), "copy into the chosen name")
            let again = try FileReferenceHarness.copy(outside, named: "assets/photo.png", into: docs)
            expect(again == copy, "identical file already there is reused")
            try Data([9]).write(to: base.appendingPathComponent("other.png"))
            let renamed = try FileReferenceHarness.copy(base.appendingPathComponent("other.png"), named: "assets/photo.png", into: docs)
            expect(renamed.lastPathComponent == "photo-1.png", "different file never overwrites, got \(renamed.lastPathComponent)")
            let escaped = try FileReferenceHarness.copy(outside, named: "../../escape.png", into: docs)
            expect(escaped.path.hasSuffix("docs/escape.png"), "copy names cannot leave the document folder, got \(escaped.path)")
            let alert = FileReferenceHarness.alertTexts(image: true, inRepository: true)
            expect(alert.title == "“My Photo.png” is outside this document’s repository", "ask title, got \(alert.title)")
            expect(alert.text.contains("breaks on other computers") && alert.buttons == ["Copy Image", "Use Original Location", "Cancel"] && alert.field == "assets/My Photo.png",
                   "ask texts, buttons and editable name, got \(alert)")
            if let git = Git.installed {
                git.run(["init", "-q"], in: repo)
                FileReferenceHarness.trackIfNeeded(local)
                expect(git.isTracked(local, root: repo), "inserting an untracked image inside the repository starts tracking it")
            }
        } catch {
            expect(false, "file reference test failed: \(error)")
        }

        // Images: shown like GitHub — no source, own space, never overlapping text; a card on click.
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("marka-img-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let chart = dir.appendingPathComponent("chart.png"), wide = dir.appendingPathComponent("wide.png"), icon = dir.appendingPathComponent("icon.png")
            try EditorWindowHarness.writePNG(CGSize(width: 200, height: 100), to: chart)
            try EditorWindowHarness.writePNG(CGSize(width: 2000, height: 500), to: wide)
            try EditorWindowHarness.writePNG(CGSize(width: 40, height: 40), to: icon)
            let doc = "Before the image.\n\n![Chart](\(chart.path))\n\nText with ![i](\(icon.path)) inside.\nAfter the images.\n\n![Wide](\(wide.path))\n\n![Missing](nothing/here.png)\n\nEnd.\n"
            let h = EditorWindowHarness()
            h.loadMarkdown(doc)
            h.pump(0.3)
            let frames = h.imageFrames
            expect(frames.count == 4, "four images drawn (incl. placeholder), got \(frames.count)")
            if frames.count == 4 {
                let ns = doc as NSString
                func y(_ text: String) -> CGFloat { h.canvasY(of: ns.range(of: text).location) }
                expect(abs(frames[0].width - 200) < 1 && abs(frames[0].height - 100) < 1, "natural size kept, got \(frames[0].size)")
                expect(y("Before") + 10 < frames[0].minY, "image below the text before it")
                expect(frames[0].maxY <= y("Text with") + 0.5, "text after the image starts below it (no overlap): image \(frames[0].maxY), text \(y("Text with"))")
                expect(frames[1].minY > y("Text with") && frames[1].maxY <= y("After the") + 0.5, "inline image drawn below its line, before the next line")
                expect(abs(frames[2].width - h.contentWidth) < 1 && abs(frames[2].height - h.contentWidth / 4) < 1, "wide image fits the column, got \(frames[2].size)")
                expect(frames[2].maxY <= y("![Missing") + 1, "wide image does not cover the next line")
                expect(h.imagePlaceholders == [false, false, false, true], "missing image shows a placeholder, got \(h.imagePlaceholders)")
                expect(frames[3].maxY <= y("End.") + 0.5, "placeholder has its own space")
                let source = ns.range(of: "![Chart](")
                expect(h.visibleSourceCharacters(in: NSRange(location: source.location, length: 12)).isEmpty, "image source (name, path) is hidden")
                let inline = ns.range(of: "![i](")
                expect(h.visibleSourceCharacters(in: NSRange(location: inline.location, length: 5)).isEmpty, "inline image source hidden")
                expect(!h.visibleSourceCharacters(in: ns.range(of: "Text with")).isEmpty, "text around an inline image stays visible")
            }
            if let dir = ProcessInfo.processInfo.environment["MARKA_PUBLISH_SNAPSHOT_DIR"] {
                h.pageSnapshot(0, height: 700, to: "\(dir)/images-page.png")
                h.pdfPageSnapshot(0, to: "\(dir)/images-pdf.png")
            }
            h.clickImage(0)
            expect(h.imageCardURL == chart.path, "clicking an image shows its card with the path, got \(h.imageCardURL ?? "nil")")
            h.imageCardCommit(icon.path)
            expect(h.markdown.contains("![Chart](\(icon.path))"), "card changes the image source")
            expect(abs((h.imageFrames.first?.width ?? 0) - 40) < 1, "new image shown")
            h.clickImage(0)
            h.imageCardRemove()
            expect(!h.markdown.contains("![Chart]") && h.markdown.hasPrefix("Before the image.\n\n\nText"), "remove deletes the image line, got \(h.markdown.prefix(40).debugDescription)")
            expect(h.imageFrames.count == 3 && h.imageCardURL == nil, "card hides after removing")
            h.setSourceMode(true)
            expect(h.imageFrames.isEmpty, "source mode shows Markdown, no pictures")
            h.close()
        } catch {
            expect(false, "image test failed: \(error)")
        }

        // Link card icons show the pointing hand (the text view below must not force its I-beam).
        do {
            let h = EditorWindowHarness()
            h.loadMarkdown("See [the docs](https://example.com) here.\n")
            h.select(NSRange(location: 6, length: 0))
            h.pump(0.2)
            expect(h.linkCardVisible, "link card shown for the pointer test")
            for index in 0..<4 {
                let pointer = h.linkCardPointer(button: index)
                expect(pointer.button, "link card icon \(index) uses the pointing hand")
                expect(!pointer.field, "address field keeps the I-beam")
            }
            h.close()
        }

        // Paths without a scheme are relative to the document ("./" implied); only real schemes are web.
        do {
            let docs = URL(fileURLWithPath: "/tmp/marka-docs", isDirectory: true)
            for raw in ["example.com/page", "www.example.com", "docs/guide.md", "images/logo.png"] {
                switch Hyperlink.destination(raw, relativeTo: docs) {
                case .remote?: expect(false, "“\(raw)” must be a local path, not a web address")
                case .file(let url)?, .markdown(let url)?:
                    expect(url.path == "/tmp/marka-docs/" + raw, "“\(raw)” resolves like ./\(raw), got \(url.path)")
                case nil: expect(false, "“\(raw)” resolves")
                }
            }
            for raw in ["https://example.com", "http://example.com", "mailto:me@example.com"] {
                if case .remote? = Hyperlink.destination(raw, relativeTo: docs) {} else { expect(false, "“\(raw)” stays a web / mail link") }
            }
        }

        // Toolbar: Go to (overview) right after the page number; it opens the overview.
        do {
            let h = EditorWindowHarness()
            h.loadMarkdown("# One\n\n## Two\n")
            let ids = h.toolbarIdentifiers
            if let page = ids.firstIndex(of: "pageInfo"), let overview = ids.firstIndex(of: "overview") {
                expect(overview == page + 1, "overview control sits right after the page control, got \(ids)")
            } else {
                expect(false, "toolbar has page and overview controls, got \(ids)")
            }
            expect(h.openOverviewFromToolbar(), "toolbar overview button opens the Go to list")
            expect(h.toolbarPaletteLabels["pageInfo"] == "Page" && h.toolbarPaletteLabels["overview"] == "Content", "toolbar names Page and Content, got \(h.toolbarPaletteLabels)")
            let view = InsertHarness.viewMenu()
            if let page = view.firstIndex(of: "Go to Page… ⌥⌘G") {
                expect(page + 1 < view.count && view[page + 1] == "Go to Content… ⌘L", "Go to Content… ⌘L right under Go to Page…, got \(view)")
            } else { expect(false, "View menu has Go to Page…, got \(view)") }
            h.close()
        }

        if let dir = ProcessInfo.processInfo.environment["MARKA_CARD_ZOOM_SNAPSHOT_DIR"] {
            let h = EditorWindowHarness()
            h.loadMarkdown("See [the docs](assets/icon.png) here.\n")
            for zoom in [1.0, 2.0] as [CGFloat] {
                h.setManualZoom(zoom)
                h.select(NSRange(location: 6, length: 0))
                h.pump(0.3)
                h.linkCardScreenSnapshot(to: "\(dir)/card-\(Int(zoom * 100)).png")
            }
            h.close()
            let png = URL(fileURLWithPath: dir).appendingPathComponent("pic.png")
            try? EditorWindowHarness.writePNG(CGSize(width: 300, height: 120), to: png)
            let g = EditorWindowHarness()
            g.loadMarkdown("Intro\n\n![Pic](\(png.path))\n\nAfter\n")
            for zoom in [1.0, 1.25, 1.37, 1.5, 1.75, 2.0] as [CGFloat] {
                g.setManualZoom(zoom)
                g.clickImage(0)
                g.pump(0.3)
                g.linkCardScreenSnapshot(to: "\(dir)/imagecard-\(Int(zoom * 100)).png", image: true)
                g.cardCompositedSnapshot(to: "\(dir)/imagecard-composited-\(Int(zoom * 100)).png", image: true)
            }
            g.close()
        }

        // About Marka links to the GitHub project.
        expect(InsertHarness.aboutCredits.link == "https://github.com/lubino/marka" && InsertHarness.aboutCredits.text.contains("github.com/lubino/marka"),
               "About panel links to GitHub, got \(InsertHarness.aboutCredits)")

        // Card icons: drawn by an image view filling the button, the symbol fits — nothing to cut.
        expect(FileReferenceHarness.cardIconFits() == [true, true, true, true, true], "card icons fit their buttons, got \(FileReferenceHarness.cardIconFits())")

        // Run in Terminal: shell and Python blocks, not others.
        do {
            let h = EditorWindowHarness()
            h.loadMarkdown("```bash\necho hi\n```\n\n```python\nprint('hi')\n```\n\n```swift\nprint(1)\n```\n")
            expect(h.codeRunIcons == [true, true, false], "Terminal icon on bash and python blocks only, got \(h.codeRunIcons)")
            h.close()
        }

        // Find & Replace: the replace text starts where the find text does (icon in both fields).
        do {
            let h = EditorWindowHarness()
            let starts = h.findReplaceTextStarts
            expect(abs(starts.find - starts.replace) < 1, "find and replace text start at the same x, got \(starts)")
            if let dir = ProcessInfo.processInfo.environment["MARKA_PUBLISH_SNAPSHOT_DIR"] {
                h.findPopoverSnapshot(to: "\(dir)/find.png")
            }
            h.close()
        }

        // File menu: Export PDF… and Publish… have icons; File → Share anchors under the toolbar.
        do {
            let icons = InsertHarness.fileMenuItemsWithIcons()
            expect(icons.contains("Export PDF…") && icons.contains("Publish…"), "File menu icons for Export PDF and Publish, got \(icons)")
            let h = EditorWindowHarness()
            let share = h.menuShareAnchor
            if let anchor = share.anchor {
                expect(share.window.insetBy(dx: -2, dy: -2).contains(NSPoint(x: anchor.midX, y: anchor.midY)), "share anchor inside the window, got \(anchor) in \(share.window)")
                expect(anchor.minY > share.window.midY, "share anchor is up in the toolbar, got \(anchor)")
            } else {
                expect(false, "File → Share has an anchor")
            }
            h.close()
        }

        // Command line: Marka -pdf in.md out.pdf exports and reports.
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("marka-cli-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let input = dir.appendingPathComponent("in.md")
            try Data(((1...120).map { "Paragraph \($0) with a few words." }.joined(separator: "\n\n") + "\n").utf8).write(to: input)
            let output = dir.appendingPathComponent("out/result.pdf")
            let code = MarkaCommandLine.run(["Marka", "-pdf", input.path, output.path])
            expect(code == 0, "-pdf exits 0, got \(String(describing: code))")
            let pages = EditorWindowHarness.pdfPageCount(output)
            expect(pages >= 2, "PDF written with the document's pages, got \(pages)")
            expect(MarkaCommandLine.run(["Marka", "-pdf", dir.appendingPathComponent("missing.md").path]) == 1, "missing input → exit 1")
            expect(MarkaCommandLine.run(["Marka", "-pdf"]) == 2, "no input → usage, exit 2")
            expect(MarkaCommandLine.run(["Marka", "-NSDocumentRevisionsDebugMode", "YES"]) == nil, "other arguments start the app")
            let defaultOut = MarkaCommandLine.run(["Marka", "--pdf", input.path])
            expect(defaultOut == 0 && fm.fileExists(atPath: dir.appendingPathComponent("in.pdf").path), "default output next to the input")
        } catch {
            expect(false, "command line test failed: \(error)")
        }

        // Page popover: the overview icon is the link card's hover button (pointing hand), bigger.
        if let size = EditorWindowHarness.pageOverviewButtonSize {
            expect(size.width >= 28 && size.height >= 28, "page popover overview icon is card-sized, got \(size)")
        } else {
            expect(false, "page popover has the overview button")
        }

        // Markdown extras: text effects, GitHub alerts, anchors and overview, image options, emoji, tables.
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("marka-extras-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let logo = dir.appendingPathComponent("logo.png")
            try EditorWindowHarness.writePNG(CGSize(width: 200, height: 100), to: logo)
            try Data("# Notes\n".utf8).write(to: dir.appendingPathComponent("notes.md"))
            let doc = """
            # Intro

            Water is H2O and E = mc2. Press K to search.

            > [!NOTE]
            > Highlights information users should take into account.

            > [!WARNING]
            > Critical content demanding immediate attention.

            > A plain quote.

            ## Shipping :rocket:

            ![Logo](\(logo.path))

            | Left | Center | Right |
            |:-----|:------:|------:|
            | a | b \\| c | ![L](\(logo.path)) 1 |

            Done :) <3

            """
            let h = EditorWindowHarness()
            h.loadMarkdown(doc)
            // Effects through the toolbar actions, on selections.
            let h2o = (h.markdown as NSString).range(of: "2O").location
            h.select(NSRange(location: h2o, length: 1))
            h.applyEffect("subscript")
            expect(h.markdown.contains("H<sub>2</sub>O"), "subscript wraps the selection")
            let mc = (h.markdown as NSString).range(of: "mc2").location + 2
            h.select(NSRange(location: mc, length: 1))
            h.applyEffect("superscript")
            let k = (h.markdown as NSString).range(of: "Press K").location + 6
            h.select(NSRange(location: k, length: 1))
            h.applyEffect("keyboard")
            let water = (h.markdown as NSString).range(of: "Water").location
            h.select(NSRange(location: water, length: 5))
            h.applyEffect("underline")
            expect(h.markdown.contains("<ins>Water</ins>") && h.markdown.contains("mc<sup>2</sup>") && h.markdown.contains("<kbd>K</kbd>"),
                   "effects written as GitHub tags, got \(h.markdown.prefix(120))")
            h.select(NSRange(location: 0, length: 0))
            let ns = h.markdown as NSString
            expect(h.underlined(at: ns.range(of: "Water").location), "underline drawn")
            expect(h.baselineOffset(at: ns.range(of: "<sup>2").location + 5) > 0, "superscript raised")
            expect(h.baselineOffset(at: ns.range(of: "<sub>2").location + 5) < 0, "subscript lowered")
            expect(h.visibleSourceCharacters(in: ns.range(of: "<sub>")).isEmpty, "effect tags hidden")
            // Alerts: coloured bars + titles; plain quote gets a grey bar.
            expect(h.quoteBars == ["note", "warning", ""], "quote bars: note, warning, plain — got \(h.quoteBars)")
            expect(h.alertTitlesDrawn == 2, "alert titles drawn")
            expect(h.visibleSourceCharacters(in: ns.range(of: "[!NOTE]")).isEmpty, "[!NOTE] marker hidden")
            // Anchors and overview.
            h.openAnchor("#shipping-rocket")
            expect(h.caretLocation == ns.range(of: "## Shipping").location, "#anchor link scrolls to its heading")
            let rows = h.overviewRows(directory: dir)
            expect(rows.prefix(3) == ["§ Headings", "# intro", "# shipping-rocket"], "overview lists headings with anchors, got \(rows)")
            expect(rows.contains("§ Documents") && rows.contains("file notes.md") && rows.contains("file logo.png"), "overview lists files")
            expect(h.overviewRows(filter: "ship") == ["§ Headings", "# shipping-rocket"], "overview filter")
            expect(h.overviewPointers(directory: dir) == rows.map { !$0.hasPrefix("§") }, "clickable overview rows show the pointing hand, section titles do not")
            expect(h.overviewHoverAfterScroll(directory: dir, from: 1, to: 2) == [2], "scrolling under the pointer moves the highlight, never leaves several rows highlighted")
            // Emoji shortcodes (setting on for this editor only).
            expect(h.drawnEmoji.isEmpty, "emoji shortcodes off by default")
            h.setEmojiShortcodes(true)
            expect(h.drawnEmoji == ["🚀"], "shortcode drawn as emoji (emoticons stay text), got \(h.drawnEmoji)")
            if let dir = ProcessInfo.processInfo.environment["MARKA_PUBLISH_SNAPSHOT_DIR"] {
                h.pageSnapshot(0, height: 900, to: "\(dir)/extras-page.png")
                h.pdfPageSnapshot(0, to: "\(dir)/extras-pdf.png")
                h.popoverSnapshots(to: dir, directory: logo.deletingLastPathComponent())
            }
            // Image options: width + centre.
            h.applyImageOptions(0, width: "100", align: "center")
            expect(h.markdown.contains("<p align=\"center\"><img src=\"\(logo.path)\" alt=\"Logo\" width=\"100\"></p>"), "image options written as <img>")
            if let frame = h.imageFrames.first {
                expect(abs(frame.width - 100) < 1 && abs(frame.height - 50) < 1, "width 100 keeps the ratio, got \(frame.size)")
                let left = frame.minX - (h.imageFrames.first.map { _ in 0 } ?? 0)
                _ = left
            }
            // Editing a cell that holds an image shows the picture (source only with the caret inside it).
            let row2 = h.markdown.components(separatedBy: "\n").first { $0.contains("![L](\(logo.path))") }
            expect(row2 != nil, "table cell holds an image")
            h.clickTableCell(row: 2, column: 2)
            let editing = h.cellPictureState
            expect(editing.drawsPictures && editing.pictures == 1, "editing the cell shows the picture, not its file name, got \(editing)")
            if let snap = ProcessInfo.processInfo.environment["MARKA_PUBLISH_SNAPSHOT_DIR"] {
                h.pageSnapshot(0, height: 900, to: "\(snap)/cell-editing.png")
            }
            h.selectInCell(NSRange(location: 3, length: 0))
            expect(h.cellPictureState.pictures == 1, "the picture stays while editing")
            let groupEnd = (editing.text as NSString).range(of: ")").location + 1
            expect(h.cellCaret == groupEnd || h.cellCaret == 0, "caret snaps out of the hidden image Markdown, got \(h.cellCaret)")
            expect(h.tableRowHeight(2) > 60, "the row grows to the picture's height, got \(h.tableRowHeight(2))")
            h.clickTableCell(row: 2, column: 0)
            // Clicking a cell's picture opens the image card (same as pictures in the text).
            h.clickCellImage(row: 2, column: 2)
            expect(h.imageCardURL == logo.path, "cell picture opens the image card with its path, got \(h.imageCardURL ?? "nil")")
            h.imageCardCommit("logo.png")
            expect(h.markdown.contains("![L](logo.png) 1"), "card edits the image inside the cell")
            h.imageCardCommit(logo.path)

            // An image inserted while editing a table cell goes into that cell and shows there.
            h.clickTableCell(row: 2, column: 0)
            h.insertImageInCell(path: "logo.png", alt: "L")
            h.clickTableCell(row: 2, column: 2)
            expect(h.markdown.contains("| a![L](logo.png) |") || h.markdown.contains("![L](logo.png)a") || h.markdown.contains("| ![L](logo.png)"),
                   "image Markdown lands in the cell, got \(h.markdown.components(separatedBy: "\n").first { $0.contains("logo.png)") } ?? "none")")
            expect(!h.markdown.contains("\n![L](logo.png)\n"), "not inserted into the text behind the table")
            // Replace Emojis: :rocket:, :) and <3.
            let found = h.replaceAllEmojis()
            expect(found.hasSuffix("of 3"), "emoji mode finds three codes, got \(found)")
            expect(h.markdown.contains("## Shipping 🚀") && h.markdown.contains("Done 🙂 ❤️"), "Replace All puts in the emoji")
            h.close()
        } catch {
            expect(false, "extras test failed: \(error)")
        }

        // Settings: auto-load and Git integration are on by default.
        expect(EditorSettings.default.autoload && EditorSettings.default.gitIntegration, "auto-load and git default on")

        // Publish popover (fake snapshot).
        do {
            let snapshot = PublishSnapshot(
                root: URL(fileURLWithPath: "/tmp/notes"),
                branch: "main",
                hasOrigin: true,
                changes: [GitChange(path: "docs/README.md", code: " M"), GitChange(path: "assets/a.png", code: "A ")],
                diffs: ["docs/README.md": "--- a/docs/README.md\n+++ b/docs/README.md\n@@ -1 +1 @@\n-old\n+new\n", "assets/a.png": "Binary files differ\n"],
                commits: [GitCommit(hash: "0123456789", author: "Ada", date: Date(), subject: "Earlier change")]
            )
            let publish = PublishPopoverHarness(snapshot: snapshot)
            expect(publish.message == "Update 2 files", "suggested commit message, got \(publish.message)")
            expect(publish.publishEnabled, "Publish enabled with changes and a message")
            publish.setMessage("   ")
            expect(!publish.publishEnabled, "Publish disabled with an empty message")
            publish.setMessage("Fix typo")
            expect(publish.visibleTab == 0, "Message tab first")
            publish.clickFile(0)
            expect(publish.visibleTab == 2 && publish.diffText.contains("+new"), "clicking a file shows its diff")
            publish.selectTab(3)
            expect(publish.visibleTab == 3, "History tab")
            let frames = publish.buttonFrames
            let right = frames.bounds.maxX - frames.publish.maxX
            let bottom = frames.publish.minY - frames.bounds.minY
            expect(abs(right - 20) < 1 && abs(bottom - 20) < 1, "Publish button keeps the popover padding (right \(right), bottom \(bottom))")
            expect(frames.cancel.maxX <= frames.publish.minX, "Cancel sits left of Publish")
            if let dir = ProcessInfo.processInfo.environment["MARKA_PUBLISH_SNAPSHOT_DIR"] {
                publish.setMessage("Fix typo in the install section\n\nThe curl command missed -L.")
                for tab in 0..<4 { publish.snapshot(tab: tab, to: "\(dir)/publish-\(tab).png") }
                publish.snapshot(tab: 1, to: "\(dir)/publish-dark.png", dark: true)
                for mermaid in [false, true] {
                    PublishPopoverHarness.renderedEditorSnapshot(mermaid: mermaid, to: "\(dir)/source-\(mermaid ? "mermaid" : "math").png")
                }
            }
            let empty = PublishPopoverHarness(snapshot: PublishSnapshot(root: URL(fileURLWithPath: "/tmp/n"), branch: nil, hasOrigin: false, changes: [], diffs: [:], commits: []))
            expect(!empty.publishEnabled, "nothing to publish → disabled")

            let failure = PublishPopoverHarness.failureAlert(.pushFailed(log: "$ git push\nfatal: no remote\n"))
            expect(failure.title == "Publish could not be completed" && failure.text.contains("external Git tool"), "push failure texts")
            expect(failure.expandedHeight > failure.collapsedHeight + 100 && failure.log, "Show more reveals the git log")
            expect(PublishPopoverHarness.failureAlert(.commitFailed(log: "x")).title == "Publish could not be done", "commit failure title")
        }

        // Auto-load: another app changes the file → the open document follows; Marka's own save does not reload.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marka-autoload-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("watched.md")
            try Data("# One\n\nFirst.\n".utf8).write(to: url)
            let doc = try DocumentFileHarness(url: url)
            expect(doc.text.contains("First."), "document opened")
            try Data("# One\n\nChanged elsewhere.\n".utf8).write(to: url)
            doc.pump(1.0)   // file watcher, no explicit check
            expect(doc.text.contains("Changed elsewhere."), "watcher reloads an external change, got \(doc.text)")
            expect(!doc.isEdited, "reloaded document is not marked edited")
            // Atomic replace (how many editors and git write files).
            let temp = dir.appendingPathComponent("tmp.md")
            try Data("# One\n\nReplaced atomically.\n".utf8).write(to: temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            doc.pump(1.2)
            expect(doc.text.contains("Replaced atomically."), "watcher survives an atomic replace, got \(doc.text)")
            doc.type("\nTyped in Marka.")
            doc.save()
            doc.checkForExternalChange()
            expect(doc.text.contains("Typed in Marka.") && !doc.isEdited, "own save is not reloaded")
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            expect(onDisk.contains("Typed in Marka."), "save wrote the edit")
            doc.close()
        } catch {
            expect(false, "auto-load test failed: \(error)")
        }

        // Updating to a newer published version reloads the open document (even with auto-load off).
        if let git = Git.installed {
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marka-update-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: dir) }
                let hub = dir.appendingPathComponent("hub.git"), mine = dir.appendingPathComponent("mine"), theirs = dir.appendingPathComponent("theirs")
                for d in [hub, mine] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
                git.run(["init", "-q", "--bare", "-b", "main"], in: hub)
                for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@example.invalid"], ["config", "commit.gpgsign", "false"]] {
                    git.run(args, in: mine)
                }
                let page = mine.appendingPathComponent("page.md")
                try Data("# Page\n\nOld text.\n".utf8).write(to: page)
                git.run(["add", "page.md"], in: mine)
                git.run(["commit", "-q", "-m", "v1"], in: mine)
                git.run(["remote", "add", "origin", hub.path], in: mine)
                git.run(["push", "-q", "-u", "origin", "main"], in: mine)
                let doc = try DocumentFileHarness(url: page)
                doc.pump(1.0)   // the open-time check finds nothing yet
                git.run(["clone", "-q", hub.path, theirs.path], in: dir)
                for args in [["config", "user.name", "Other"], ["config", "user.email", "o@example.invalid"], ["config", "commit.gpgsign", "false"]] {
                    git.run(args, in: theirs)
                }
                try Data("# Page\n\nNew published text.\n".utf8).write(to: theirs.appendingPathComponent("page.md"))
                git.run(["commit", "-q", "-am", "v2"], in: theirs)
                git.run(["push", "-q"], in: theirs)
                if let update = GitUpdater.check(git: git, file: page) {
                    doc.applyPublishedUpdate(update)
                    expect(doc.text.contains("New published text."), "document shows the published version, got \(doc.text)")
                    expect(!doc.isEdited, "updated document is clean")
                } else {
                    expect(false, "newer published version detected")
                }
                doc.close()
            } catch {
                expect(false, "published update test failed: \(error)")
            }
        }

        // Git state: a tracked document enables Publish; an untracked one does not.
        if let git = Git.installed {
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marka-publish-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                git.run(["init", "-q"], in: dir)
                let tracked = dir.appendingPathComponent("tracked.md")
                let loose = dir.appendingPathComponent("loose.md")
                try Data("# T\n".utf8).write(to: tracked)
                try Data("# L\n".utf8).write(to: loose)
                git.run(["add", "tracked.md"], in: dir)
                let a = try DocumentFileHarness(url: tracked)
                a.refreshGitState()
                expect(a.hasPublishToolbarItem, "Publish button in the toolbar")
                expect(a.gitRootPath?.hasSuffix(dir.lastPathComponent) == true, "tracked document enables Publish, got \(a.gitRootPath ?? "nil")")
                a.close()
                // Publish starts tracking files the document links to.
                let assets = dir.appendingPathComponent("assets")
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                try Data([0x89]).write(to: assets.appendingPathComponent("my photo.png"))
                try Data("# Linked\n".utf8).write(to: dir.appendingPathComponent("linked.md"))
                let source = "# T\n\n[linked](linked.md#intro) ![p](assets/my%20photo.png) [web](https://example.com) [gone](missing.md) [dir](assets)\n"
                expect(DocumentFileHarness.linkedFiles(in: source, directory: dir).sorted() == ["linked.md", "my photo.png"],
                       "linked local files (anchor dropped, encoded space, no web / missing / folder links), got \(DocumentFileHarness.linkedFiles(in: source, directory: dir))")
                let linking = try DocumentFileHarness(url: tracked)
                linking.refreshGitState()
                linking.type("\n[linked](linked.md#intro) ![p](assets/my%20photo.png)\n")
                let changes = linking.publishChanges()
                let added = changes.filter { $0.label == "Added" && $0.path != "tracked.md" }.map(\.path).sorted()   // tracked.md itself was never committed
                expect(added == ["assets/my photo.png", "linked.md"], "Publish lists linked untracked files as Added, got \(changes)")
                expect(changes.contains { $0.path == "tracked.md" }, "the document itself is in the list")
                expect(!changes.contains { $0.path == "loose.md" }, "unlinked untracked files stay out")
                linking.close()
                let b = try DocumentFileHarness(url: loose)
                b.refreshGitState()
                expect(b.gitRootPath == nil, "untracked document keeps Publish disabled")
                b.close()
            } catch {
                expect(false, "git state test failed: \(error)")
            }
        }

        if failed > 0 {
            fputs("\(failed) UI test(s) failed.\n", stderr)
            exit(1)
        }
        print("All UI tests passed")
    }
}