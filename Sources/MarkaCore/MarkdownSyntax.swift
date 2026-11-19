import Foundation

public enum StyleKind: Equatable, Sendable {
    case heading(Int)
    case paragraph
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    /// `$…$` — rendered as math in WYSIWYG.
    case inlineMath
    case codeBlock(language: String?)
    case blockquote
    case list(ordered: Bool, task: Bool)
    case link(url: String)
    case image(url: String)
    case table
    case thematicBreak
    case pageBreak
    case syntax
}

public enum StyleRole: Equatable, Sendable {
    case content
    case marker
}

public struct StyleSpan: Equatable, Sendable {
    public var range: NSRange
    public var kind: StyleKind
    public var role: StyleRole
    /// Marker glyphs are revealed when the caret/selection intersects this group.
    public var group: NSRange

    public init(range: NSRange, kind: StyleKind, role: StyleRole, group: NSRange) {
        self.range = range
        self.kind = kind
        self.role = role
        self.group = group
    }
}

public struct MarkdownDocumentOutline: Equatable, Sendable {
    public var level: Int
    public var title: String
    public var range: NSRange
}

/// Range-accurate GFM-ish parser. The source string is never rewritten.
public enum MarkdownSyntax {
    public struct FencedCodeBlock: Equatable, Sendable {
        public var group: NSRange
        public var language: String?
        public var content: NSRange
        public var innerText: String
    }

    /// Fenced blocks Marka draws instead of showing as code: ```math / $$…$$ and ```mermaid.
    public static func isRendered(language: String?) -> Bool {
        guard let language = language?.split(separator: " ").first?.lowercased() else { return false }
        return language == "math" || language == "mermaid" || language == "latex" || language == "tex"
    }

    public static func renderedBlocks(in source: String) -> [FencedCodeBlock] {
        codeBlocks(in: source).filter { isRendered(language: $0.language) }
    }

    public static func codeBlocks(in source: String) -> [FencedCodeBlock] {
        let ns = source as NSString
        var map: [Int: FencedCodeBlock] = [:]
        for span in spans(in: source) {
            guard case .codeBlock(let language) = span.kind else { continue }
            var block = map[span.group.location] ?? FencedCodeBlock(
                group: span.group,
                language: language,
                content: NSRange(location: 0, length: 0),
                innerText: ""
            )
            block.language = language
            block.group = span.group
            if span.role == .content {
                block.content = span.range
                var text = ns.substring(with: span.range)
                if text.hasPrefix("\n") { text.removeFirst() }
                if text.hasSuffix("\n") { text.removeLast() }
                block.innerText = text
            }
            map[span.group.location] = block
        }
        return map.values.sorted { $0.group.location < $1.group.location }
    }

    public struct QuoteBlock: Equatable, Sendable {
        public var group: NSRange
        public var innerText: String
    }

    public static func quotes(in source: String) -> [QuoteBlock] {
        var seen = Set<Int>()
        var result: [QuoteBlock] = []
        for span in spans(in: source) {
            guard span.kind == .blockquote, span.role == .content else { continue }
            if seen.contains(span.group.location) { continue }
            seen.insert(span.group.location)
            result.append(QuoteBlock(group: span.group, innerText: quoteInnerText(span.group, source: source)))
        }
        return result.sorted { $0.group.location < $1.group.location }
    }

