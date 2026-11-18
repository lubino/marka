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
        let prefix = (1...max(0, min(6, level))).map { _ in "#" }.joined()
        let newLine: String
        if level <= 0 {
            newLine = stripped + (hadNewline ? "\n" : "")
        } else {
            newLine = prefix + " " + stripped + (hadNewline ? "\n" : "")
        }
        let new = ns.replacingCharacters(in: lineRange, with: newLine)
        let caret = lineRange.location + (newLine as NSString).length - (hadNewline ? 1 : 0)
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
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

    public static func insertLink(source: String, selected: NSRange, url: String) -> EditResult {
        let ns = source as NSString
        let text = selected.length > 0 ? ns.substring(with: selected) : "link"
        let replacement = "[\(text)](\(url))"
        let new = ns.replacingCharacters(in: selected, with: replacement)
        return EditResult(text: new, selected: NSRange(location: selected.location + 1, length: (text as NSString).length))
    }

    public static func insertImage(source: String, selected: NSRange, path: String, alt: String) -> EditResult {
        let ns = source as NSString
        let replacement = "![\(alt)](\(path))"
        let new = ns.replacingCharacters(in: selected, with: replacement)
        let caret = selected.location + (replacement as NSString).length
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }

    public static func insertTable(source: String, selected: NSRange, rows: Int = 2, columns: Int = 2) -> EditResult {
        let ns = source as NSString
        var lines: [String] = []
        let header = (0..<columns).map { "Column \($0 + 1)" }.joined(separator: " | ")
        let sep = (0..<columns).map { _ in "---" }.joined(separator: " | ")
        lines.append("| \(header) |")
        lines.append("| \(sep) |")
        for _ in 0..<max(1, rows) {
            let cells = (0..<columns).map { _ in " " }.joined(separator: " | ")
            lines.append("| \(cells) |")
        }
        let block = "\n" + lines.joined(separator: "\n") + "\n"
        let insertAt = NSMaxRange(selected)
        let new = ns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: block)
        return EditResult(text: new, selected: NSRange(location: insertAt + 2, length: 0))
    }

    public static func insertCodeBlock(source: String, selected: NSRange, language: String = "") -> EditResult {
        let ns = source as NSString
        let inner = selected.length > 0 ? ns.substring(with: selected) : ""
        let replacement = "```\(language)\n\(inner)\n```"
        let new = ns.replacingCharacters(in: selected, with: replacement)
        let caret = selected.location + 3 + (language as NSString).length + 1
        return EditResult(text: new, selected: NSRange(location: caret, length: (inner as NSString).length))
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
