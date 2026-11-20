import Foundation

/// Editing lists, task lists and quotes the way word processors do: commands work on every
/// selected line, Return continues the block, Backspace at the start of an item undoes one step of
/// structure, and the caret never sits inside a hidden marker.
extension MarkdownEditing {
    public enum ListKind: Equatable, Sendable {
        case bullet, ordered, task
    }

    /// One source line split into its parts: `> ` quote prefix, indentation, list marker, text.
    struct LineParts {
        var quote: String        // "", "> ", ">> " …
        var indent: String       // spaces / tabs before the marker
        var marker: String       // "- ", "1. ", "- [ ] ", "" (not a list item)
        var text: String
        var kind: ListKind?

        init(_ line: String) {
            let quoteText = MarkdownEditing.quotePrefix(line)
            quote = quoteText
            let rest = String(line.dropFirst(quoteText.count))
            indent = String(rest.prefix { $0 == " " || $0 == "\t" })
            let afterIndent = String(rest.dropFirst(indent.count))
            if let prefix = MarkdownSyntax.parseListPrefix(afterIndent) {
                marker = String(afterIndent.prefix(prefix.markerLength))
                text = String(afterIndent.dropFirst(prefix.markerLength))
                kind = prefix.task ? .task : (prefix.ordered ? .ordered : .bullet)
            } else {
                marker = ""
                text = afterIndent
                kind = nil
            }
        }

        var line: String { quote + indent + marker + text }
    }

    /// The selected lines (whole lines; the caret's line when nothing is selected).
    static func selectedLines(_ ns: NSString, _ selected: NSRange) -> NSRange {
        let start = min(max(0, selected.location), ns.length)
        var end = min(ns.length, NSMaxRange(selected))
        // A selection ending at the start of a line does not include that line.
        if selected.length > 0, end > start, end <= ns.length, ns.character(at: end - 1) == 10 { end -= 1 }
        return ns.lineRange(for: NSRange(location: start, length: max(0, end - start)))
    }

    /// Replaces `range`'s lines with `lines`, keeping the caret on the same text when one line
    /// changed, or selecting the changed lines.
    static func replaceLines(_ ns: NSString, _ range: NSRange, old: [String], new: [String], selected: NSRange) -> EditResult {
        let hadNewline = ns.substring(with: range).hasSuffix("\n")
        let joined = new.joined(separator: "\n") + (hadNewline ? "\n" : "")
        let text = ns.replacingCharacters(in: range, with: joined)
        if old.count == 1, new.count == 1, selected.length == 0 {
            // Caret stays on the same character of the text: shift by the prefix change.
            let delta = (new[0] as NSString).length - (old[0] as NSString).length
            let offset = selected.location - range.location
            let oldPrefix = (old[0] as NSString).length - (LineParts(old[0]).text as NSString).length
            let newPrefix = (new[0] as NSString).length - (LineParts(new[0]).text as NSString).length
            let caret = offset >= oldPrefix ? selected.location + delta : range.location + newPrefix
            return EditResult(text: text, selected: NSRange(location: max(range.location, caret), length: 0))
        }
        return EditResult(text: text, selected: NSRange(location: range.location, length: (joined as NSString).length - (hadNewline ? 1 : 0)))
    }

    /// Bullets, numbers or tasks for every selected line; when they all already are that kind, the
    /// list is removed instead. Indentation and quotes are kept; numbers count 1, 2, 3 per level.
    public static func setList(source: String, selected: NSRange, kind: ListKind) -> EditResult {
        let ns = source as NSString
        let range = selectedLines(ns, selected)
        var lines = ns.substring(with: range).components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        let parts = lines.map(LineParts.init)
        let content = parts.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty || $0.kind != nil }
        let removing = !content.isEmpty && content.allSatisfy { $0.kind == kind }
        var counters: [String: Int] = [:]
        let new: [String] = parts.map { part in
            var part = part
            if removing {
                part.marker = ""
            } else if !(part.text.trimmingCharacters(in: .whitespaces).isEmpty && part.kind == nil) {
                switch kind {
                case .bullet: part.marker = "- "
                case .task:
                    // Keep a task's tick when it already is one.
                    part.marker = part.kind == .task ? part.marker : "- [ ] "
                case .ordered:
                    let key = part.quote + part.indent
                    let number = (counters[key] ?? 0) + 1
                    counters[key] = number
                    part.marker = "\(number). "
                }
            }
            return part.line
        }
        return replaceLines(ns, range, old: lines, new: new, selected: selected)
    }

    /// Quotes every selected line (`> `), or removes one quote level when all are quoted.
    public static func toggleQuote(source: String, selected: NSRange) -> EditResult {
        let ns = source as NSString
        let range = selectedLines(ns, selected)
        var lines = ns.substring(with: range).components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        let quoted = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy { $0.hasPrefix(">") }
            && lines.contains { $0.hasPrefix(">") }
        let new = lines.map { line -> String in
            if quoted {
                if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
                if line.hasPrefix(">") { return String(line.dropFirst()) }
                return line
            }
            return line.isEmpty ? ">" : "> " + line
        }
        return replaceLines(ns, range, old: lines, new: new, selected: selected)
    }

    /// Backspace with the caret right after a hidden marker: a nested item moves out one level,
    /// a list item becomes text, a quote line loses one `>`. nil: an ordinary backspace.
    public static func backspaceStructure(source: String, caret: Int) -> EditResult? {
        let ns = source as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, max(0, ns.length - 1)), length: 0))
        guard caret >= lineRange.location else { return nil }
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        let parts = LineParts(line)
        let contentStart = lineRange.location + ((parts.quote + parts.indent + parts.marker) as NSString).length
        guard caret == contentStart, !(parts.quote + parts.indent + parts.marker).isEmpty else { return nil }
        var updated = parts
        if parts.kind != nil, !parts.indent.isEmpty {
            // Nested: out one level (a tab or up to four spaces).
            if parts.indent.hasSuffix("\t") {
                updated.indent.removeLast()
            } else {
                let spaces = parts.indent.reversed().prefix { $0 == " " }.count
                updated.indent.removeLast(min(spaces, spaces >= 4 ? 4 : max(1, spaces)))
            }
        } else if parts.kind != nil {
            updated.marker = ""
        } else if !parts.quote.isEmpty {
            updated.quote = parts.quote.hasSuffix("> ") ? String(parts.quote.dropLast(2)) : String(parts.quote.dropLast())
        } else {
            return nil
        }
        let newLine = updated.line
        let text = ns.replacingCharacters(in: NSRange(location: lineRange.location, length: (line as NSString).length), with: newLine)
        let newCaret = lineRange.location + ((updated.quote + updated.indent + updated.marker) as NSString).length
        return EditResult(text: text, selected: NSRange(location: newCaret, length: 0))
    }
}

extension MarkdownSyntax {
    /// Hidden line prefixes in WYSIWYG — list markers (with their indentation) and quote markers —
    /// where the caret must not stop.
    public static func hiddenLinePrefixes(in source: String) -> [NSRange] {
        let ns = source as NSString
        var ranges: [NSRange] = listItems(in: source).map { NSRange(location: $0.line.location, length: NSMaxRange($0.marker) - $0.line.location) }
        let covered = Set(ranges.map(\.location))
        for quote in quotes(in: source) {
            var location = quote.group.location
            while location < NSMaxRange(quote.group) {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(line)
                guard !covered.contains(line.location) else { continue }
                let prefix = MarkdownEditing.quotePrefix(ns.substring(with: line))
                if !prefix.isEmpty { ranges.append(NSRange(location: line.location, length: (prefix as NSString).length)) }
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }
}