    static func quoteInnerText(_ group: NSRange, source: String) -> String {
        let raw = (source as NSString).substring(with: group)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let stripped = lines.map { line -> String in
            var s = String(line)
            while s.hasPrefix(" ") || s.hasPrefix("\t") { s.removeFirst() }
            if s.hasPrefix(">") { s.removeFirst() }
            if s.hasPrefix(" ") { s.removeFirst() }
            return s
        }
        return stripped.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    public static func outline(in source: String) -> [MarkdownDocumentOutline] {
        spans(in: source).compactMap { span in
            guard span.role == .content, case .heading(let level) = span.kind else { return nil }
            let ns = source as NSString
            let title = ns.substring(with: span.range)
                .trimmingCharacters(in: .whitespaces)
            return MarkdownDocumentOutline(level: level, title: title, range: span.group)
        }
    }

    public static func spans(in source: String) -> [StyleSpan] {
        SpanMemo.shared.spans(in: source)
    }

    static func parseSpans(in source: String) -> [StyleSpan] {
        let ns = source as NSString
        let lines = splitLines(ns)
        var spans: [StyleSpan] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            if PageBreakMarker.isPageBreakLine(line.text) {
                let group = line.range
                spans.append(StyleSpan(range: group, kind: .pageBreak, role: .marker, group: group))
                i += 1
                continue
            }
            if let heading = parseATXHeading(line) {
                spans.append(contentsOf: heading)
                spans.append(contentsOf: parseInline(ns, range: headingContentRange(from: heading)))
                i += 1
                continue
            }
            if isThematicBreak(trimmed) {
                spans.append(StyleSpan(range: line.range, kind: .thematicBreak, role: .content, group: line.range))
                i += 1
                continue
            }
            if trimmed.hasPrefix("$$") {
                let (block, next) = parseDisplayMath(lines: lines, start: i)
                spans.append(contentsOf: block)
                i = next
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let (block, next) = parseFence(lines: lines, start: i)
                spans.append(contentsOf: block)
                i = next
                continue
            }
            if trimmed.hasPrefix(">") {
                let (quote, next) = parseQuote(ns: ns, lines: lines, start: i)
                spans.append(contentsOf: quote)
                i = next
                continue
            }
            if let list = parseListPrefix(line.text) {
                let (items, next) = parseList(ns: ns, lines: lines, start: i, ordered: list.ordered, task: list.task)
                spans.append(contentsOf: items)
                i = next
                continue
            }
            if i + 1 < lines.count, isTableSeparator(lines[i + 1].text), line.text.contains("|") {
                let (table, next) = parseTable(ns: ns, lines: lines, start: i)
                spans.append(contentsOf: table)
                i = next
                continue
            }
            if i + 1 < lines.count, isSetextUnderline(lines[i + 1].text, char: "=") {
                let group = union(line.range, lines[i + 1].range)
                spans.append(StyleSpan(range: line.range, kind: .heading(1), role: .content, group: group))
                spans.append(StyleSpan(range: lines[i + 1].range, kind: .heading(1), role: .marker, group: group))
                spans.append(contentsOf: parseInline(ns, range: line.range))
                i += 2
                continue
            }
            if i + 1 < lines.count, isSetextUnderline(lines[i + 1].text, char: "-") {
                let group = union(line.range, lines[i + 1].range)
                spans.append(StyleSpan(range: line.range, kind: .heading(2), role: .content, group: group))
                spans.append(StyleSpan(range: lines[i + 1].range, kind: .heading(2), role: .marker, group: group))
                spans.append(contentsOf: parseInline(ns, range: line.range))
                i += 2
                continue
            }
            let para = collectParagraph(lines: lines, start: i)
            let group = union(para.lines.first!.range, para.lines.last!.range)
            spans.append(StyleSpan(range: group, kind: .paragraph, role: .content, group: group))
            spans.append(contentsOf: parseInline(ns, range: group))
            i = para.next
        }
        return spans
    }

    // MARK: - Lines

    struct Line {
        var range: NSRange
        var text: String
    }

    static func splitLines(_ ns: NSString) -> [Line] {
        var lines: [Line] = []
        var start = 0
        let n = ns.length
        while start <= n {
            if start == n {
                break
            }
            var end = start
            while end < n {
                let ch = ns.character(at: end)
                if ch == 10 { break } // \n
                end += 1
            }
            let range = NSRange(location: start, length: end - start)
            lines.append(Line(range: range, text: ns.substring(with: range)))
            start = min(n, end + 1)
            if end == n { break }
        }
        return lines
    }

    // MARK: - Blocks

