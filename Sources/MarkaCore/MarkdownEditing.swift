import Foundation

public struct EditResult: Equatable, Sendable {
    public var text: String
    public var selected: NSRange

    public init(text: String, selected: NSRange) {
        self.text = text
        self.selected = selected
    }
}

public enum MarkdownEditing {
    public static func toggleWrap(source: String, selected: NSRange, left: String, right: String) -> EditResult {
        let ns = source as NSString
        let l = left as NSString
        let r = right as NSString
        let loc = selected.location
        let len = selected.length
        if loc >= l.length, loc + len + r.length <= ns.length {
            let before = ns.substring(with: NSRange(location: loc - l.length, length: l.length))
            let after = ns.substring(with: NSRange(location: loc + len, length: r.length))
            if before == left && after == right {
                let new = ns.replacingCharacters(in: NSRange(location: loc + len, length: r.length), with: "") as NSString
                let newer = new.replacingCharacters(in: NSRange(location: loc - l.length, length: l.length), with: "")
                return EditResult(text: newer, selected: NSRange(location: loc - l.length, length: len))
            }
        }
        if len > 0, loc + len <= ns.length {
            let inner = ns.substring(with: selected)
            if inner.hasPrefix(left), inner.hasSuffix(right), inner.count >= left.count + right.count {
                let start = inner.index(inner.startIndex, offsetBy: left.count)
                let end = inner.index(inner.endIndex, offsetBy: -right.count)
                let core = String(inner[start..<end])
                let new = ns.replacingCharacters(in: selected, with: core)
                return EditResult(text: new, selected: NSRange(location: loc, length: (core as NSString).length))
            }
        }
        let replacement = left + ns.substring(with: selected) + right
        let new = ns.replacingCharacters(in: selected, with: replacement)
        return EditResult(
            text: new,
            selected: NSRange(location: loc + l.length, length: len)
        )
    }

    public struct FormatState: Equatable, Sendable {
        public var headingLevel = 0
        public var bold = false
        public var italic = false
        public var strike = false
        public var inlineCode = false
        public var link = false
        public var quote = false
        public var unorderedList = false
        public var orderedList = false
        public var taskList = false
        public var inTable = false
        public var inCodeBlock = false
        public var codeBlockLanguage: String?
        public var inThematicBreak = false
        public var inPageBreak = false
    }

    public struct FormatAvailability: Equatable, Sendable {
        public var heading = true
        public var inline = true
        public var inlineCode = true
        public var link = true
        public var lists = true
        public var quote = true
        public var table = true
        public var image = true
        public var codeBlock = true
        public var rule = true
        public var pageBreak = true

        public static let none = FormatAvailability(
            heading: false,
            inline: false,
            inlineCode: false,
            link: false,
            lists: false,
            quote: false,
            table: false,
            image: false,
            codeBlock: false,
            rule: false,
            pageBreak: false
        )
    }

    public static func availability(for state: FormatState, sourceMode: Bool) -> FormatAvailability {
        if state.inCodeBlock || state.inPageBreak || state.inThematicBreak {
            return .none
        }
        var available = FormatAvailability()
        if state.inTable {
            if sourceMode {
                available.heading = false
                available.lists = false
                available.quote = false
                available.table = false
                available.image = false
                available.codeBlock = false
                available.rule = false
                available.pageBreak = false
                return available
            }
            return .none
        }
        if state.inlineCode {
            available.inline = false
            available.link = false
        }
        return available
    }

