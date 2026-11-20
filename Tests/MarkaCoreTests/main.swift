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
            expect(ShellRunner.isRunnable("python") && ShellRunner.isRunnable("Python3") && ShellRunner.isRunnable("py"), "python fences can run")
            expect(!ShellRunner.isRunnable("swift") && !ShellRunner.isRunnable(nil), "other languages do not run")
            if let py = try? ShellRunner.writeCommandFile(script: "print('hi')", workingDirectory: "/tmp/doc", language: "python") {
                let body = (try? String(contentsOf: py, encoding: .utf8)) ?? ""
                let script = body.components(separatedBy: "\n").first { $0.hasPrefix("python3 ") } ?? ""
                let pyPath = String(script.dropFirst("python3 '".count).dropLast())
                expect(body.contains("cd '/tmp/doc'") && !script.isEmpty, "python runs via python3 in the document folder")
                expect((try? String(contentsOf: URL(fileURLWithPath: pyPath), encoding: .utf8)) == "print('hi')", "the script is saved as a .py file")
                try? FileManager.default.removeItem(at: py)
                try? FileManager.default.removeItem(atPath: pyPath)
            } else { expect(false, "python command file") }
            expect(ShellRunner.isShell(nil) == false, "missing language is not a shell")
            let body = ShellRunner.commandFileContents(script: "echo hi", workingDirectory: "/tmp/doc")
            expect(body.hasPrefix("#!/bin/zsh"), "zsh shebang")
            expect(body.contains("cd '/tmp/doc'"), "cd to document directory")
            expect(body.contains("echo hi"), "script body")
            let file = try ShellRunner.writeCommandFile(script: "echo hi", workingDirectory: nil)
            expect(FileManager.default.isExecutableFile(atPath: file.path), "command file is executable")
            try? FileManager.default.removeItem(at: file)
            expect(!body.contains("Press") && !body.contains("read"), "no key prompt by default")

            // Run the command files for real (zsh, no Terminal): exit codes, prompt, cleanup.
            func runCommand(_ url: URL) -> (status: Int32, output: String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [url.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                try? process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            }
            let plain = try ShellRunner.writeCommandFile(script: "echo working; exit 3", workingDirectory: "/tmp")
            let plainRun = runCommand(plain)
            expect(plainRun.status == 3 && plainRun.output == "working\n", "no extra output, script's exit code kept, got \(plainRun)")
            expect(!FileManager.default.fileExists(atPath: plain.path), "the command file removes itself")
            let python = try ShellRunner.writeCommandFile(script: "print(6 * 7)", workingDirectory: "/tmp", language: "python")
            let pyPath = (try? String(contentsOf: python, encoding: .utf8))?.components(separatedBy: "\n").first { $0.hasPrefix("python3 ") }
                .map { String($0.dropFirst("python3 '".count).dropLast()) } ?? ""
            let pythonRun = runCommand(python)
            if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
                expect(pythonRun.output.contains("42"), "python block runs, got \(pythonRun.output)")
            }
            expect(!FileManager.default.fileExists(atPath: python.path) && !FileManager.default.fileExists(atPath: pyPath), "the .command and .py files are cleaned up")
            let failing = try ShellRunner.writeCommandFile(script: "echo oops; false", workingDirectory: nil, waitForKey: true)
            let failingRun = runCommand(failing)
            expect(failingRun.output.contains("✗ Exited with code 1") && failingRun.output.contains("Press any key to close"), "wait mode shows the failure and asks for a key, got \(failingRun.output)")
            expect(failingRun.status == 1, "wait mode keeps the script's exit code")
            let ok = try ShellRunner.writeCommandFile(script: "true", workingDirectory: nil, waitForKey: true)
            expect(runCommand(ok).output.contains("✓ Finished"), "wait mode shows success")
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

        // Math (LaTeX subset)
        expect(MathParser.parse("\\text{if } x").rowItems.first == .text("if "), "\\text keeps its spaces")
        if case .fraction(let num, let den, bar: true) = MathParser.parse("\\frac{a+1}{b}") {
            expect(num == .row([.atom("a", .variable), .atom("+", .binary), .atom("1", .number)]), "fraction numerator, got \(num)")
            expect(den == .atom("b", .variable), "fraction denominator")
        } else { expect(false, "\\frac parses to a fraction") }
        if case .scripts(.atom("x", .variable), let sup, let sub) = MathParser.parse("x_i^{2}") {
            expect(sup == .atom("2", .number) && sub == .atom("i", .variable), "sub- and superscript, got \(String(describing: sup)) \(String(describing: sub))")
        } else { expect(false, "x_i^{2} parses to scripts") }
        if case .scripts(.largeOp("∑", limits: true), let sup, let sub) = MathParser.parse("\\sum_{k=1}^{n}") {
            expect(sup == .atom("n", .variable) && sub != nil, "sum with limits")
        } else { expect(false, "\\sum_{k=1}^{n} parses to a large operator with scripts") }
        expect(MathParser.parse("\\alpha \\leq \\infty") == .row([.atom("α", .variable), .atom("≤", .relation), .atom("∞", .ordinary)]), "Greek, relations, symbols")
        if case .root(_, let index) = MathParser.parse("\\sqrt[3]{x}") { expect(index == .atom("3", .number), "root index") } else { expect(false, "\\sqrt[3]{x}") }
        if case .delimited("(", _, ")") = MathParser.parse("\\left( \\frac{1}{2} \\right)") {} else { expect(false, "\\left( … \\right)") }
        if case .matrix(let rows, "(", ")", .centered) = MathParser.parse("\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}") {
            expect(rows.count == 2 && rows[0].count == 2 && rows[1][1] == .atom("4", .number), "pmatrix cells, got \(rows)")
        } else { expect(false, "pmatrix parses to a matrix") }
        if case .matrix(let rows, "{", "", .cases) = MathParser.parse("f(x)=\\begin{cases} 1 & x>0 \\\\ 0 & \\text{otherwise} \\end{cases}").rowItems.last ?? .row([]) {
            expect(rows.count == 2 && rows[1][1] == .text("otherwise"), "cases rows with \\text, got \(rows)")
        } else { expect(false, "cases parses") }
        expect(MathParser.parse("\\sin x") == .row([.atom("sin", .operatorName), .atom("x", .variable)]), "function names are upright operators")
        if case .styled(_, .blackboard) = MathParser.parse("\\mathbb{R}") {} else { expect(false, "\\mathbb") }
        if case .accent(_, "→", wide: false) = MathParser.parse("\\vec{v}") {} else { expect(false, "\\vec accent") }
        if case .row(let items) = MathParser.parse("\\nosuchcommand x"), case .error("\\nosuchcommand") = items.first {} else { expect(false, "unknown commands become visible errors") }
        expect(MathParser.parse("a\\,b") == .row([.atom("a", .variable), .space(3.0 / 18), .atom("b", .variable)]), "thin space")

        // Math in Markdown
        func mathSpans(_ source: String) -> [String] {
            MarkdownSyntax.spans(in: source).filter { $0.kind == .inlineMath && $0.role == .content }.map { (source as NSString).substring(with: $0.range) }
        }
        expect(mathSpans("Euler: $e^{i\\pi}+1=0$ done") == ["e^{i\\pi}+1=0"], "inline math, got \(mathSpans("Euler: $e^{i\\pi}+1=0$ done"))")
        expect(mathSpans("It costs $5 and $10 today").isEmpty, "prices are not math")
        expect(mathSpans("Code `$x$` stays code").isEmpty, "dollars inside inline code are not math")
        expect(mathSpans("Escaped \\$x$ is text").isEmpty, "an escaped dollar does not open math")
        let display = MarkdownSyntax.codeBlocks(in: "Text\n\n$$\nx^2\n$$\n\n$$ y $$\n\n```mermaid\ngraph TD\nA-->B\n```\n")
        expect(display.map { $0.language ?? "" } == ["math", "math", "mermaid"], "display math (multi- and single-line) and mermaid fences, got \(display.map(\.language))")
        expect(display.first?.innerText == "x^2" && display[1].innerText.trimmingCharacters(in: .whitespaces) == "y", "display math content")
        expect(MarkdownSyntax.isRendered(language: "mermaid") && MarkdownSyntax.isRendered(language: "math") && !MarkdownSyntax.isRendered(language: "swift"), "rendered languages")

        // Mermaid
        if case .flowchart(let chart) = Mermaid.parse("flowchart LR\n  A[Start] -->|go| B{Ready?}\n  B -- yes --> C((Done))\n  B -.-> D[(Store)]\n  C ==> A\n  %% comment\n  E & F --- G") {
            expect(chart.direction == .leftRight, "flowchart direction")
            expect(chart.node("A")?.label == "Start" && chart.node("B")?.shape == .rhombus && chart.node("C")?.shape == .circle && chart.node("D")?.shape == .database, "node labels and shapes, got \(chart.nodes)")
            expect(chart.edges.count == 6, "edges incl. & fan-out, got \(chart.edges.count)")
            expect(chart.edges[0].label == "go" && chart.edges[1].label == "yes", "edge labels (|go| and -- yes -->), got \(chart.edges.map(\.label))")
            expect(chart.edges[2].style == .dotted && chart.edges[3].style == .thick && chart.edges[4].style == .open, "edge styles")
            let layout = chart.layout { node in CGSize(width: CGFloat(node.label.count * 8 + 24), height: 36) }
            let a = layout.nodes["A"]!, b = layout.nodes["B"]!, c = layout.nodes["C"]!
            expect(a.maxX < b.minX && b.maxX < c.minX, "LR layout places ranks left to right, got \(a) \(b) \(c)")
            let rects = Array(layout.nodes.values)
            var overlap = false
            for x in rects.indices { for y in rects.indices where x < y { if rects[x].intersects(rects[y]) { overlap = true } } }
            expect(!overlap, "no two nodes overlap")
            expect(layout.edges.count == chart.edges.count && layout.edges.allSatisfy { $0.count >= 2 }, "every edge has a path")
            expect(rects.allSatisfy { CGRect(origin: .zero, size: layout.size).contains($0) }, "layout size contains every node")
        } else { expect(false, "flowchart parses") }
        if case .sequence(let seq) = Mermaid.parse("sequenceDiagram\n  participant A as Alice\n  actor B\n  A->>B: Hello\n  B-->>A: Hi\n  Note right of B: thinks\n  A-xB: bye") {
            expect(seq.participants.map(\.label) == ["Alice", "B"] && seq.participants[1].isActor, "participants and actors")
            expect(seq.events.count == 4, "messages and notes, got \(seq.events.count)")
            if case .message(_, _, let text, let dashed, .filled) = seq.events[1] { expect(text == "Hi" && dashed, "dashed reply") } else { expect(false, "reply message") }
        } else { expect(false, "sequence parses") }
        if case .pie(let pie) = Mermaid.parse("pie title Pets\n  \"Dogs\" : 386\n  \"Cats\" : 85.5") {
            expect(pie.title == "Pets" && pie.slices.map(\.label) == ["Dogs", "Cats"] && pie.slices[1].value == 85.5, "pie title and slices")
        } else { expect(false, "pie parses") }
        expect(Mermaid.parse("gantt\n title x") == .unsupported("gantt"), "other diagram types are reported, not guessed")

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

        // Text effects: GitHub-safe <ins>, <sup>, <sub>, <kbd> (+ <u>).
        do {
            let text = "a <ins>under</ins> x<sup>2</sup> H<sub>2</sub>O <kbd>⌘K</kbd> <u>old</u> <sup>**b**</sup>"
            let spans = MarkdownSyntax.inlineSpans(in: text)
            let ns = text as NSString
            func content(_ kind: StyleKind) -> [String] { spans.filter { $0.kind == kind && $0.role == .content }.map { ns.substring(with: $0.range) } }
            expectEqual(content(.underline), ["under", "old"], "underline from <ins> and <u>")
            expectEqual(content(.superscript), ["2", "**b**"], "superscript")
            expectEqual(content(.`subscript`), ["2"], "subscript")
            expectEqual(content(.keyboard), ["⌘K"], "keyboard")
            expect(spans.contains { $0.kind == .strong && $0.role == .content }, "bold inside <sup> still parsed")
            expect(MarkdownSyntax.inlineSpans(in: "a <sup>open").allSatisfy { $0.kind != .superscript }, "unclosed tag stays text")
            let wrapped = MarkdownEditing.toggleInline(source: "x2", selected: NSRange(location: 1, length: 1), left: "<sup>", right: "</sup>", kind: .superscript)
            expectEqual(wrapped.text, "x<sup>2</sup>", "wrap selection in <sup>")
            let state = MarkdownEditing.format(at: NSRange(location: 6, length: 0), in: wrapped.text)
            expect(state.superscript && !state.`subscript`, "format state sees superscript")
            let unwrapped = MarkdownEditing.toggleInline(source: wrapped.text, selected: NSRange(location: 6, length: 0), left: "<sup>", right: "</sup>", kind: .superscript)
            expectEqual(unwrapped.text, "x2", "toggle again unwraps")
        }

        // GitHub alerts.
        do {
            let doc = "> [!NOTE]\n> Useful.\n\n> [!warning]\n> Careful!\n\n> [!TIP] extra\n> no\n\n> plain\n"
            let alerts = MarkdownSyntax.alerts(in: doc)
            expectEqual(alerts.map(\.kind), [.note, .warning], "NOTE and lower-case warning; text after the marker = plain quote")
            expectEqual((doc as NSString).substring(with: alerts[0].marker), "[!NOTE]", "marker range")
            let inserted = MarkdownEditing.insertAlert(source: "Text\n", selected: NSRange(location: 5, length: 0), kind: .caution)
            expectEqual(inserted.text, "Text\n> [!CAUTION]\n> ", "insert alert")
            expectEqual(inserted.selected.location, ("Text\n> [!CAUTION]\n> " as NSString).length, "caret on the alert text line")
            expectEqual(MarkdownSyntax.alerts(in: inserted.text).first?.kind, .caution, "inserted alert is detected")
        }

        // Tables (GitHub): alignment, escaped pipes.
        do {
            let table = "| a | b | c | d |\n|---|:--|:-:|--:|\n| 1 | x \\| y | 3 | 4 |\n"
            let block = TableMutator.block(at: 0, in: table)
            expectEqual(block?.alignments, [.none, .left, .center, .right], "column alignment from the delimiter row")
            expectEqual(block?.rows[2], ["1", "x \\| y", "3", "4"], "escaped pipe stays inside its cell")
            if let cell = TableMutator.cell(at: (table as NSString).range(of: "| 1").location + 2, in: table),
               let aligned = TableMutator.setAlignment(source: table, cell: TableMutator.CellRef(block: cell.block, row: cell.row, column: 3), alignment: .center) {
                expectEqual(TableMutator.block(at: 0, in: aligned.text)?.alignments.last, .center, "set a column's alignment")
            } else { expect(false, "setAlignment") }
            if let edited = TableMutator.setCell(source: table, location: 0, row: 2, column: 0, value: "a|b") {
                expect(edited.text.contains("a\\|b"), "a typed pipe is escaped")
                expectEqual(TableMutator.block(at: 0, in: edited.text)?.columnCount, 4, "column count unchanged")
            } else { expect(false, "setCell") }
        }

        // GitHub heading anchors.
        do {
            expectEqual(MarkdownSyntax.githubSlug("Hello, World!"), "hello-world", "slug drops punctuation")
            expectEqual(MarkdownSyntax.githubSlug("Čo je nové? 2.0"), "čo-je-nové-20", "slug keeps letters with accents")
            let doc = "# Intro\n## Install `Marka.app`\n## **Bold** [link](x)\n# Intro\n"
            let anchors = MarkdownSyntax.headingAnchors(in: doc)
            expectEqual(anchors.map(\.slug), ["intro", "install-markaapp", "bold-link", "intro-1"], "anchors: markers stripped, duplicates numbered")
            expectEqual(anchors[1].title, "Install Marka.app", "plain heading title")
            expectEqual(MarkdownSyntax.heading(forAnchor: "#intro-1", in: doc)?.location, (doc as NSString).range(of: "# Intro", options: .backwards).location, "anchor → heading")
        }

        // Image options: GitHub <img> attributes and <p align="center">.
        do {
            let doc = "<p align=\"center\"><img src=\"a b.png\" alt=\"Logo\" width=\"120\"></p>\nText <img src='i.png' height=20 align=right> end\n![Plain](p.png \"Tip\")\n"
            let lines = MarkdownSyntax.imageLines(in: doc)
            expectEqual(lines.count, 3, "html and markdown image lines")
            let centred = lines[0].images[0]
            expect(lines[0].imageOnly && centred.isHTML && centred.align == "center" && centred.width == "120" && centred.alt == "Logo" && centred.source == "a b.png",
                   "centred <img> in <p>: \(centred)")
            expect(!lines[1].imageOnly && lines[1].images[0].height == "20" && lines[1].images[0].align == "right", "inline <img> attributes")
            expectEqual(lines[2].images[0].title, "Tip", "markdown title")
            if let plain = MarkdownEditing.setImageOptions(source: doc, imageAt: centred.group.location, options: ImageOptions(alt: "Logo")) {
                expect(plain.text.hasPrefix("![Logo](a b.png)\n"), "no size / align → plain Markdown (wrapper removed), got \(plain.text.prefix(30))")
            } else { expect(false, "setImageOptions plain") }
            let md = lines[2].images[0]
            if let html = MarkdownEditing.setImageOptions(source: doc, imageAt: md.group.location, options: ImageOptions(alt: "Plain", title: "Tip", width: "50%", align: "center")) {
                expect(html.text.contains("<p align=\"center\"><img src=\"p.png\" alt=\"Plain\" title=\"Tip\" width=\"50%\"></p>"), "size + centre → <img> in <p>")
                let back = MarkdownSyntax.imageLines(in: html.text).last?.images.first
                expect(back?.width == "50%" && back?.align == "center", "written options read back")
            } else { expect(false, "setImageOptions html") }
            if let removed = MarkdownEditing.removeImage(source: doc, imageAt: centred.group.location) {
                expect(removed.text.hasPrefix("Text <img"), "removing a centred image removes its wrapper line")
            } else { expect(false, "remove html image") }
        }

        // Images inside table cells.
        do {
            let doc = "Intro\n\n| Name | Logo |\n|---|---|\n| a \\| b | ![L](logo.png) and <img src=\"x.png\" width=\"40\"> |\n"
            let ns = doc as NSString
            if let block = TableMutator.block(at: ns.range(of: "| Name").location, in: doc) {
                let cell = TableMutator.cellRange(in: doc, block: block, row: 2, column: 1)
                expectEqual(cell.map { ns.substring(with: $0) }, "![L](logo.png) and <img src=\"x.png\" width=\"40\">", "cell range is the trimmed cell text")
                expectEqual(TableMutator.cellRange(in: doc, block: block, row: 2, column: 0).map { ns.substring(with: $0) }, "a \\| b", "escaped pipe stays in its cell")
            } else { expect(false, "table found") }
            let images = MarkdownSyntax.tableImages(in: doc)
            expectEqual(images.map(\.source), ["logo.png", "x.png"], "Markdown and <img> images in cells")
            expectEqual(images.first?.alt, "L", "cell image alt")
            expect(MarkdownSyntax.imageLines(in: doc).isEmpty, "cell images are not drawn as text images")
            if let edited = MarkdownEditing.setImageSource(source: doc, imageAt: images[0].group.location, to: "assets/new.png") {
                expect(edited.text.contains("| ![L](assets/new.png) and"), "change a cell image's source")
            } else { expect(false, "setImageSource in a cell") }
            if let removed = MarkdownEditing.removeImage(source: doc, imageAt: images[0].group.location) {
                expect(removed.text.contains("|  and <img") && removed.text.hasSuffix("|\n"), "remove a cell image, the row stays")
            } else { expect(false, "removeImage in a cell") }
            if let centred = MarkdownEditing.setImageOptions(source: doc, imageAt: images[0].group.location, options: ImageOptions(alt: "L", width: "80", align: "center")) {
                expect(centred.text.contains("| <img src=\"logo.png\" alt=\"L\" width=\"80\"> and") && !centred.text.contains("<p align"), "no <p> wrapper inside a table row")
            } else { expect(false, "setImageOptions in a cell") }
        }

        // Lists, task lists and quotes: editing like a word processor.
        do {
            // Several lines at once; numbers count up; indentation and quotes are kept.
            let doc = "alpha\n    beta\ngamma\n"
            let numbered = MarkdownEditing.setList(source: doc, selected: NSRange(location: 0, length: (doc as NSString).length), kind: .ordered)
            expectEqual(numbered.text, "1. alpha\n    1. beta\n2. gamma\n", "numbered list over a selection (per level)")
            let tasks = MarkdownEditing.setList(source: numbered.text, selected: NSRange(location: 0, length: (numbered.text as NSString).length), kind: .task)
            expectEqual(tasks.text, "- [ ] alpha\n    - [ ] beta\n- [ ] gamma\n", "switching the kind replaces the markers")
            let off = MarkdownEditing.setList(source: tasks.text, selected: NSRange(location: 0, length: (tasks.text as NSString).length), kind: .task)
            expectEqual(off.text, "alpha\n    beta\ngamma\n", "same kind again removes the list")
            let caret = MarkdownEditing.setList(source: "hello world\n", selected: NSRange(location: 6, length: 0), kind: .bullet)
            expect(caret.text == "- hello world\n" && caret.selected.location == 8, "single line: caret stays on the same letter, got \(caret.selected)")
            let ticked = MarkdownEditing.setList(source: "- [x] done\n", selected: NSRange(location: 3, length: 0), kind: .bullet)
            expectEqual(ticked.text, "- done\n", "task → bullet")
            // Quotes over a selection, and back.
            let quoted = MarkdownEditing.toggleQuote(source: "one\n\ntwo\n", selected: NSRange(location: 0, length: 8))
            expectEqual(quoted.text, "> one\n>\n> two\n", "quote every selected line (empty ones too)")
            expectEqual(MarkdownEditing.toggleQuote(source: quoted.text, selected: NSRange(location: 0, length: (quoted.text as NSString).length)).text, "one\n\ntwo\n", "unquote")
            // Return.
            if case .insert(let next) = MarkdownEditing.handleReturn(currentLine: "- [x] done") {
                expectEqual(next, "\n- [ ] ", "Return after a ticked task starts an unticked one")
            } else { expect(false, "task return") }
            if case .insert(let next) = MarkdownEditing.handleReturn(currentLine: "    3. third") {
                expectEqual(next, "\n    4. ", "numbered Return keeps the nesting")
            } else { expect(false, "ordered return") }
            if case .insert(let next) = MarkdownEditing.handleReturn(currentLine: "> - in a quote") {
                expectEqual(next, "\n> - ", "a list in a quote continues in the quote")
            } else { expect(false, "quote list return") }
            if case .replaceLine(let line) = MarkdownEditing.handleReturn(currentLine: "> - ") {
                expectEqual(line, "> ", "empty item in a quote ends the list, stays in the quote")
            } else { expect(false, "quote list end") }
            // Backspace at the start of an item's text.
            expectEqual(MarkdownEditing.backspaceStructure(source: "    - nested\n", caret: 6)?.text, "- nested\n", "Backspace outdents a nested item")
            expectEqual(MarkdownEditing.backspaceStructure(source: "- [ ] task\n", caret: 6)?.text, "task\n", "Backspace turns an item into text")
            expectEqual(MarkdownEditing.backspaceStructure(source: "> quote\n", caret: 2)?.text, "quote\n", "Backspace removes the quote")
            expectEqual(MarkdownEditing.backspaceStructure(source: "> - a\n", caret: 4)?.text, "> a\n", "list in a quote: the list goes first")
            expect(MarkdownEditing.backspaceStructure(source: "- text\n", caret: 4) == nil, "inside the text: ordinary Backspace")
            // Lists inside quotes and hidden prefixes.
            let q = "> - one\n> - [x] two\n> plain\n"
            let items = MarkdownSyntax.listItems(in: q)
            expect(items.count == 2 && items.allSatisfy { $0.quoteDepth == 1 }, "lists inside quotes are found, got \(items)")
            expectEqual(items.last?.kind, .task(checked: true), "task inside a quote")
            expectEqual(MarkdownSyntax.hiddenLinePrefixes(in: q).map(\.length), [4, 8, 2], "hidden prefixes: quote + list markers, quote marker")
        }

        // Statistics count GitHub <img> tags as images too.
        expectEqual(DocumentStats.compute("![a](a.png)\n<img src=\"b.png\" width=\"40%\">\n<p align=\"center\"><IMG src='c.png'></p>\n").images, 3,
                    "images: Markdown and <img>")

        // Emoji codes.
        do {
            let doc = "Ship it :rocket: :) and <3\n`:smile:` $:a:$ [x](http://a:)) :notacode: http://x.com/:p\n"
            let found = EmojiCatalog.matches(in: doc)
            expectEqual(found.map(\.code), [":rocket:", ":)", "<3"], "codes outside code / math / URLs, unknown names skipped, got \(found.map(\.code))")
            expectEqual(found.map(\.emoji), ["🚀", "🙂", "❤️"], "their emoji")
            expectEqual(EmojiCatalog.matches(in: doc, includeEmoticons: false).count, 1, "shortcodes only")
            let replaced = EmojiCatalog.replaceAll(in: doc)
            expect(replaced.count == 3 && replaced.text.hasPrefix("Ship it 🚀 🙂 and ❤️\n`:smile:`"), "replace all, got \(replaced.text.prefix(30))")
        }

        // Images: lines, image-only detection, editing.
        do {
            let doc = "# T\n![Chart](assets/chart.png)\nText with ![icon](i.png \"Icon\") inline.\n[![CI](https://x/badge.svg)](https://x) ![v](<my v.png>)\n```\n![no](code.png)\n```\n| a |\n|---|\n| ![no](t.png) |\n"
            let lines = MarkdownSyntax.imageLines(in: doc)
            expectEqual(lines.count, 3, "three image lines (code and table skipped)")
            expect(lines[0].imageOnly && lines[0].images.first?.source == "assets/chart.png" && lines[0].images.first?.alt == "Chart", "image-only line, source and alt")
            expect(!lines[1].imageOnly && lines[1].images.first?.source == "i.png", "inline image: not image-only, title stripped")
            expect(lines[2].imageOnly && lines[2].images.map(\.source) == ["https://x/badge.svg", "my v.png"], "linked badge + angle-bracket image line is image-only")
            let ns = doc as NSString
            expectEqual(ns.substring(with: lines[1].images[0].sourceRange), "i.png", "source range excludes the title")
            if let edit = MarkdownEditing.setImageSource(source: doc, imageAt: lines[1].images[0].group.location, to: "img/new.png") {
                expect(edit.text.contains("![icon](img/new.png \"Icon\")"), "set source keeps alt and title")
            } else { expect(false, "setImageSource") }
            if let edit = MarkdownEditing.setImageSource(source: doc, imageAt: lines[2].images[1].group.location, to: "b.png") {
                expect(edit.text.contains("![v](b.png)"), "angle brackets replaced too")
            } else { expect(false, "setImageSource angle") }
            if let removed = MarkdownEditing.removeImage(source: doc, imageAt: lines[0].images[0].group.location) {
                expect(removed.text.hasPrefix("# T\nText with"), "removing the only image removes its line")
            } else { expect(false, "removeImage") }
            if let removed = MarkdownEditing.removeImage(source: doc, imageAt: lines[1].images[0].group.location) {
                expect(removed.text.contains("Text with  inline."), "removing an inline image keeps the text")
            } else { expect(false, "removeImage inline") }
        }

        // Insert menu templates: every example parses cleanly.
        do {
            for kind in InsertKind.allCases {
                expect(kind.templates.count >= 3, "\(kind.title) gallery has examples")
                for template in kind.templates {
                    switch kind.preview {
                    case .math:
                        let node = MathParser.parse(template.body)
                        expect(!String(describing: node).contains("error("), "\(kind.title) “\(template.title)” has no unknown commands: \(node)")
                    case .mermaid:
                        let diagram = Mermaid.parse(template.body)
                        let ok: Bool
                        switch (kind, diagram) {
                        case (.flowchart, .flowchart), (.leftToRight, .flowchart), (.sequence, .sequence), (.pie, .pie): ok = true
                        default: ok = false
                        }
                        expect(ok, "\(kind.title) “\(template.title)” parses as its diagram type, got \(diagram)")
                    case .code:
                        expect(template.body.isEmpty && !template.sample.isEmpty, "code tiles insert an empty fence and show a sample")
                    }
                }
            }
            let euler = InsertKind.equation.templates[4]
            let mid = MarkdownEditing.insertTemplate(source: "Before after", selected: NSRange(location: 7, length: 0), template: euler)
            expectEqual(mid.text, "Before \n```math\ne^{i\\pi} + 1 = 0\n```\nafter", "template on its own lines mid-paragraph")
            expectEqual(mid.selected.location, ("Before \n```math\ne^{i\\pi} + 1 = 0\n```\n" as NSString).length, "caret after the block")
            let end = MarkdownEditing.insertTemplate(source: "Text\n", selected: NSRange(location: 5, length: 0), template: euler)
            expectEqual(end.text, "Text\n```math\ne^{i\\pi} + 1 = 0\n```\n", "template at the end")
            let code = MarkdownEditing.insertTemplate(source: "", selected: NSRange(location: 0, length: 0), template: InsertKind.codeBlock.templates[1])
            expect(code.text == "```bash\n\n```" && code.selected.location == 8, "code tile inserts an empty fence with the caret inside, got \(code.text.debugDescription)")
        }

        // Git: parsing
        do {
            let changes = Git.parsePorcelain(" M docs/a.md\0A  new file.md\0R  b.md\0old b.md\0?? img/x.png\0")
            expectEqual(changes.map(\.path), ["docs/a.md", "new file.md", "b.md", "img/x.png"], "porcelain paths (rename source skipped, spaces kept)")
            expectEqual(changes.map(\.label), ["Modified", "Added", "Renamed", "Untracked"], "porcelain labels")
            let log = Git.parseLog("abc\u{1f}Ada Lovelace\u{1f}1700000000\u{1f}Fix: a | b\u{1e}\ndef\u{1f}Bob\u{1f}1600000000\u{1f}Init\u{1e}\n")
            expectEqual(log.count, 2, "two log entries")
            expectEqual(log.first?.author, "Ada Lovelace", "log author")
            expectEqual(log.first?.subject, "Fix: a | b", "log subject keeps separators")
            expectEqual(log.first?.date, Date(timeIntervalSince1970: 1_700_000_000), "log date")
            let counts = GitPublisher.lineCounts("--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n-old\n+new\n+more\n")
            expect(counts.added == 2 && counts.removed == 1, "diff line counts ignore file headers")
            expectEqual(GitPublisher.suggestedMessage(for: [GitChange(path: "docs/README.md", code: " M")]), "Update README.md", "message for one file")
            expectEqual(GitPublisher.suggestedMessage(for: [GitChange(path: "a.md", code: "A "), GitChange(path: "b.png", code: "A ")]), "Add 2 files", "message for added files")
        }

        // Git: a real repository (skipped when git is not installed)
        if let git = Git.installed {
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent("marka-git-\(UUID().uuidString)")
            let repo = base.appendingPathComponent("repo")
            let remote = base.appendingPathComponent("remote.git")
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: base) }
            func setUp(_ dir: URL) {
                git.run(["init", "-q", "-b", "main"], in: dir)
                git.run(["config", "user.name", "Marka Test"], in: dir)
                git.run(["config", "user.email", "test@example.invalid"], in: dir)
                git.run(["config", "commit.gpgsign", "false"], in: dir)
            }
            setUp(repo)
            let doc = repo.appendingPathComponent("notes/doc.md")
            try? fm.createDirectory(at: doc.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("# Notes\n".utf8).write(to: doc)
            let root = git.repositoryRoot(containing: doc)
            expect(root != nil, "repository root found")
            let r = root ?? repo
            expectEqual(Git.relativePath(of: doc, root: r), "notes/doc.md", "relative path resolves /var → /private/var")
            expect(!git.isTracked(doc, root: r), "new file is not tracked yet")
            expect(git.repositoryRoot(containing: base.appendingPathComponent("elsewhere.md")) == nil, "outside a repository")
            git.add(["notes/doc.md"], root: r)
            expect(git.isTracked(doc, root: r), "added file is tracked")
            expectEqual(git.changes(["notes/doc.md"], root: r).first?.label, "Added", "added file shows as Added")
            expect(git.diff("notes/doc.md", root: r).contains("+# Notes"), "diff of a new file without HEAD")

            // No origin: Publish only commits.
            let first = GitPublisher.publish(git: git, root: r, paths: ["notes/doc.md"], message: "Add notes")
            if case .committedOnly = first {} else { expect(false, "without origin Publish only commits — got \(first)") }
            expectEqual(git.recentCommits(root: r).first?.subject, "Add notes", "commit is in the log")
            expectEqual(git.recentCommits(root: r).first?.author, "Marka Test", "commit author")
            expect(git.changes(["notes/doc.md"], root: r).isEmpty, "no changes after commit")

            // With origin: commit + push (sets upstream on the first push).
            try? fm.createDirectory(at: remote, withIntermediateDirectories: true)
            git.run(["init", "-q", "--bare", "-b", "main"], in: remote)
            git.run(["remote", "add", "origin", remote.path], in: r)
            try? Data("# Notes\nMore.\n".utf8).write(to: doc)
            let other = repo.appendingPathComponent("other.md")
            try? Data("staged elsewhere\n".utf8).write(to: other)
            git.add(["other.md"], root: r)
            let snapshot = GitPublisher.snapshot(git: git, root: r, files: [doc])
            expectEqual(snapshot.changes.map(\.path), ["notes/doc.md"], "snapshot lists only the given files")
            expect(snapshot.hasOrigin && snapshot.branch == "main", "snapshot sees origin and branch")
            expect(snapshot.diffs["notes/doc.md"]?.contains("+More.") == true, "snapshot diff")
            let second = GitPublisher.publish(git: git, root: r, paths: ["notes/doc.md"], message: "More notes")
            if case .pushed = second {} else { expect(false, "with origin Publish pushes — got \(second.log)") }
            let remoteLog = git.run(["log", "-1", "--format=%s", "main"], in: remote).output.trimmingCharacters(in: .whitespacesAndNewlines)
            expectEqual(remoteLog, "More notes", "commit reached the remote")
            expectEqual(git.changes(["other.md"], root: r).first?.code, "A ", "other staged work stays staged, uncommitted")

            // Publish tracks files the documents link to (inside the repository, not ignored).
            do {
                let picture = repo.appendingPathComponent("assets/photo.png")
                try? fm.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data([0x89, 0x50]).write(to: picture)
                let secret = repo.appendingPathComponent("secret.txt")
                try? Data("x".utf8).write(to: secret)
                try? Data("secret.txt\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
                let outside = base.appendingPathComponent("outside.md")
                try? Data("x".utf8).write(to: outside)
                let added = GitPublisher.trackLinkedFiles(git: git, root: r, files: [picture, secret, outside, doc])
                expectEqual(added, ["assets/photo.png"], "only the untracked, not-ignored file inside the repository is added")
                expect(git.isTracked(picture, root: r) && !git.isTracked(secret, root: r), "linked file tracked, ignored one not")
                git.run(["rm", "-q", "--cached", "assets/photo.png"], in: r)
                try? fm.removeItem(at: repo.appendingPathComponent(".gitignore"))
                try? fm.removeItem(at: secret)
                try? fm.removeItem(at: picture)
            }

            // Push failure: the commit stays, the outcome carries git's log.
            git.run(["remote", "set-url", "origin", base.appendingPathComponent("missing.git").path], in: r)
            try? Data("# Notes\nMore.\nEven more.\n".utf8).write(to: doc)
            let third = GitPublisher.publish(git: git, root: r, paths: ["notes/doc.md"], message: "Third")
            if case .pushFailed(let log) = third {
                expect(log.contains("$ git push"), "failure log shows the push command")
            } else {
                expect(false, "unreachable origin → pushFailed — got \(third)")
            }
            expectEqual(git.recentCommits(root: r).first?.subject, "Third", "commit kept when push fails")
            expectEqual(git.recentCommits(root: r, count: 3).count, 3, "last three commits")

            // Commit failure: nothing to commit.
            let fourth = GitPublisher.publish(git: git, root: r, paths: ["notes/doc.md"], message: "Nothing")
            if case .commitFailed = fourth {} else { expect(false, "nothing to commit → commitFailed — got \(fourth)") }

            // Newer published version: another clone pushes, this one sees and fast-forwards.
            do {
                let hub = base.appendingPathComponent("hub.git")
                let mine = base.appendingPathComponent("mine")
                let theirs = base.appendingPathComponent("theirs")
                try? fm.createDirectory(at: hub, withIntermediateDirectories: true)
                git.run(["init", "-q", "--bare", "-b", "main"], in: hub)
                try? fm.createDirectory(at: mine, withIntermediateDirectories: true)
                setUp(mine)
                let page = mine.appendingPathComponent("page.md")
                try? Data("v1\n".utf8).write(to: page)
                git.run(["add", "page.md"], in: mine)
                git.run(["commit", "-q", "-m", "v1"], in: mine)
                git.run(["remote", "add", "origin", hub.path], in: mine)
                git.run(["push", "-q", "-u", "origin", "main"], in: mine)
                expect(GitUpdater.check(git: git, file: page) == nil, "up to date → no update")
                git.run(["clone", "-q", hub.path, theirs.path], in: base)
                git.run(["config", "user.name", "Other Author"], in: theirs)
                git.run(["config", "user.email", "other@example.invalid"], in: theirs)
                git.run(["config", "commit.gpgsign", "false"], in: theirs)
                try? Data("v2 from elsewhere\n".utf8).write(to: theirs.appendingPathComponent("page.md"))
                git.run(["commit", "-q", "-am", "Second version"], in: theirs)
                git.run(["push", "-q"], in: theirs)
                let update = GitUpdater.check(git: git, file: page)
                expectEqual(update?.commits.count, 1, "one newer published commit")
                expectEqual(update?.commits.first?.author, "Other Author", "who published it")
                expectEqual(update?.upstream, "origin/main", "upstream name")
                expect((try? String(contentsOf: page, encoding: .utf8)) == "v1\n", "check alone never changes the file")
                if let update {
                    expect(GitUpdater.update(git: git, root: update.root).ok, "fast-forward update succeeds")
                }
                expectEqual(try? String(contentsOf: page, encoding: .utf8), "v2 from elsewhere\n", "file updated to the published version")
                expect(GitUpdater.check(git: git, file: page) == nil, "up to date after the update")
                // Diverged: a local commit and a newer published one → update refuses, file untouched.
                try? Data("local\n".utf8).write(to: mine.appendingPathComponent("other.md"))
                git.run(["add", "other.md"], in: mine)
                git.run(["commit", "-q", "-m", "Local"], in: mine)
                try? Data("v3\n".utf8).write(to: theirs.appendingPathComponent("page.md"))
                git.run(["commit", "-q", "-am", "Third version"], in: theirs)
                git.run(["push", "-q"], in: theirs)
                if let diverged = GitUpdater.check(git: git, file: page) {
                    let result = GitUpdater.update(git: git, root: diverged.root)
                    expect(!result.ok && result.log.contains("merge --ff-only"), "diverged branch → update fails with a log")
                } else {
                    expect(false, "diverged branch still reports the newer version")
                }
                expectEqual(try? String(contentsOf: page, encoding: .utf8), "v2 from elsewhere\n", "failed update leaves the file")
                expect(GitUpdater.check(git: git, file: repo.appendingPathComponent("notes/doc.md")) == nil, "no upstream → no check")
            }
        } else {
            print("SKIP git tests: git is not installed")
        }

        if failed > 0 {
            fputs("\(failed) test(s) failed.\n", stderr)
            exit(1)
        }
        print("All tests passed")
    }
}