    static func parseATXHeading(_ line: Line) -> [StyleSpan]? {
        let ns = line.text as NSString
        var i = 0
        while i < ns.length && ns.character(at: i) == 32 { i += 1 }
        var hashes = 0
        while i + hashes < ns.length && ns.character(at: i + hashes) == 35 { hashes += 1 }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let after = i + hashes
        if after < ns.length {
            let ch = ns.character(at: after)
            if ch != 32 && ch != 9 { return nil }
        }
        let group = line.range
        var spans: [StyleSpan] = []
        let markerLen = after < ns.length ? hashes + 1 : hashes
        let marker = NSRange(location: line.range.location + i, length: markerLen)
        spans.append(StyleSpan(range: marker, kind: .heading(hashes), role: .marker, group: group))
        let contentLoc = line.range.location + i + markerLen
        let contentLen = max(0, NSMaxRange(line.range) - contentLoc)
        if contentLen > 0 {
            var trailing = 0
            let full = line.text as NSString
            var j = full.length - 1
            while j >= i + markerLen && (full.character(at: j) == 32 || full.character(at: j) == 35) {
                if full.character(at: j) == 35 { trailing = full.length - j }
                j -= 1
            }
            let trimmedLen = contentLen - trailing
            if trimmedLen > 0 {
                spans.append(StyleSpan(
                    range: NSRange(location: contentLoc, length: trimmedLen),
                    kind: .heading(hashes),
                    role: .content,
                    group: group
                ))
            }
            if trailing > 0 {
                spans.append(StyleSpan(
                    range: NSRange(location: contentLoc + trimmedLen, length: trailing),
                    kind: .heading(hashes),
                    role: .marker,
                    group: group
                ))
            }
        }
        return spans
    }

    static func headingContentRange(from spans: [StyleSpan]) -> NSRange {
        let contents = spans.filter { $0.role == .content }
        if let first = contents.first {
            return first.range
        }
        return NSRange(location: 0, length: 0)
    }

    static func isThematicBreak(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let set = Set(compact)
        return set.count == 1 && (set.contains("-") || set.contains("*") || set.contains("_"))
    }

