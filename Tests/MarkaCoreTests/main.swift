import Foundation
import MarkaCore

@main
enum MarkaTests {
    static func main() {
        var failed = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                fputs("FAIL: \(message)\n", stderr)
                failed += 1
            }
        }
        func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
            expect(a == b, "\(message) — got \(a), expected \(b)")
        }

        // FileCodec identity
        do {
            let raw = Data("Hello **world**\n".utf8)
            let decoded = FileCodec.decode(raw)
            let encoded = decoded.codec.encode(
                normalized: decoded.normalized,
                originalNormalized: decoded.normalized,
                originalData: raw
            )
            expect(encoded == raw, "UTF-8 LF round-trip must be byte-identical")
        }
        do {
            var raw = Data([0xEF, 0xBB, 0xBF])
            raw.append(contentsOf: Data("a\r\nb\r\n".utf8))
            let decoded = FileCodec.decode(raw)
            expect(decoded.codec.hasUTF8BOM, "BOM detected")
            expectEqual(decoded.codec.lineEnding, .crlf, "CRLF detected")
            expectEqual(decoded.normalized, "a\nb\n", "normalized to LF")
            let encoded = decoded.codec.encode(
                normalized: decoded.normalized,
                originalNormalized: decoded.normalized,
                originalData: raw
            )
            expect(encoded == raw, "BOM+CRLF identity round-trip")
            let changed = decoded.codec.encode(
                normalized: "a\nb\nc\n",
                originalNormalized: decoded.normalized,
                originalData: raw
            )
            expect(changed.starts(with: [0xEF, 0xBB, 0xBF]), "BOM preserved on edit")
            expect(String(data: changed.dropFirst(3), encoding: .utf8) == "a\r\nb\r\nc\r\n", "CRLF preserved on edit")
        }

        // Metrics
        expectEqual(TextMetrics.wordCount("Hello, world."), 2, "word count")
        expectEqual(TextMetrics.wordCount(""), 0, "empty word count")
        expectEqual(TextMetrics.characterCount("ř"), 1, "composed character")

        // Page geometry
        let a4 = PageGeometry()
        expect(abs(a4.paperSize.width - 595.275) < 0.1, "A4 width in points")
        expect(abs(a4.paperSize.height - 841.89) < 0.1, "A4 height in points")
        expect(a4.interPageGap <= 12, "Preview-like page gap, got \(a4.interPageGap)")
        expectEqual(EditorSettings.default.fontName, "Times New Roman", "default body font matches Preview documents")
        expect(EditorSettings.default.fontSize <= 10, "default body size is 10pt or smaller")
        let exclusions = PageLayout.exclusionRects(pageCount: 3, geometry: a4, containerWidth: a4.contentSize.width)
        expectEqual(exclusions.count, 2, "two holes for three pages")
        expect(exclusions[0].width == a4.contentSize.width, "exclusion width")
        expectEqual(PageLayout.pageCountFitting(usedTextHeight: 10, geometry: a4), 1, "short text is one page")
        expect(PageLayout.pageCountFitting(usedTextHeight: a4.contentSize.height * 2.5, geometry: a4) >= 3, "tall text spans pages")
        expectEqual(PageLayout.stepZoom(from: 1.0, delta: 1), 1.25, "zoom in")
        expectEqual(PageLayout.stepZoom(from: 1.0, delta: -1), 0.75, "zoom out")
        expectEqual(PageLayout.nearestZoomStep(1.07), 1.0, "nearest zoom")
        do {
            let g = PageGeometry()
            let padX: CGFloat = 8
            let padY: CGFloat = 28
            let page0 = PageLayout.contentRect(pageIndex: 0, geometry: g, paddingX: padX, paddingY: padY)
            let page1 = PageLayout.contentRect(pageIndex: 1, geometry: g, paddingX: padX, paddingY: padY)
            let spanning = CGRect(x: page0.minX, y: page0.midY, width: page0.width, height: page1.midY - page0.midY)
            let pieces = PageLayout.pageContentPieces(
                of: spanning,
                pageCount: 2,
                geometry: g,
                paddingX: padX,
                paddingY: padY
            )
            expectEqual(pieces.count, 2, "spanning rect splits across two pages")
            let gap = CGRect(
                x: page0.minX,
                y: page0.maxY,
                width: page0.width,
                height: page1.minY - page0.maxY
            )
            expect(gap.height > 8, "pages have a gutter")
            for piece in pieces {
                let overlap = piece.intersection(gap)
                expect(overlap.isNull || overlap.height < 0.5, "piece stays off the page gutter")
            }
            let short = PageLayout.pageContentPieces(
                of: page0.insetBy(dx: 4, dy: 40),
                pageCount: 2,
                geometry: g,
                paddingX: padX,
                paddingY: padY
            )
            expectEqual(short.count, 1, "single-page rect stays one piece")
        }

        // Syntax
        do {
            let source = "# Title\n\nHello **bold** and *em* and `code`.\n"
            let spans = MarkdownSyntax.spans(in: source)
            expect(spans.contains(where: { $0.kind == .heading(1) && $0.role == .content }), "H1 content")
            expect(spans.contains(where: { $0.kind == .strong && $0.role == .marker }), "strong markers")
            expect(spans.contains(where: { $0.kind == .emphasis && $0.role == .content }), "emphasis content")
            expect(spans.contains(where: { $0.kind == .inlineCode && $0.role == .content }), "inline code")
            let outline = MarkdownSyntax.outline(in: source)
            expectEqual(outline.first?.title, "Title", "outline title")
        }
        do {
            let source = "```swift\nlet x = 1\n```\n"
            let spans = MarkdownSyntax.spans(in: source)
            expect(spans.contains(where: {
                if case .codeBlock(let lang) = $0.kind { return lang == "swift" && $0.role == .content }
                return false
            }), "fenced swift block")
        }
        do {
            let source = "- [ ] task\n- [x] done\n"
            let spans = MarkdownSyntax.spans(in: source)
            expect(spans.contains(where: {
                if case .list(_, let task) = $0.kind { return task }
                return false
            }), "task list")
        }
        do {
            let source = "Intro\n\n\(PageBreakMarker.comment)\n\nNext page\n"
            expectEqual(PageBreakMarker.ranges(in: source).count, 1, "pagebreak range")
            let spans = MarkdownSyntax.spans(in: source)
            expect(spans.contains(where: { $0.kind == .pageBreak }), "pagebreak span")
        }
        do {
            let source = "[link](https://example.com) and ![img](./assets/a.png)\n"
            let spans = MarkdownSyntax.spans(in: source)
            expect(spans.contains(where: {
                if case .link(let url) = $0.kind { return url == "https://example.com" && $0.role == .content }
                return false
            }), "link")
            expect(spans.contains(where: {
                if case .image(let url) = $0.kind { return url == "./assets/a.png" }
                return false
            }), "image")
        }
        do {
            let source = "[`README.md`](./README.md)"
            let spans = MarkdownSyntax.spans(in: source)
            expect(spans.contains(where: {
                if case .link(let url) = $0.kind { return url == "./README.md" && $0.role == .content }
                return false
            }), "code-styled markdown link")
            expect(spans.contains(where: {
                if case .inlineCode = $0.kind { return $0.role == .content }
                return false
            }), "link display can contain inline code")
            let loc = (source as NSString).range(of: "README.md").location
            expectEqual(MarkdownEditing.link(at: loc, in: source)?.url ?? "", "./README.md", "link at code display text")
        }
        do {
            let quotes = MarkdownSyntax.quotes(in: "> hello quote\n>\n> still quoted\n")
            expectEqual(quotes.count, 1, "one quote block")
            expectEqual(quotes.first?.innerText ?? "", "hello quote\n\nstill quoted", "quote copy strips >")
        }

        // Editing
        do {
            let src = "hello world"
            let wrapped = MarkdownEditing.toggleWrap(
                source: src,
                selected: NSRange(location: 6, length: 5),
                left: "**",
                right: "**"
            )
            expectEqual(wrapped.text, "hello **world**", "wrap bold")
            let unwrapped = MarkdownEditing.toggleWrap(
                source: wrapped.text,
                selected: wrapped.selected,
                left: "**",
                right: "**"
            )
            expectEqual(unwrapped.text, src, "unwrap bold")
        }
        do {
            let src = "Hello"
            let h1 = MarkdownEditing.setHeading(source: src, selected: NSRange(location: 0, length: 0), level: 1)
            expect(h1.text.hasPrefix("# Hello"), "set H1")
            let h2 = MarkdownEditing.setHeading(source: h1.text, selected: NSRange(location: 0, length: 0), level: 2)
            expect(h2.text.hasPrefix("## Hello"), "cycle H2")
        }
        do {
            let src = "Item"
            let list = MarkdownEditing.toggleList(source: src, selected: NSRange(location: 0, length: 0), ordered: false, task: false)
            expect(list.text.hasPrefix("- Item"), "ul")
        }
        do {
            let src = "See [GitHub](https://github.com) now"
            let loc = (src as NSString).range(of: "GitHub").location
            let link = MarkdownEditing.link(at: loc, in: src)
            expect(link != nil, "link at display text")
            expectEqual(link?.text ?? "", "GitHub", "link display text")
            expectEqual(link?.url ?? "", "https://github.com", "link url")
            expect(MarkdownEditing.link(at: (src as NSString).range(of: "now").location, in: src) == nil, "plain text is not a link")
            let updated = MarkdownEditing.setLinkURL(source: src, location: loc, url: "https://example.com")
            expectEqual(updated?.text ?? "", "See [GitHub](https://example.com) now", "set link URL")
            expect(MarkdownEditing.setLinkURL(source: src, location: loc, url: "https://github.com") == nil, "unchanged URL is a no-op")
            let removed = MarkdownEditing.removeLink(source: src, location: loc)
            expectEqual(removed?.text ?? "", "See GitHub now", "remove link keeps display text")
            let inserted = MarkdownEditing.insertLink(
                source: "hello",
                selected: NSRange(location: 0, length: 5),
                url: "https://"
            )
            expectEqual(inserted.text, "[hello](https://)", "insert link wraps selection")
        }
        do {
            switch MarkdownEditing.handleReturn(currentLine: "- item") {
            case .insert(let s):
                expectEqual(s, "\n- ", "continue ul")
            default:
                expect(false, "continue ul action")
            }
            switch MarkdownEditing.handleReturn(currentLine: "- ") {
            case .replaceLine(let s):
                expectEqual(s, "", "terminate empty ul")
            default:
                expect(false, "terminate ul")
            }
            switch MarkdownEditing.handleReturn(currentLine: "1. hi") {
            case .insert(let s):
                expectEqual(s, "\n2. ", "continue ol")
            default:
                expect(false, "continue ol")
            }
        }
        do {
            expectEqual(MarkdownEditing.indentListLine("- a", indent: true), "    - a", "indent")
            expectEqual(MarkdownEditing.indentListLine("    - a", indent: false), "- a", "outdent")
        }
        do {
            let inserted = MarkdownEditing.insertTable(source: "Hello", selected: NSRange(location: 5, length: 0), rows: 2, columns: 3)
            expect(inserted.text.contains("| --- | --- | --- |"), "separator row")
            expect(inserted.text.contains("Column") == false, "Pages-style table starts with empty cells")
            let block = TableMutator.allBlocks(in: inserted.text).first
            expectEqual(block?.columnCount ?? 0, 3, "three columns")
            expectEqual(block?.rows.count ?? 0, 3, "header + sep + one body row")
        }

        // Tables
        do {
            let src = """
            | A | B |
            | --- | --- |
            | 1 | 2 |
            """
            let loc1 = (src as NSString).range(of: "1").location
            let locB = (src as NSString).range(of: "B").location
            let addedRow = TableMutator.addRow(source: src, location: loc1)
            expect(addedRow != nil, "add row")
            expect(addedRow!.text.split(separator: "\n").count == 4, "row count after add")
            let addedCol = TableMutator.addColumn(source: src, location: locB)
            expect(addedCol != nil, "add column")
            expectEqual(TableMutator.allBlocks(in: addedCol!.text).first?.columnCount ?? 0, 3, "new empty column")

            let above = TableMutator.insertRow(source: src, location: loc1, placement: .above)
            expect(above != nil, "insert row above")
            let aboveRows = TableMutator.allBlocks(in: above!.text).first?.rows ?? []
            expectEqual(aboveRows.count, 4, "header + sep + new + original")
            expect(aboveRows[2].joined().contains("1") == false, "new row sits above data")
            expect(aboveRows[3].contains("1"), "original data row shifted down")

            let below = TableMutator.insertRow(source: src, location: loc1, placement: .below)
            expectEqual(TableMutator.allBlocks(in: below!.text).first?.rows.count, 4, "insert row below")

            let left = TableMutator.insertColumn(source: src, location: locB, placement: .left)
            expect(left != nil, "insert column left")
            let leftHeader = String(left!.text.split(separator: "\n").first!)
            expect(leftHeader.contains("A") && leftHeader.contains("B"), "column inserted, A and B remain")
            expectEqual(TableMutator.allBlocks(in: left!.text).first?.columnCount ?? 0, 3, "column inserted between A and B")

            let right = TableMutator.insertColumn(source: src, location: locB, placement: .right)
            expectEqual(TableMutator.allBlocks(in: right!.text).first?.columnCount ?? 0, 3, "insert column right")

            let deletedRow = TableMutator.deleteRow(source: src, location: loc1)
            expect(deletedRow != nil, "deleting the last data row removes the table")
            expect(TableMutator.allBlocks(in: deletedRow!.text).isEmpty, "table gone after last row")
            expect(deletedRow!.text.contains("|") == false, "pipes removed with the table")

            let deletedHeader = TableMutator.deleteRow(source: src, location: locB)
            expect(TableMutator.allBlocks(in: deletedHeader!.text).isEmpty, "deleting the header removes the table")

            let twoRows = """
            | A | B |
            | --- | --- |
            | 1 | 2 |
            | 3 | 4 |
            """
            let loc3 = (twoRows as NSString).range(of: "3").location
            let afterDeleteRow = TableMutator.deleteRow(source: twoRows, location: loc3)
            expect(afterDeleteRow != nil, "delete extra data row")
            expect(afterDeleteRow!.text.contains("3") == false, "deleted row gone")
            expect(afterDeleteRow!.text.contains("1"), "remaining row kept")

            let afterDeleteCol = TableMutator.deleteColumn(source: src, location: locB)
            expect(afterDeleteCol != nil, "delete column")
            expect(afterDeleteCol!.text.contains("B") == false, "deleted column gone")
            expect(afterDeleteCol!.text.contains("A"), "remaining column kept")
            let lastCol = TableMutator.deleteColumn(source: afterDeleteCol!.text, location: 2)
            expect(lastCol != nil, "deleting the last column removes the table")
            expect(TableMutator.allBlocks(in: lastCol!.text).isEmpty, "table gone after last column")

            let gone = TableMutator.deleteTable(source: src, location: loc1)
            expect(gone != nil, "delete table")
            expect(TableMutator.allBlocks(in: gone!.text).isEmpty, "explicit delete removes the table")

            let edited = TableMutator.setCell(source: src, location: loc1, row: 2, column: 0, value: "hello")
            expect(edited != nil, "set cell")
            expect(edited!.text.contains("hello"), "cell value written")
        }

        // Fenced code blocks
        do {
            let source = "```sh\necho hi\n```\n"
            let blocks = MarkdownSyntax.codeBlocks(in: source)
            expectEqual(blocks.count, 1, "one fenced block")
            expectEqual(blocks.first?.language, "sh", "shell language")
            expectEqual(blocks.first?.innerText, "echo hi", "inner copy text")
            expect(blocks.first!.innerText.isEmpty == false, "copy payload is non-empty")
            let empty = MarkdownEditing.insertCodeBlock(source: "Hello", selected: NSRange(location: 5, length: 0), language: "bash")
            expect(empty.text.contains("Hello\n```bash\n\n```"), "empty bash fence is its own block, got \(empty.text)")
            expectEqual(empty.selected.length, 0, "empty fence has a caret, not a selection")
            let atInner = empty.selected.location
            expectEqual((empty.text as NSString).substring(with: NSRange(location: atInner, length: 4)), "\n```", "caret is on the blank inner line")
            let wrapped = MarkdownEditing.insertCodeBlock(source: "use x here", selected: NSRange(location: 4, length: 1), language: "text")
            expect(wrapped.text.contains("```text\nx\n```"), "selection becomes the fence body")
            let retarget = MarkdownEditing.setCodeBlockLanguage(source: empty.text, selected: empty.selected, language: "python")
            expect(retarget?.text.contains("```python") == true, "retarget keeps the fence and changes language")
            expect(retarget?.text.contains("```bash") == false, "old language is gone")
        }

        // Live format + toggle unwrap
        do {
            let src = "Hello **world** today"
            let world = (src as NSString).range(of: "world")
            let format = MarkdownEditing.format(at: world, in: src)
            expect(format.bold, "caret in **world** is bold")
            expect(format.italic == false, "not italic")
            let unbold = MarkdownEditing.toggleInline(
                source: src,
                selected: NSRange(location: world.location + 1, length: 0),
                left: "**",
                right: "**",
                kind: .strong
            )
            expectEqual(unbold.text, "Hello world today", "toggle unwraps enclosing bold")
            let plain = "Hello world today"
            let wrapRange = (plain as NSString).range(of: "world")
            let wrapped = MarkdownEditing.toggleInline(
                source: plain,
                selected: wrapRange,
                left: "**",
                right: "**",
                kind: .strong
            )
            expect(wrapped.text.contains("**world**"), "selection wraps in bold")
            let headingSrc = "# Title\n\nPara"
            let title = (headingSrc as NSString).range(of: "Title")
            expectEqual(MarkdownEditing.format(at: title, in: headingSrc).headingLevel, 1, "heading 1 at caret")
            let para = (headingSrc as NSString).range(of: "Para")
            expectEqual(MarkdownEditing.format(at: para, in: headingSrc).headingLevel, 0, "paragraph at caret")
            let demoted = MarkdownEditing.setHeading(source: headingSrc, selected: title, level: 0)
            expect(demoted.text.hasPrefix("Title"), "heading 0 strips hashes")
            expect(demoted.text.contains("# Title") == false, "ATX marker removed")
            let code = MarkdownEditing.format(at: NSRange(location: 1, length: 0), in: "`x`")
            expect(code.inlineCode, "inline code at caret")
            let fence = MarkdownEditing.format(at: NSRange(location: 6, length: 0), in: "```sh\necho\n```\n")
            expect(fence.inCodeBlock, "caret in fence")
            let locked = MarkdownEditing.availability(for: fence, sourceMode: false)
            expect(locked.inline == false && locked.heading == false && locked.table == false, "no formatting inside a fence")
            let tableSrc = "| A |\n| --- |\n| 1 |\n"
            let cell = MarkdownEditing.format(at: (tableSrc as NSString).range(of: "1"), in: tableSrc)
            expect(cell.inTable, "caret in table")
            expect(MarkdownEditing.availability(for: cell, sourceMode: false).inline == false, "WYSIWYG table overlay cannot take inline format")
            expect(MarkdownEditing.availability(for: cell, sourceMode: true).inline, "source mode can wrap cell text")
            expect(MarkdownEditing.availability(for: cell, sourceMode: true).heading == false, "headings cannot sit in a table row")
            let tick = MarkdownEditing.format(at: NSRange(location: 1, length: 0), in: "`x`")
            let tickAvail = MarkdownEditing.availability(for: tick, sourceMode: false)
            expect(tickAvail.inline == false, "no bold inside inline code")
            expect(tickAvail.inlineCode, "inline code can unwrap")
            expect(tickAvail.heading, "a heading can still wrap the line")
        }

        do {
            let g = PageGeometry()
            let nearEnd = g.contentSize.height - 78
            let flow = PageLayout.flowTableRows(
                startY: nearEnd,
                storageRows: [0, 2, 3, 4, 5, 6],
                rowHeight: 34,
                topPad: 24,
                bottomPad: 24,
                geometry: g
            )
            expect(flow.rows.contains(where: { $0.isRepeatedHeader }), "Pages repeats the header on the next page")
            expect(Set(flow.rows.map(\.page)).count >= 2, "tall table uses more than one page")
            expect(flow.contentHeight < flow.endY - flow.startY + 1, "spacing excludes the page gutter")
            let huge = PageLayout.flowTableRows(
                startY: 12,
                storageRows: [0, 2, 3],
                rowHeight: 10_000,
                topPad: 11,
                bottomPad: 11,
                geometry: g
            )
            expect(huge.rows.count >= 1, "oversized rows still produce a flow")
            expect(huge.rows.count <= 8, "page walking is capped so layout cannot hang")
            expectEqual(PageLayout.columnLetter(0), "A", "first column letter")
            expectEqual(PageLayout.columnLetter(1), "B", "second column letter")
            expectEqual(PageLayout.columnLetter(25), "Z", "26th column letter")
            expectEqual(PageLayout.columnLetter(26), "AA", "column 27 wraps to AA")
            expectEqual(PageLayout.columnLetter(27), "AB", "column 28 is AB")
            let slices = PageLayout.tablePageSlices(
                flow: flow,
                rowHeight: 34,
                topPad: 24,
                bottomPad: 24
            )
            expect(slices.count >= 2, "each page gets its own table slice, got \(slices.count)")
            expect(slices.first?.isContinuation == false, "the first slice is the original table")
            expect(slices.dropFirst().allSatisfy(\.isContinuation), "later slices repeat the header")
            expect(Set(slices.map(\.page)).count == slices.count, "slices map 1:1 onto pages")
            if let repeated = flow.rows.first(where: \.isRepeatedHeader) {
                let top = PageLayout.contentTop(pageIndex: repeated.page, geometry: g)
                expect(
                    repeated.y >= top + 24 - 0.5,
                    "continuation pages leave topPad for column letters, y=\(repeated.y) top=\(top)"
                )
            } else {
                expect(false, "flow should repeat the header after a page break")
            }
            let firstHeight = slices[0].height
            expect(firstHeight >= 34 + 24, "a slice includes the column-letter bar")
        }

        do {
            expect(MarkdownEditing.isATXHeadingLine("# Title", maxLevel: 2), "ATX h1")
            expect(MarkdownEditing.isATXHeadingLine("## Sub", maxLevel: 2), "ATX h2")
            expect(MarkdownEditing.isATXHeadingLine("### H3", maxLevel: 2) == false, "h3 is not a ruled heading")
            expect(MarkdownEditing.isSetextUnderline("====="), "setext h1 underline")
            let blankAfter = MarkdownEditing.snapOutOfHeadingRule(
                source: "# Title\n\nPara",
                selected: NSRange(location: 8, length: 0)
            )
            expect(blankAfter != nil, "blank line under h1 is not typeable")
            expectEqual(blankAfter?.location ?? -1, 9, "caret moves past the rule gap")
            let setext = MarkdownEditing.snapOutOfHeadingRule(
                source: "Title\n=====\n",
                selected: NSRange(location: 6, length: 0)
            )
            expect(setext != nil, "setext underline is not typeable")
            expect((setext?.location ?? 99) <= 5, "caret returns to the heading text")
        }

        // Shell runner
        do {
            expect(ShellRunner.isShell("bash"), "bash is a shell fence")
            expect(ShellRunner.isShell("zsh"), "zsh is a shell fence")
            expect(ShellRunner.isShell("sh"), "sh is a shell fence")
            expect(ShellRunner.isShell("python") == false, "python is not a shell fence")
            expect(ShellRunner.isShell(nil) == false, "missing language is not a shell")
            let body = ShellRunner.commandFileContents(script: "echo hi", workingDirectory: "/tmp/doc")
            expect(body.hasPrefix("#!/bin/zsh"), "zsh shebang")
            expect(body.contains("cd '/tmp/doc'"), "cd to document directory")
            expect(body.contains("echo hi"), "script body")
            let file = try ShellRunner.writeCommandFile(script: "echo hi", workingDirectory: nil)
            expect(FileManager.default.isExecutableFile(atPath: file.path), "command file is executable")
            try? FileManager.default.removeItem(at: file)
        } catch {
            expect(false, "shell command file: \(error)")
        }

        let statsSource = """
        # Title

        First paragraph with a [link](https://a.b) and ![pic](assets/p.png).
        Still the first paragraph.

        Second paragraph.

        ```swift
        # not a heading
        [not](a-link)
        ```

        | A | B |
        | --- | --- |
        | 1 | 2 |

        - [x] done
        - [ ] open

        ---

        ## Sub
        """
        let stats = DocumentStats.compute(statsSource)
        expect(stats.headings == 2, "stats headings, got \(stats.headings)")
        expect(stats.paragraphs == 2, "stats paragraphs, got \(stats.paragraphs)")
        expect(stats.links == 1, "stats links skip images and fenced code, got \(stats.links)")
        expect(stats.images == 1, "stats images, got \(stats.images)")
        expect(stats.codeBlocks == 1, "stats code blocks, got \(stats.codeBlocks)")
        expect(stats.tables == 1, "stats tables, got \(stats.tables)")
        expect(stats.tasks == 2 && stats.completedTasks == 1, "stats tasks \(stats.completedTasks)/\(stats.tasks)")
        expect(stats.lines == 22, "stats lines, got \(stats.lines)")
        expect(stats.charactersWithoutSpaces < stats.characters, "no-space count is smaller")
        expect(DocumentStats.compute("").readingMinutes == 0, "empty doc reads in 0 min")
        expect(DocumentStats.compute("word").readingMinutes == 1, "short doc reads in 1 min")
        let long = Array(repeating: "word", count: 461).joined(separator: " ")
        expect(DocumentStats.compute(long).readingMinutes == 3, "461 words ≈ 3 min")

        // Table row / column moves
        let grid = "| A | B | C |\n| --- | :-: | --: |\n| a1 | b1 | c1 |\n| a2 | b2 | c2 |\n| a3 | b3 | c3 |"
        if let a3 = TableMutator.cell(at: (grid as NSString).range(of: "a3").location, in: grid),
           let moved = TableMutator.moveRow(source: grid, cell: a3, to: 2) {
            let lines = moved.text.components(separatedBy: "\n")
            expect(lines[2].contains("a3") && lines[3].contains("a1") && lines[4].contains("a2"), "row a3 moves to the top of the body, got \(lines)")
            expect((moved.text as NSString).substring(with: moved.selected).contains("a3"), "caret follows the moved row")
            expect(TableMutator.moveRow(source: grid, cell: a3, to: 0)?.text.components(separatedBy: "\n")[0].contains("A") == true, "the header never moves")
        } else {
            expect(false, "moveRow should apply")
        }
        if let b1 = TableMutator.cell(at: (grid as NSString).range(of: "b1").location, in: grid),
           let moved = TableMutator.moveColumn(source: grid, cell: b1, to: 2) {
            let lines = moved.text.components(separatedBy: "\n")
            let header = lines[0].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            expect(header == ["A", "C", "B"], "column B moves to the end, got \(header)")
            let row = lines[2].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            expect(row == ["a1", "c1", "b1"], "cells move with their column, got \(row)")
            let delimiter = lines[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            expect(delimiter.count == 3 && delimiter[1].hasSuffix(":") && !delimiter[1].hasPrefix(":") && delimiter[2].hasPrefix(":") && delimiter[2].hasSuffix(":"), "alignment moves with its column, got \(delimiter)")
        } else {
            expect(false, "moveColumn should apply")
        }

        // Find & replace
        let hay = "Marka marks MARKA; remark marka_x Marka"
        expect(FindEngine.matches(of: "marka", in: hay).count == 4, "case-insensitive finds Marka, MARKA, marka (in marka_x) and Marka")
        expect(FindEngine.matches(of: "Marka", in: hay, options: .init(caseSensitive: true)).count == 2, "match case")
        expect(FindEngine.matches(of: "marka", in: hay, options: .init(wholeWord: true)).count == 3, "whole words skip marka_x and remark")
        expect(FindEngine.matches(of: "", in: hay).isEmpty, "empty query finds nothing")
        let found = FindEngine.matches(of: "marka", in: hay)
        expect(FindEngine.nextIndex(in: found, after: 1) == 1, "next match after the caret")
        expect(FindEngine.nextIndex(in: found, after: 1000) == 0, "next wraps to the first")
        expect(FindEngine.nextIndex(in: found, after: 0, backwards: true) == found.count - 1, "previous wraps to the last")
        let replaced = FindEngine.replaceAll("Marka", with: "Marka 2", in: hay, options: .init(caseSensitive: true, wholeWord: true))
        expect(replaced.count == 2 && replaced.text == "Marka 2 marks MARKA; remark marka_x Marka 2", "replace all, got \(replaced.text)")
        let grow = FindEngine.replaceAll("a", with: "aa", in: "a-a")
        expect(grow.text == "aa-aa" && grow.count == 2, "replacement containing the query does not loop")

        // Combined inline Markdown — spans as "text|kind|role" strings
        func inlineSpans(_ source: String) -> Set<String> {
            var out = Set<String>()
            for span in MarkdownSyntax.spans(in: source) {
                let text = (source as NSString).substring(with: span.range)
                var kind = String(describing: span.kind)
                if let paren = kind.firstIndex(of: "(") { kind = String(kind[..<paren]) }
                out.insert("\(text)|\(kind)|\(span.role)")
            }
            return out
        }
        let boldLink = inlineSpans("**[readme](README.md)**")
        expect(boldLink.contains("**|strong|marker"), "bold wraps a link: ** markers, got \(boldLink)")
        expect(boldLink.contains("readme|link|content"), "link inside bold keeps its label")
        let boldCode = inlineSpans("Get **`Marka.dmg`** now")
        expect(boldCode.contains("`Marka.dmg`|strong|content"), "bold wraps inline code, got \(boldCode)")
        expect(boldCode.contains("Marka.dmg|inlineCode|content"), "inline code inside bold")
        let italicCode = inlineSpans("*`Marka.dmg`*")
        expect(italicCode.contains("`Marka.dmg`|emphasis|content"), "italic wraps inline code, got \(italicCode)")
        let snake = inlineSpans("`my_var_name` and `a*b*c`")
        expect(!snake.contains { $0.contains("|emphasis|") }, "_ and * inside inline code never become emphasis")

        // Syntax highlighting
        func hl(_ code: String, _ info: String) -> [String: SyntaxHighlighter.Kind] {
            var map: [String: SyntaxHighlighter.Kind] = [:]
            for t in SyntaxHighlighter.tokens(in: code, info: info) {
                map[(code as NSString).substring(with: t.range)] = t.kind
            }
            return map
        }
        expect(SyntaxHighlighter.language(for: "C++") == .cpp, "c++ fence maps to cpp")
        expect(SyntaxHighlighter.language(for: "yml") == .yaml, "yml maps to yaml")
        expect(SyntaxHighlighter.language(for: "py {.numberLines}") == .python, "info string attributes are ignored")
        expect(SyntaxHighlighter.language(for: "brainfuck") == nil, "unknown language is not highlighted")
        let bash = hl("# setup\nexport NAME=\"$HOME/x\"\nif [ -f a ]; then echo ok; fi", "bash")
        expect(bash["# setup"] == .comment, "bash comment")
        expect(bash["export"] == .keyword && bash["if"] == .keyword && bash["fi"] == .keyword, "bash keywords")
        expect(bash["$HOME"] == .variable, "bash variable inside a string")
        expect(bash["echo"] == .function, "bash builtin command")
        let json = hl("{\"name\": \"Marka\", \"n\": -1.5e3, \"ok\": true, \"x\": null}", "json")
        expect(json["\"name\""] == .property && json["\"Marka\""] == .string, "json key vs string")
        expect(json["-1.5e3"] == .number && json["true"] == .constant && json["null"] == .constant, "json number and literals")
        let py = hl("@cache\ndef f(x: int) -> str:\n    return \"\"\"doc\"\"\"  # done\nprint(None)", "python")
        expect(py["@cache"] == .meta && py["def"] == .keyword && py["int"] == .type, "python decorator, keyword, type")
        expect(py["\"\"\"doc\"\"\""] == .string && py["# done"] == .comment && py["None"] == .constant, "python string, comment, None")
        expect(py["print"] == .function, "python builtin call")
        let js = hl("const x = `t ${1}`; // c\nfunction go() { return new Map(); }", "js")
        expect(js["const"] == .keyword && js["// c"] == .comment && js["`t ${1}`"] == .string, "js keyword, comment, template")
        expect(js["go"] == .function && js["Map"] == .type, "js call and constructor type")
        let cpp = hl("#include <vector>\nstd::vector<int> v; /* x */ auto n = nullptr;", "c++")
        expect(cpp["#include"] == .meta && cpp["int"] == .type && cpp["/* x */"] == .comment && cpp["nullptr"] == .constant, "c++ tokens")
        let swift = hl("@MainActor struct A { let n = 0x1F; func f() -> String? { nil } }", "swift")
        expect(swift["@MainActor"] == .meta && swift["struct"] == .keyword && swift["0x1F"] == .number, "swift attribute, keyword, hex")
        expect(swift["String"] == .type && swift["nil"] == .constant && swift["A"] == .type, "swift types and nil")
        let html = hl("<!-- c --><a href=\"/x\" class='y'>Tom &amp; Jerry</a>", "html")
        expect(html["<!-- c -->"] == .comment && html["a"] == .tag && html["href"] == .attribute, "html comment, tag, attribute")
        expect(html["\"/x\""] == .string && html["&amp;"] == .constant, "html attribute value and entity")
        let xml = hl("<?xml version=\"1.0\"?><plist><key>A</key></plist>", "xml")
        expect(xml["<?xml version=\"1.0\"?>"] == .meta && xml["plist"] == .tag, "xml declaration and tag")
        let css = hl("/* c */ .btn:hover { color: #fff; margin: 4px 0; width: calc(100% - 2px) !important; }", "css")
        expect(css["/* c */"] == .comment && css[".btn"] == .attribute && css[":hover"] == .keyword, "css comment, class, pseudo")
        expect(css["color"] == .property && css["#fff"] == .constant && css["4px"] == .number, "css property, colour, length")
        expect(css["calc"] == .function && css["!important"] == .keyword, "css function and !important")
        let yaml = hl("---\nname: Marka # app\nport: 8080\nenabled: true\nlist:\n  - \"x\"\nref: *base", "yaml")
        expect(yaml["---"] == .meta && yaml["name"] == .property && yaml["# app"] == .comment, "yaml document, key, comment")
        expect(yaml["8080"] == .number && yaml["true"] == .constant && yaml["\"x\""] == .string && yaml["*base"] == .variable, "yaml values")
        let sql = hl("SELECT id, count(*) FROM users WHERE name = 'a' -- q", "sql")
        expect(sql["SELECT"] == .keyword && sql["FROM"] == .keyword && sql["'a'"] == .string && sql["-- q"] == .comment, "sql tokens (case-insensitive)")
        let go = hl("package main\nfunc main() { var s string = \"x\" }", "go")
        expect(go["package"] == .keyword && go["string"] == .type && go["main"] != nil, "go tokens")
        let samples: [(String, String)] = [
            ("echo \"$A ${B}\" $1 'c' # d", "bash"), ("{\"a\": [1, {\"b\": \"c\"}]}", "json"),
            ("x = '''a\nb''' # c", "python"), ("<a b=\"c\"><!-- d --></a>", "html"), ("a { b: c; } /* d */", "css"),
            ("k: v # c\n- \"q\"", "yaml"), ("fn main() { let s = \"x\"; } // c", "rust"), ("unterminated \"string", "swift")
        ]
        for (code, info) in samples {
            let tokens = SyntaxHighlighter.tokens(in: code, info: info).sorted { $0.range.location < $1.range.location }
            var end = 0
            var ok = true
            for t in tokens {
                if t.range.location < end || NSMaxRange(t.range) > (code as NSString).length || t.range.length == 0 { ok = false }
                end = NSMaxRange(t.range)
            }
            expect(ok, "\(info) tokens are non-overlapping and in range")
        }

        if failed > 0 {
            fputs("\(failed) test(s) failed.\n", stderr)
            exit(1)
        }
        print("All tests passed")
    }
}
