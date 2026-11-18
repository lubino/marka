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
        let exclusions = PageLayout.exclusionRects(pageCount: 3, geometry: a4, containerWidth: a4.contentSize.width)
        expectEqual(exclusions.count, 2, "two holes for three pages")
        expect(exclusions[0].width == a4.contentSize.width, "exclusion width")
        expectEqual(PageLayout.pageCountFitting(usedTextHeight: 10, geometry: a4), 1, "short text is one page")
        expect(PageLayout.pageCountFitting(usedTextHeight: a4.contentSize.height * 2.5, geometry: a4) >= 3, "tall text spans pages")
        expectEqual(PageLayout.stepZoom(from: 1.0, delta: 1), 1.25, "zoom in")
        expectEqual(PageLayout.stepZoom(from: 1.0, delta: -1), 0.75, "zoom out")
        expectEqual(PageLayout.nearestZoomStep(1.07), 1.0, "nearest zoom")

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

        // Tables
        do {
            let src = """
            | A | B |
            | --- | --- |
            | 1 | 2 |
            """
            let addedRow = TableMutator.addRow(source: src, location: 20)
            expect(addedRow != nil, "add row")
            expect(addedRow!.text.split(separator: "\n").count == 4, "row count after add")
            let addedCol = TableMutator.addColumn(source: src, location: 4)
            expect(addedCol != nil, "add column")
            expect(addedCol!.text.contains("Column"), "new column header")
        }

        if failed > 0 {
            fputs("\(failed) test(s) failed.\n", stderr)
            exit(1)
        }
        print("All tests passed")
    }
}