    static func isSetextUnderline(_ text: String, char: Character) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0 == char }
    }

    static func parseFence(lines: [Line], start: Int) -> ([StyleSpan], Int) {
        let open = lines[start]
        let trimmed = open.text.trimmingCharacters(in: .whitespaces)
        let fenceChar = trimmed.first ?? "`"
        var fenceLen = 0
        for ch in trimmed {
            if ch == fenceChar { fenceLen += 1 } else { break }
        }
        let lang = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
        var end = start + 1
        while end < lines.count {
            let t = lines[end].text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(String(repeating: String(fenceChar), count: fenceLen)) && t.unicodeScalars.allSatisfy({ $0 == fenceChar.unicodeScalars.first || $0 == " " }) {
                break
            }
            end += 1
        }
        let closed = end < lines.count
        let last = closed ? lines[end] : lines[lines.count - 1]
        let group = union(open.range, last.range)
        var spans: [StyleSpan] = []
        spans.append(StyleSpan(range: open.range, kind: .codeBlock(language: lang.isEmpty ? nil : lang), role: .marker, group: group))
        if closed {
            let innerStart = NSMaxRange(open.range) + 1
            let innerEnd = last.range.location
            if innerEnd > innerStart {
                spans.append(StyleSpan(
                    range: NSRange(location: innerStart, length: innerEnd - innerStart),
                    kind: .codeBlock(language: lang.isEmpty ? nil : lang),
                    role: .content,
                    group: group
                ))
            }
            spans.append(StyleSpan(range: last.range, kind: .codeBlock(language: lang.isEmpty ? nil : lang), role: .marker, group: group))
            return (spans, end + 1)
        }
        let innerStart = NSMaxRange(open.range)
        let innerEnd = NSMaxRange(last.range)
        if innerEnd > innerStart {
            spans.append(StyleSpan(
                range: NSRange(location: innerStart, length: innerEnd - innerStart),
                kind: .codeBlock(language: lang.isEmpty ? nil : lang),
                role: .content,
                group: group
            ))
        }
        return (spans, lines.count)
    }

    /// `$$ … $$` display math (one line or several) — a block like a ```math fence.
    static func parseDisplayMath(lines: [Line], start: Int) -> ([StyleSpan], Int) {
        let open = lines[start]
        let kind = StyleKind.codeBlock(language: "math")
        let text = open.text as NSString
        let lead = open.text.prefix { $0 == " " }.utf16.count
        // Single line: $$ x^2 $$
        let afterOpen = text.substring(from: min(text.length, lead + 2))
        if afterOpen.trimmingCharacters(in: .whitespaces).count >= 2, afterOpen.trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
            let closeOffset = (afterOpen as NSString).range(of: "$$", options: .backwards).location
            let base = open.range.location + lead
            var spans = [StyleSpan(range: NSRange(location: base, length: 2), kind: kind, role: .marker, group: open.range)]
            if closeOffset > 0 {
                spans.append(StyleSpan(range: NSRange(location: base + 2, length: closeOffset), kind: kind, role: .content, group: open.range))
            }
            let closeStart = base + 2 + closeOffset
            spans.append(StyleSpan(range: NSRange(location: closeStart, length: NSMaxRange(open.range) - closeStart), kind: kind, role: .marker, group: open.range))
            return (spans, start + 1)
        }
        // Several lines: $$ … $$ on their own lines.
        var end = start + 1
        while end < lines.count, !lines[end].text.trimmingCharacters(in: .whitespaces).hasSuffix("$$") { end += 1 }
        guard end < lines.count else {
            return ([StyleSpan(range: open.range, kind: .paragraph, role: .content, group: open.range)], start + 1)
        }
        let last = lines[end]
        let group = union(open.range, last.range)
        var spans = [StyleSpan(range: open.range, kind: kind, role: .marker, group: group)]
        let innerStart = NSMaxRange(open.range) + 1
        if last.range.location > innerStart {
            spans.append(StyleSpan(range: NSRange(location: innerStart, length: last.range.location - innerStart), kind: kind, role: .content, group: group))
        }
        spans.append(StyleSpan(range: last.range, kind: kind, role: .marker, group: group))
        return (spans, end + 1)
    }

    static func parseQuote(ns: NSString, lines: [Line], start: Int) -> ([StyleSpan], Int) {
        var end = start
        while end < lines.count {
            let t = lines[end].text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") || t.isEmpty && end + 1 < lines.count && lines[end + 1].text.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                end += 1
                continue
            }
            if t.hasPrefix(">") { end += 1; continue }
            break
        }
        let block = Array(lines[start..<end])
        let group = union(block.first!.range, block.last!.range)
        var spans: [StyleSpan] = [StyleSpan(range: group, kind: .blockquote, role: .content, group: group)]
        for line in block {
            if let idx = line.text.firstIndex(of: ">") {
                let offset = line.text.utf16.distance(from: line.text.startIndex, to: idx)
                var markerLen = 1
                let local = line.text as NSString
                if offset + 1 < local.length && (local.character(at: offset + 1) == 32 || local.character(at: offset + 1) == 9) {
                    markerLen = 2
                }
                let marker = NSRange(location: line.range.location + offset, length: markerLen)
                spans.append(StyleSpan(range: marker, kind: .blockquote, role: .marker, group: group))
                let rest = NSRange(location: NSMaxRange(marker), length: NSMaxRange(line.range) - NSMaxRange(marker))
                if rest.length > 0 {
                    spans.append(contentsOf: parseInline(ns, range: rest))
                }
            }
        }
        return (spans, end)
    }

    struct ListPrefix {
        var ordered: Bool
        var task: Bool
        var markerLength: Int
    }

    static func parseListPrefix(_ text: String) -> ListPrefix? {
        let ns = text as NSString
        var i = 0
        while i < ns.length && (ns.character(at: i) == 32 || ns.character(at: i) == 9) { i += 1 }
        guard i < ns.length else { return nil }
        let ch = ns.character(at: i)
        if ch == 45 || ch == 42 || ch == 43 { // - * +
            var len = 1
            if i + 1 < ns.length && ns.character(at: i + 1) == 32 { len = 2 }
            else { return nil }
            var task = false
            let after = i + len
            if after + 3 <= ns.length {
                let box = ns.substring(with: NSRange(location: after, length: 3))
                if box == "[ ]" || box.lowercased() == "[x]" {
                    task = true
                    len += 3
                    if after + 3 < ns.length && ns.character(at: after + 3) == 32 { len += 1 }
                }
            }
            return ListPrefix(ordered: false, task: task, markerLength: i + len)
        }
        var j = i
        while j < ns.length && ns.character(at: j) >= 48 && ns.character(at: j) <= 57 { j += 1 }
        if j > i, j < ns.length, ns.character(at: j) == 46, j + 1 < ns.length, ns.character(at: j + 1) == 32 {
            return ListPrefix(ordered: true, task: false, markerLength: j + 2)
        }
        return nil
    }

    static func parseList(ns: NSString, lines: [Line], start: Int, ordered: Bool, task: Bool) -> ([StyleSpan], Int) {
        var end = start
        while end < lines.count {
            let t = lines[end].text
            if t.trimmingCharacters(in: .whitespaces).isEmpty {
                if end + 1 < lines.count, parseListPrefix(lines[end + 1].text) != nil {
                    end += 1
                    continue
                }
                break
            }
            if parseListPrefix(t) != nil || t.hasPrefix("    ") || t.hasPrefix("\t") {
                end += 1
                continue
            }
            break
        }
        let block = Array(lines[start..<end])
        let group = union(block.first!.range, block.last!.range)
        var spans: [StyleSpan] = [StyleSpan(range: group, kind: .list(ordered: ordered, task: task), role: .content, group: group)]
        for line in block {
            if let prefix = parseListPrefix(line.text) {
                let marker = NSRange(location: line.range.location, length: prefix.markerLength)
                spans.append(StyleSpan(range: marker, kind: .list(ordered: prefix.ordered, task: prefix.task), role: .marker, group: group))
                let rest = NSRange(location: NSMaxRange(marker), length: max(0, NSMaxRange(line.range) - NSMaxRange(marker)))
                if rest.length > 0 {
                    spans.append(contentsOf: parseInline(ns, range: rest))
                }
            } else {
                spans.append(contentsOf: parseInline(ns, range: line.range))
            }
        }
        return (spans, end)
    }

    static func isTableSeparator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") || trimmed.contains("-") else { return false }
        let stripped = trimmed.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        return stripped.isEmpty && trimmed.contains("-")
    }

    static func parseTable(ns: NSString, lines: [Line], start: Int) -> ([StyleSpan], Int) {
        var end = start + 2
        while end < lines.count {
            let t = lines[end].text.trimmingCharacters(in: .whitespaces)
            if t.contains("|") { end += 1 } else { break }
        }
        let block = Array(lines[start..<end])
        let group = union(block.first!.range, block.last!.range)
        var spans: [StyleSpan] = [StyleSpan(range: group, kind: .table, role: .content, group: group)]
        for (idx, line) in block.enumerated() {
            let local = line.text as NSString
            for k in 0..<local.length {
                if local.character(at: k) == 124 {
                    spans.append(StyleSpan(
                        range: NSRange(location: line.range.location + k, length: 1),
                        kind: .table,
                        role: .marker,
                        group: group
                    ))
                }
            }
            if idx != 1 {
                let cells = splitTableCells(line.text)
                var cursor = line.range.location
                let raw = line.text as NSString
                for cell in cells {
                    if let found = raw.range(of: cell, options: [], range: NSRange(location: cursor - line.range.location, length: line.range.length - (cursor - line.range.location))).nilIfNotFound {
                        let r = NSRange(location: line.range.location + found.location, length: found.length)
                        spans.append(contentsOf: parseInline(ns, range: r))
                        cursor = NSMaxRange(r)
                    }
                }
            }
        }
        return (spans, end)
    }

    static func splitTableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
    }

    static func collectParagraph(lines: [Line], start: Int) -> (lines: [Line], next: Int) {
        var end = start + 1
        while end < lines.count {
            let t = lines[end].text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~") { break }
            if parseListPrefix(lines[end].text) != nil { break }
            if isThematicBreak(t) { break }
            end += 1
        }
        return (Array(lines[start..<end]), end)
    }

    // MARK: - Inline

    /// Inline spans only (bold, italic, strike, code, links, images) — for text that is not a block,
    /// such as a table cell, where "# x" or "- x" must not turn into a heading or list.
    public static func inlineSpans(in text: String) -> [StyleSpan] {
        let ns = text as NSString
        return parseInline(ns, range: NSRange(location: 0, length: ns.length))
    }

    static func parseInline(_ ns: NSString, range: NSRange) -> [StyleSpan] {
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return [] }
        // Covers only this range (indexed from `base`): sizing it to the whole document made
        // parsing O(paragraphs × document length).
        let base = range.location
        var occupied = Array(repeating: false, count: range.length)
        var spans: [StyleSpan] = []

        func isOccupied(_ i: Int) -> Bool {
            let k = i - base
            return k >= 0 && k < occupied.count && occupied[k]
        }
        func mark(_ r: NSRange) {
            let end = NSMaxRange(r)
            var i = r.location
            while i < end {
                let k = i - base
                if k >= 0 && k < occupied.count { occupied[k] = true }
                i += 1
            }
        }
        func free(_ r: NSRange) -> Bool {
            let end = NSMaxRange(r)
            var i = r.location
            while i < end {
                if isOccupied(i) { return false }
                i += 1
            }
            return true
        }

        var i = range.location
        let limit = NSMaxRange(range)

        // Images then links first so [`README.md`](./README.md) is a link wrapping inline code.
        while i < limit {
            let isImage = ns.character(at: i) == 33 && i + 1 < limit && ns.character(at: i + 1) == 91
            let isLink = ns.character(at: i) == 91
            if (isImage || isLink), i == range.location || ns.character(at: i - 1) != 92 {
                let openBracket = isImage ? i + 1 : i
                if let closeBracket = findClosing(ns, open: openBracket, from: openBracket + 1, limit: limit, openChar: 91, closeChar: 93),
                   closeBracket + 1 < limit,
                   ns.character(at: closeBracket + 1) == 40,
                   let closeParen = findClosing(ns, open: closeBracket + 1, from: closeBracket + 2, limit: limit, openChar: 40, closeChar: 41) {
                    let group = NSRange(location: i, length: NSMaxRange(NSRange(location: closeParen, length: 1)) - i)
                    if free(group) {
                        let urlRange = NSRange(location: closeBracket + 2, length: max(0, closeParen - (closeBracket + 2)))
                        let url = ns.substring(with: urlRange).trimmingCharacters(in: .whitespaces)
                        let kind: StyleKind = isImage ? .image(url: url) : .link(url: url)
                        let textStart = openBracket + 1
                        let textLen = closeBracket - textStart
                        spans.append(StyleSpan(range: NSRange(location: i, length: textStart - i), kind: kind, role: .marker, group: group))
                        if textLen > 0 {
                            spans.append(StyleSpan(range: NSRange(location: textStart, length: textLen), kind: kind, role: .content, group: group))
                        }
                        spans.append(StyleSpan(range: NSRange(location: closeBracket, length: NSMaxRange(group) - closeBracket), kind: kind, role: .marker, group: group))
                        mark(group)
                        if textLen > 0 && !isImage {
                            spans.append(contentsOf: parseInline(ns, range: NSRange(location: textStart, length: textLen)))
                        }
                    }
                    i = NSMaxRange(group)
                    continue
                }
            }
            i += 1
        }

        i = range.location
        while i < limit {
            if isOccupied(i) { i += 1; continue }
            if ns.character(at: i) == 96, (i == range.location || ns.character(at: i - 1) != 92) {
                var ticks = 1
                while i + ticks < limit && ns.character(at: i + ticks) == 96 { ticks += 1 }
                var j = i + ticks
                while j + ticks <= limit {
                    var k = 0
                    while k < ticks && ns.character(at: j + k) == 96 { k += 1 }
                    if k == ticks {
                        let group = NSRange(location: i, length: (j + ticks) - i)
                        if free(group) {
                            spans.append(StyleSpan(range: NSRange(location: i, length: ticks), kind: .inlineCode, role: .marker, group: group))
                            let inner = NSRange(location: i + ticks, length: j - (i + ticks))
                            if inner.length > 0 {
                                spans.append(StyleSpan(range: inner, kind: .inlineCode, role: .content, group: group))
                            }
                            spans.append(StyleSpan(range: NSRange(location: j, length: ticks), kind: .inlineCode, role: .marker, group: group))
                            mark(group)
                        }
                        i = j + ticks
                        break
                    }
                    j += 1
                }
                if j + ticks > limit { i += 1 }
            } else {
                i += 1
            }
        }

        // Inline math `$…$` (GitHub rules): no space just inside the dollars, no digit right after
        // the closing one — so prices like "$5 and $10" stay text.
        i = range.location
        while i < limit {
            if isOccupied(i) || ns.character(at: i) != 36 || (i > range.location && ns.character(at: i - 1) == 92) { i += 1; continue }
            let first = i + 1
            guard first < limit, ns.character(at: first) != 36, ns.character(at: first) != 32 else { i += 1; continue }
            var j = first
            var found = -1
            while j < limit {
                if isOccupied(j) { break }
                let ch = ns.character(at: j)
                if ch == 36, ns.character(at: j - 1) != 92, ns.character(at: j - 1) != 32,
                   !(j + 1 < limit && (48...57).contains(ns.character(at: j + 1))) {
                    found = j
                    break
                }
                j += 1
            }
            guard found > first else { i += 1; continue }
            let group = NSRange(location: i, length: found + 1 - i)
            spans.append(StyleSpan(range: NSRange(location: i, length: 1), kind: .inlineMath, role: .marker, group: group))
            spans.append(StyleSpan(range: NSRange(location: first, length: found - first), kind: .inlineMath, role: .content, group: group))
            spans.append(StyleSpan(range: NSRange(location: found, length: 1), kind: .inlineMath, role: .marker, group: group))
            mark(group)
            i = found + 1
        }

        func delimited(_ marker: String, kind: StyleKind) {
            let m = marker as NSString
            let mlen = m.length
            var p = range.location
            while p + mlen * 2 <= limit {
                if isOccupied(p) { p += 1; continue }
                if match(ns, at: p, marker: m), p == range.location || ns.character(at: p - 1) != 92 {
                    var q = p + mlen
                    while q + mlen <= limit {
                        if match(ns, at: q, marker: m), q == p + mlen || ns.character(at: q - 1) != 92 {
                            let group = NSRange(location: p, length: (q + mlen) - p)
                            // Only the delimiters must be free: links, images and inline code are
                            // contiguous groups, so any of them inside the content lies wholly inside
                            // (**[readme](README.md)**, **`Marka.dmg`**, *`Marka.dmg`*).
                            if free(NSRange(location: p, length: mlen)), free(NSRange(location: q, length: mlen)),
                               group.length > mlen * 2 {
                                spans.append(StyleSpan(range: NSRange(location: p, length: mlen), kind: kind, role: .marker, group: group))
                                spans.append(StyleSpan(range: NSRange(location: p + mlen, length: q - (p + mlen)), kind: kind, role: .content, group: group))
                                spans.append(StyleSpan(range: NSRange(location: q, length: mlen), kind: kind, role: .marker, group: group))
                                mark(NSRange(location: p, length: mlen))
                                mark(NSRange(location: q, length: mlen))
                                p = q + mlen
                                break
                            }
                        }
                        q += 1
                    }
                    if q + mlen > limit { p += 1 }
                } else {
                    p += 1
                }
            }
        }

        delimited("~~", kind: .strikethrough)
        delimited("**", kind: .strong)
        delimited("__", kind: .strong)
        delimited("*", kind: .emphasis)
        delimited("_", kind: .emphasis)

        return spans
    }

    static func match(_ ns: NSString, at index: Int, marker: NSString) -> Bool {
        let len = marker.length
        guard index + len <= ns.length else { return false }
        return ns.substring(with: NSRange(location: index, length: len)) == (marker as String)
    }

    static func findClosing(_ ns: NSString, open: Int, from: Int, limit: Int, openChar: unichar, closeChar: unichar) -> Int? {
        var depth = 1
        var i = from
        while i < limit {
            let ch = ns.character(at: i)
            if ch == 92 { i += 2; continue }
            if ch == openChar { depth += 1 }
            if ch == closeChar {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    static func union(_ a: NSRange, _ b: NSRange) -> NSRange {
        let loc = min(a.location, b.location)
        let end = max(NSMaxRange(a), NSMaxRange(b))
        return NSRange(location: loc, length: end - loc)
    }
}

/// Last parse only — `applyStyles`, the format toolbar, and heading rules all walk the same source.
private final class SpanMemo: @unchecked Sendable {
    static let shared = SpanMemo()
    private let lock = NSLock()
    private var source: String?
    private var spans: [StyleSpan] = []

    func spans(in source: String) -> [StyleSpan] {
        lock.lock()
        defer { lock.unlock() }
        if self.source == source { return spans }
        let parsed = MarkdownSyntax.parseSpans(in: source)
        self.source = source
        self.spans = parsed
        return parsed
    }
}

private extension NSRange {
    var nilIfNotFound: NSRange? {
        location == NSNotFound ? nil : self
    }
}
