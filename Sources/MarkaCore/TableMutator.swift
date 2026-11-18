import Foundation

public enum TableMutator {
    public struct Block: Equatable, Sendable {
        public var range: NSRange
        public var rows: [[String]]
        public var hasLeadingPipe: Bool
        public var hasTrailingPipe: Bool
    }

    public static func block(at location: Int, in source: String) -> Block? {
        let ns = source as NSString
        let lines = MarkdownSyntax.splitLines(ns)
        guard let idx = lines.firstIndex(where: { NSLocationInRange(location, $0.range) || location == NSMaxRange($0.range) }) else {
            return nil
        }
        var start = idx
        var end = idx
        func isTableLine(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.contains("|")
        }
        guard isTableLine(lines[idx].text) else { return nil }
        while start > 0, isTableLine(lines[start - 1].text) { start -= 1 }
        while end + 1 < lines.count, isTableLine(lines[end + 1].text) { end += 1 }
        let slice = Array(lines[start...end])
        guard slice.count >= 2 else { return nil }
        let group = MarkdownSyntax.union(slice.first!.range, slice.last!.range)
        let first = slice[0].text.trimmingCharacters(in: .whitespaces)
        let rows = slice.map { parseRow($0.text) }
        return Block(
            range: group,
            rows: rows,
            hasLeadingPipe: first.hasPrefix("|"),
            hasTrailingPipe: first.hasSuffix("|")
        )
    }

    public static func addRow(source: String, location: Int) -> EditResult? {
        guard var block = block(at: location, in: source) else { return nil }
        let cols = block.rows.first?.count ?? 1
        block.rows.append(Array(repeating: " ", count: cols))
        return replace(source: source, block: block, caretRow: block.rows.count - 1, caretCol: 0)
    }

    public static func addColumn(source: String, location: Int) -> EditResult? {
        guard var block = block(at: location, in: source) else { return nil }
        for i in block.rows.indices {
            if i == 1 {
                block.rows[i].append("---")
            } else if i == 0 {
                block.rows[i].append("Column")
            } else {
                block.rows[i].append(" ")
            }
        }
        return replace(source: source, block: block, caretRow: 0, caretCol: (block.rows.first?.count ?? 1) - 1)
    }

    public static func deleteRow(source: String, location: Int) -> EditResult? {
        guard var block = block(at: location, in: source), block.rows.count > 2 else { return nil }
        let ns = source as NSString
        let lines = MarkdownSyntax.splitLines(ns)
        guard let idx = lines.firstIndex(where: { NSLocationInRange(location, $0.range) }) else { return nil }
        var start = idx
        while start > 0, lines[start - 1].text.contains("|") { start -= 1 }
        let rowIndex = idx - start
        if rowIndex <= 1 { return nil }
        block.rows.remove(at: rowIndex)
        return replace(source: source, block: block, caretRow: min(rowIndex, block.rows.count - 1), caretCol: 0)
    }

    public static func deleteColumn(source: String, location: Int) -> EditResult? {
        guard var block = block(at: location, in: source) else { return nil }
        let cols = block.rows.first?.count ?? 0
        guard cols > 1 else { return nil }
        for i in block.rows.indices {
            if block.rows[i].count == cols {
                block.rows[i].removeLast()
            }
        }
        return replace(source: source, block: block, caretRow: 0, caretCol: 0)
    }

    static func replace(source: String, block: Block, caretRow: Int, caretCol: Int) -> EditResult {
        let rendered = render(block)
        let ns = source as NSString
        let new = ns.replacingCharacters(in: block.range, with: rendered)
        let caret = block.range.location + min((rendered as NSString).length, 1)
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }

    public static func render(_ block: Block) -> String {
        block.rows.map { row in
            let inner = row.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? " " : $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " | ")
            if block.hasLeadingPipe || block.hasTrailingPipe {
                return "| \(inner) |"
            }
            return inner
        }.joined(separator: "\n")
    }

    static func parseRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