    public static func format(at selected: NSRange, in source: String) -> FormatState {
        var state = FormatState()
        let ns = source as NSString
        guard ns.length > 0 else { return state }
        let loc = min(max(0, selected.location), ns.length - 1)
        let probe = selected.length > 0 ? selected : NSRange(location: loc, length: 1)
        for span in MarkdownSyntax.spans(in: source) {
            let hit = NSIntersectionRange(probe, span.group).length > 0
                || NSLocationInRange(loc, span.group)
                || loc == span.group.location
            guard hit else { continue }
            switch span.kind {
            case .heading(let level):
                state.headingLevel = level
            case .strong:
                state.bold = true
            case .emphasis:
                state.italic = true
            case .strikethrough:
                state.strike = true
            case .inlineCode:
                state.inlineCode = true
            case .link:
                state.link = true
            case .blockquote:
                state.quote = true
            case .list(let ordered, let task):
                if task { state.taskList = true }
                else if ordered { state.orderedList = true }
                else { state.unorderedList = true }
            case .table:
                state.inTable = true
            case .codeBlock(let language):
                state.inCodeBlock = true
                state.codeBlockLanguage = language
            case .thematicBreak:
                state.inThematicBreak = true
            case .pageBreak:
                state.inPageBreak = true
            default:
                break
            }
        }
        return state
    }

    public static func toggleInline(
        source: String,
        selected: NSRange,
        left: String,
        right: String,
        kind: StyleKind
    ) -> EditResult {
        let ns = source as NSString
        let loc = min(max(0, selected.location), max(0, ns.length))
        let spans = MarkdownSyntax.spans(in: source)
        if let content = spans.first(where: {
            $0.kind == kind && $0.role == .content && (
                NSLocationInRange(loc, $0.group)
                    || (selected.length > 0 && NSIntersectionRange(selected, $0.group).length > 0)
                    || loc == $0.group.location
            )
        }) {
            let inner = ns.substring(with: content.range)
            let new = ns.replacingCharacters(in: content.group, with: inner)
            return EditResult(
                text: new,
                selected: NSRange(location: content.group.location, length: (inner as NSString).length)
            )
        }
        var range = selected
        if range.length == 0, let word = wordRange(at: loc, in: source) {
            range = word
        }
        return toggleWrap(source: source, selected: range, left: left, right: right)
    }

    public static func wordRange(at location: Int, in source: String) -> NSRange? {
        let ns = source as NSString
        guard ns.length > 0 else { return nil }
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var start = min(max(0, location), ns.length)
        var end = start
        while start > 0 {
            let ch = ns.character(at: start - 1)
            guard let scalar = UnicodeScalar(UInt32(ch)), letters.contains(scalar) else { break }
            start -= 1
        }
        while end < ns.length {
            let ch = ns.character(at: end)
            guard let scalar = UnicodeScalar(UInt32(ch)), letters.contains(scalar) else { break }
            end += 1
        }
        let length = end - start
        return length > 0 ? NSRange(location: start, length: length) : nil
    }

    public static func setHeading(source: String, selected: NSRange, level: Int) -> EditResult {
        let ns = source as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(selected.location, max(0, ns.length - 1)), length: 0))
        var line = ns.substring(with: lineRange)
        var hadNewline = false
        if line.hasSuffix("\n") {
            hadNewline = true
            line.removeLast()
        }
        var stripped = line
        while stripped.hasPrefix("#") {
            stripped.removeFirst()
        }
        if stripped.hasPrefix(" ") { stripped.removeFirst() }
        let hashes = max(0, min(6, level))
        let newLine: String
        if hashes == 0 {
            newLine = stripped + (hadNewline ? "\n" : "")
        } else {
            newLine = String(repeating: "#", count: hashes) + " " + stripped + (hadNewline ? "\n" : "")
        }
        let new = ns.replacingCharacters(in: lineRange, with: newLine)
        let caret = lineRange.location + (newLine as NSString).length - (hadNewline ? 1 : 0)
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }

    public static func isATXHeadingLine(_ line: String, maxLevel: Int = 6) -> Bool {
        var stripped = line
        if stripped.hasSuffix("\n") { stripped.removeLast() }
        var i = stripped.startIndex
        while i < stripped.endIndex, stripped[i] == " " { i = stripped.index(after: i) }
        var hashes = 0
        while i < stripped.endIndex, stripped[i] == "#", hashes < 6 {
            hashes += 1
            i = stripped.index(after: i)
        }
        guard hashes >= 1, hashes <= maxLevel else { return false }
        if i == stripped.endIndex { return true }
        return stripped[i] == " " || stripped[i] == "\t"
    }

    public static func isSetextUnderline(_ line: String) -> Bool {
        var stripped = line
        if stripped.hasSuffix("\n") { stripped.removeLast() }
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        return trimmed.allSatisfy { $0 == "=" || $0 == "-" }
    }

    /// Caret on a setext underline or the blank line under an h1/h2 must not sit on the GitHub rule.
    public static func snapOutOfHeadingRule(source: String, selected: NSRange) -> NSRange? {
        let ns = source as NSString
        guard ns.length > 0 else { return nil }
        let loc = min(max(0, selected.location), ns.length)
        let probe = min(loc, ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if isSetextUnderline(line), lineRange.location > 0 {
            let prev = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            var prevText = ns.substring(with: prev)
            if prevText.hasSuffix("\n") { prevText.removeLast() }
            let caret = prev.location + (prevText as NSString).length
            return NSRange(location: caret, length: 0)
        }

        if trimmed.isEmpty, lineRange.location > 0 {
            let prev = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            var prevText = ns.substring(with: prev)
            if prevText.hasSuffix("\n") { prevText.removeLast() }
            if isATXHeadingLine(prevText, maxLevel: 2) || isSetextUnderline(prevText) {
                return NSRange(location: NSMaxRange(lineRange), length: 0)
            }
        }
        return nil
    }

    public static func toggleList(source: String, selected: NSRange, ordered: Bool, task: Bool) -> EditResult {
        let ns = source as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(selected.location, max(0, ns.length - 1)), length: 0))
        var line = ns.substring(with: lineRange)
        var hadNewline = false
        if line.hasSuffix("\n") {
            hadNewline = true
            line.removeLast()
        }
        let marker = task ? "- [ ] " : (ordered ? "1. " : "- ")
        let newLine: String
        if let prefix = listPrefixLength(line), prefix > 0 {
            let rest = (line as NSString).substring(from: prefix)
            if line.hasPrefix(marker) {
                newLine = rest + (hadNewline ? "\n" : "")
            } else {
                newLine = marker + rest + (hadNewline ? "\n" : "")
            }
        } else {
            newLine = marker + line + (hadNewline ? "\n" : "")
        }
        let new = ns.replacingCharacters(in: lineRange, with: newLine)
        let caret = lineRange.location + (newLine as NSString).length - (hadNewline ? 1 : 0)
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }

    public struct LinkRef: Equatable, Sendable {
        public var group: NSRange
        public var textRange: NSRange
        public var urlRange: NSRange
        public var text: String
        public var url: String
    }

    public static func insertLink(source: String, selected: NSRange, url: String) -> EditResult {
        let ns = source as NSString
        let text = selected.length > 0 ? ns.substring(with: selected) : "link"
        let replacement = "[\(text)](\(url))"
        let new = ns.replacingCharacters(in: selected, with: replacement)
        return EditResult(text: new, selected: NSRange(location: selected.location + 1, length: (text as NSString).length))
    }

    public static func link(at location: Int, in source: String) -> LinkRef? {
        for span in MarkdownSyntax.spans(in: source) {
            guard case .link = span.kind else { continue }
            let inGroup = NSLocationInRange(location, span.group) || location == NSMaxRange(span.group)
            guard inGroup else { continue }
            return parseLink(group: span.group, source: source)
        }
        return nil
    }

    public static func setLinkURL(source: String, location: Int, url: String) -> EditResult? {
        guard let link = link(at: location, in: source) else { return nil }
        if link.url == url { return nil }
        let ns = source as NSString
        let new = ns.replacingCharacters(in: link.urlRange, with: url)
        let caret = link.textRange.location
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }

    public static func removeLink(source: String, location: Int) -> EditResult? {
        guard let link = link(at: location, in: source) else { return nil }
        let ns = source as NSString
        let new = ns.replacingCharacters(in: link.group, with: link.text)
        return EditResult(text: new, selected: NSRange(location: link.group.location, length: (link.text as NSString).length))
    }

    static func parseLink(group: NSRange, source: String) -> LinkRef? {
        let ns = source as NSString
        guard NSMaxRange(group) <= ns.length else { return nil }
        let raw = ns.substring(with: group) as NSString
        let split = raw.range(of: "](")
        guard split.location != NSNotFound, raw.length >= split.location + 3, raw.hasSuffix(")") else { return nil }
        let textLoc = group.location + 1
        let textLen = max(0, split.location - 1)
        let urlLoc = group.location + split.location + 2
        let urlLen = max(0, raw.length - (split.location + 2) - 1)
        let textRange = NSRange(location: textLoc, length: textLen)
        let urlRange = NSRange(location: urlLoc, length: urlLen)
        return LinkRef(
            group: group,
            textRange: textRange,
            urlRange: urlRange,
            text: ns.substring(with: textRange),
            url: ns.substring(with: urlRange)
        )
    }

    public static func insertImage(source: String, selected: NSRange, path: String, alt: String) -> EditResult {
        let ns = source as NSString
        let replacement = "![\(alt)](\(path))"
        let new = ns.replacingCharacters(in: selected, with: replacement)
        let caret = selected.location + (replacement as NSString).length
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }

    /// Pages-style table: `visualRows` includes the header. Cells start empty.
    public static func insertTable(source: String, selected: NSRange, rows: Int = 2, columns: Int = 3) -> EditResult {
        let ns = source as NSString
        let cols = max(1, columns)
        let visualRows = max(1, rows)
        let bodyRows = max(1, visualRows - 1)
        let empty = (0..<cols).map { _ in " " }.joined(separator: " | ")
        let sep = (0..<cols).map { _ in "---" }.joined(separator: " | ")
        var lines = ["| \(empty) |", "| \(sep) |"]
        for _ in 0..<bodyRows {
            lines.append("| \(empty) |")
        }
        var block = lines.joined(separator: "\n")
        let replace: NSRange
        if selected.length > 0 {
            replace = selected
            block += "\n"
        } else {
            let at = min(max(0, selected.location), ns.length)
            let needLeading = at > 0 && ns.character(at: at - 1) != 10
            let needTrailing = at < ns.length && ns.character(at: at) != 10
            block = (needLeading ? "\n" : "") + block + (needTrailing ? "\n" : "")
            replace = NSRange(location: at, length: 0)
        }
        let new = ns.replacingCharacters(in: replace, with: block)
        let caretInNew = replace.location + (block.hasPrefix("\n") ? 3 : 2)
        return EditResult(text: new, selected: NSRange(location: min(caretInNew, (new as NSString).length), length: 0))
    }

    public static func insertCodeBlock(source: String, selected: NSRange, language: String = "") -> EditResult {
        let ns = source as NSString
        let inner = selected.length > 0 ? ns.substring(with: selected) : ""
        let open = "```\(language)\n"
        let close = "\n```"
        var block = open + inner + close
        let replace: NSRange
        var prefix = 0
        if selected.length > 0 {
            replace = selected
        } else {
            let at = min(max(0, selected.location), ns.length)
            let needLeading = at > 0 && ns.character(at: at - 1) != 10
            let needTrailing = at < ns.length && ns.character(at: at) != 10
            prefix = needLeading ? 1 : 0
            block = (needLeading ? "\n" : "") + block + (needTrailing ? "\n" : "")
            replace = NSRange(location: at, length: 0)
        }
        let new = ns.replacingCharacters(in: replace, with: block)
        let caret = replace.location + prefix + (open as NSString).length
        return EditResult(text: new, selected: NSRange(location: caret, length: (inner as NSString).length))
    }

    /// Retarget the opening fence language when the caret is already inside a fenced block.
    public static func setCodeBlockLanguage(source: String, selected: NSRange, language: String) -> EditResult? {
        let ns = source as NSString
        guard ns.length > 0 else { return nil }
        let loc = min(max(0, selected.location), ns.length - 1)
        let spans = MarkdownSyntax.spans(in: source)
        guard let marker = spans.first(where: {
            if case .codeBlock = $0.kind, $0.role == .marker, $0.range.location == $0.group.location {
                return NSLocationInRange(loc, $0.group) || loc == $0.group.location
            }
            return false
        }) else { return nil }
        let line = ns.substring(with: marker.range)
        var fenceLen = 0
        for ch in line {
            if ch == "`" || ch == "~" { fenceLen += 1 } else { break }
        }
        guard fenceLen >= 3 else { return nil }
        let fence = String(line.prefix(fenceLen))
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let replacement = "\(indent)\(fence)\(language)"
        let new = ns.replacingCharacters(in: marker.range, with: replacement)
        let delta = (replacement as NSString).length - marker.range.length
        var caret = selected.location
        if selected.location >= NSMaxRange(marker.range) {
            caret += delta
        }
        caret = min(max(0, caret), (new as NSString).length)
        return EditResult(text: new, selected: NSRange(location: caret, length: selected.length))
    }

    public static func insertHorizontalRule(source: String, selected: NSRange) -> EditResult {
        let ns = source as NSString
        let insertion = "\n\n---\n\n"
        let at = NSMaxRange(selected)
        let new = ns.replacingCharacters(in: NSRange(location: at, length: 0), with: insertion)
        return EditResult(text: new, selected: NSRange(location: at + (insertion as NSString).length, length: 0))
    }

    public static func insertPageBreak(source: String, selected: NSRange) -> EditResult {
        let ns = source as NSString
        let insertion = "\n\n\(PageBreakMarker.comment)\n\n"
        let at = NSMaxRange(selected)
        let new = ns.replacingCharacters(in: NSRange(location: at, length: 0), with: insertion)
        return EditResult(text: new, selected: NSRange(location: at + (insertion as NSString).length, length: 0))
    }

    public static func handleReturn(currentLine: String) -> ReturnAction {
        let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
        if PageBreakMarker.isPageBreakLine(currentLine) {
            return .insert("\n")
        }
        if let prefix = listPrefix(currentLine) {
            let rest = (currentLine as NSString).substring(from: prefix.length)
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return .replaceLine("")
            }
            if prefix.ordered, let n = prefix.number {
                return .insert("\n\(n + 1). ")
            }
            return .insert("\n\(prefix.literal)")
        }
        let quote = quotePrefix(currentLine)
        if !quote.isEmpty {
            if trimmed == ">" || trimmed == "> " {
                return .replaceLine("")
            }
            return .insert("\n\(quote)")
        }
        return .insert("\n")
    }

    public static func indentListLine(_ line: String, indent: Bool) -> String {
        if indent {
            if line.hasPrefix("    ") || parseableList(line) {
                return "    " + line
            }
            return "    " + line
        }
        if line.hasPrefix("    ") {
            return String(line.dropFirst(4))
        }
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        if line.hasPrefix("  ") {
            return String(line.dropFirst(2))
        }
        return line
    }

    public struct ListLinePrefix: Equatable, Sendable {
        public var length: Int
        public var ordered: Bool
        public var number: Int?
        public var literal: String
    }

    public enum ReturnAction: Equatable, Sendable {
        case insert(String)
        case replaceLine(String)
    }

    public static func listPrefix(_ line: String) -> ListLinePrefix? {
        guard let length = listPrefixLength(line), length > 0 else { return nil }
        let literal = (line as NSString).substring(to: length)
        let trimmed = literal.trimmingCharacters(in: .whitespaces)
        var ordered = false
        var number: Int?
        if let dot = trimmed.firstIndex(of: "."), let n = Int(trimmed[trimmed.startIndex..<dot]) {
            ordered = true
            number = n
        }
        return ListLinePrefix(length: length, ordered: ordered, number: number, literal: literal)
    }

    static func quotePrefix(_ line: String) -> String {
        let ns = line as NSString
        var i = 0
        var out = ""
        while i < ns.length && ns.character(at: i) == 62 {
            out.append(">")
            i += 1
            if i < ns.length && ns.character(at: i) == 32 {
                out.append(" ")
                i += 1
            }
        }
        return out
    }

    static func listPrefixLength(_ line: String) -> Int? {
        MarkdownSyntax.parseListPrefix(line)?.markerLength
    }

    static func parseableList(_ line: String) -> Bool {
        MarkdownSyntax.parseListPrefix(line) != nil
    }
}
