import Foundation

public enum RowPlacement: Equatable, Sendable {
    case above
    case below
}

public enum ColumnPlacement: Equatable, Sendable {
    case left
    case right
}

public enum ColumnAlignment: Equatable, Sendable {
    case none, left, center, right
}

public enum TableMutator {
    public struct Block: Equatable, Sendable {
        public var range: NSRange
        public var rows: [[String]]
        public var lineRanges: [NSRange]
        public var hasLeadingPipe: Bool
        public var hasTrailingPipe: Bool

        public var columnCount: Int { rows.first?.count ?? 0 }
        public var dataRowCount: Int { max(0, rows.count - 2) }

        /// GFM column alignment from the delimiter row (`:--` left, `:-:` centre, `--:` right).
        public var alignments: [ColumnAlignment] {
            guard rows.count > 1 else { return Array(repeating: .none, count: columnCount) }
            return (0..<columnCount).map { c in
                let raw = c < rows[1].count ? rows[1][c].trimmingCharacters(in: .whitespaces) : ""
                let left = raw.hasPrefix(":"), right = raw.hasSuffix(":") && raw.count > 1
                switch (left, right) {
                case (true, true): return .center
                case (true, false): return .left
                case (false, true): return .right
                default: return .none
                }
            }
        }

        public func isSeparatorRow(_ index: Int) -> Bool { index == 1 }
        public func isHeaderRow(_ index: Int) -> Bool { index == 0 }
        public func isDataRow(_ index: Int) -> Bool { index >= 2 && index < rows.count }
    }

    public struct CellRef: Equatable, Sendable {
        public var block: Block
        public var row: Int
        public var column: Int

        public init(block: Block, row: Int, column: Int) {
            self.block = block
            self.row = row
            self.column = column
        }
    }

    public static func allBlocks(in source: String) -> [Block] {
        let ns = source as NSString
        let lines = MarkdownSyntax.splitLines(ns)
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            if let block = blockStarting(at: i, lines: lines) {
                blocks.append(block)
                i += block.rows.count
            } else {
                i += 1
            }
        }
        return blocks
    }

    public static func block(at location: Int, in source: String) -> Block? {
        cell(at: location, in: source)?.block ?? {
            let ns = source as NSString
            let lines = MarkdownSyntax.splitLines(ns)
            for (idx, line) in lines.enumerated() {
                if NSLocationInRange(location, line.range) || location == NSMaxRange(line.range) {
                    return blockContainingLine(idx, lines: lines)
                }
            }
            return nil
        }()
    }

    public static func cell(at location: Int, in source: String) -> CellRef? {
        let ns = source as NSString
        let lines = MarkdownSyntax.splitLines(ns)
        guard let lineIndex = lines.firstIndex(where: {
            NSLocationInRange(location, $0.range) || location == NSMaxRange($0.range)
        }) else { return nil }
        guard let block = blockContainingLine(lineIndex, lines: lines) else { return nil }
        let start = lines.firstIndex(where: { $0.range.location == block.lineRanges.first?.location }) ?? lineIndex
        let row = max(0, min(lineIndex - start, block.rows.count - 1))
        let line = lines[lineIndex]
        let offset = max(0, location - line.range.location)
        let prefix = (line.text as NSString).substring(to: min(offset, (line.text as NSString).length))
        var pipes = prefix.filter { $0 == "|" }.count
        if !block.hasLeadingPipe { pipes += 1 }
        let column = max(0, min(pipes - 1, max(0, block.columnCount - 1)))
        return CellRef(block: block, row: row, column: column)
    }

    public static func addRow(source: String, location: Int) -> EditResult? {
        insertRow(source: source, location: location, placement: .below)
    }

    public static func addColumn(source: String, location: Int) -> EditResult? {
        insertColumn(source: source, location: location, placement: .right)
    }

    public static func insertRow(source: String, location: Int, placement: RowPlacement) -> EditResult? {
        guard let cell = cell(at: location, in: source) else { return nil }
        return insertRow(source: source, cell: cell, placement: placement)
    }

    public static func insertRow(source: String, cell: CellRef, placement: RowPlacement) -> EditResult? {
        guard var block = block(at: cell.block.range.location, in: source) else { return nil }
        let cols = max(1, block.columnCount)
        let empty = Array(repeating: " ", count: cols)
        var index: Int
        if cell.row <= 1 {
            index = 2
        } else {
            index = placement == .above ? cell.row : cell.row + 1
        }
        index = min(max(2, index), block.rows.count)
        block.rows.insert(empty, at: index)
        return replace(source: source, block: block, focusRow: index, focusColumn: min(cell.column, cols - 1))
    }

    public static func insertColumn(source: String, location: Int, placement: ColumnPlacement) -> EditResult? {
        guard let cell = cell(at: location, in: source) else { return nil }
        return insertColumn(source: source, cell: cell, placement: placement)
    }

    public static func insertColumn(source: String, cell: CellRef, placement: ColumnPlacement) -> EditResult? {
        guard var block = block(at: cell.block.range.location, in: source) else { return nil }
        let insertAt = max(0, placement == .left ? cell.column : cell.column + 1)
        for i in block.rows.indices {
            let value: String
            if i == 1 { value = "---" }
            else if i == 0 { value = " " }
            else { value = " " }
            var row = padded(block.rows[i], to: max(insertAt, block.columnCount))
            row.insert(value, at: min(insertAt, row.count))
            block.rows[i] = row
        }
        return replace(source: source, block: block, focusRow: max(cell.row, 0), focusColumn: insertAt)
    }

    public static func deleteRow(source: String, location: Int) -> EditResult? {
        guard let cell = cell(at: location, in: source) else { return nil }
        return deleteRow(source: source, cell: cell)
    }

    public static func deleteRow(source: String, cell: CellRef) -> EditResult? {
        guard let block = block(at: cell.block.range.location, in: source) else { return nil }
        if cell.row <= 1 || block.dataRowCount <= 1 {
            return deleteTable(source: source, block: block)
        }
        var next = block
        next.rows.remove(at: cell.row)
        let focus = min(cell.row, next.rows.count - 1)
        return replace(source: source, block: next, focusRow: max(focus, 2), focusColumn: min(cell.column, max(0, next.columnCount - 1)))
    }

    /// Source range of a cell's text (trimmed) in the document; `row` is the storage row.
    public static func cellRange(in source: String, block: Block, row: Int, column: Int) -> NSRange? {
        guard row >= 0, row < block.lineRanges.count else { return nil }
        let ns = source as NSString
        let line = block.lineRanges[row]
        let text = ns.substring(with: line) as NSString
        // Cell boundaries: unescaped pipes, like `MarkdownSyntax.splitPipes`.
        var pipes: [Int] = []
        var i = 0
        while i < text.length {
            let ch = text.character(at: i)
            if ch == 92, i + 1 < text.length, text.character(at: i + 1) == 124 { i += 2; continue }
            if ch == 124 { pipes.append(i) }
            i += 1
        }
        let leading = text.substring(to: min(text.length, (pipes.first ?? text.length))).trimmingCharacters(in: .whitespaces).isEmpty && !pipes.isEmpty
        var bounds = (leading ? [] : [-1]) + pipes
        let trailing = text.substring(from: (pipes.last ?? 0) + 1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pipes.count > 1
        if !trailing { bounds.append(text.length) }
        guard column + 1 < bounds.count else { return nil }
        var start = bounds[column] + 1, end = bounds[column + 1]
        while start < end, text.character(at: start) == 32 || text.character(at: start) == 9 { start += 1 }
        while end > start, text.character(at: end - 1) == 32 || text.character(at: end - 1) == 9 { end -= 1 }
        return NSRange(location: line.location + start, length: end - start)
    }

    /// Sets a column's GFM alignment (the delimiter row: `---`, `:--`, `:-:`, `--:`).
    public static func setAlignment(source: String, cell: CellRef, alignment: ColumnAlignment) -> EditResult? {
        guard var block = block(at: cell.block.range.location, in: source), block.rows.count > 1,
              cell.column >= 0, cell.column < block.columnCount else { return nil }
        var separator = padded(block.rows[1], to: block.columnCount)
        switch alignment {
        case .none: separator[cell.column] = "---"
        case .left: separator[cell.column] = ":--"
        case .center: separator[cell.column] = ":-:"
        case .right: separator[cell.column] = "--:"
        }
        block.rows[1] = separator
        return replace(source: source, block: block, focusRow: cell.row, focusColumn: cell.column)
    }

    public static func deleteColumn(source: String, location: Int) -> EditResult? {
        guard let cell = cell(at: location, in: source) else { return nil }
        return deleteColumn(source: source, cell: cell)
    }

    public static func deleteColumn(source: String, cell: CellRef) -> EditResult? {
        guard let block = block(at: cell.block.range.location, in: source) else { return nil }
        if block.columnCount <= 1 {
            return deleteTable(source: source, block: block)
        }
        var next = block
        let col = min(cell.column, next.columnCount - 1)
        for i in next.rows.indices {
            if col < next.rows[i].count {
                next.rows[i].remove(at: col)
            }
        }
        let focusCol = min(col, max(0, next.columnCount - 1))
        return replace(source: source, block: next, focusRow: cell.row, focusColumn: focusCol)
    }

    public static func deleteTable(source: String, location: Int) -> EditResult? {
        guard let block = block(at: location, in: source) else { return nil }
        return deleteTable(source: source, block: block)
    }

    public static func deleteTable(source: String, cell: CellRef) -> EditResult? {
        deleteTable(source: source, block: cell.block)
    }

    public static func deleteTable(source: String, block: Block) -> EditResult? {
        let ns = source as NSString
        var range = block.range
        if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) == 10 {
            range.length += 1
        } else if range.location > 0, ns.character(at: range.location - 1) == 10 {
            range.location -= 1
            range.length += 1
        }
        let new = ns.replacingCharacters(in: range, with: "")
        let caret = min(range.location, (new as NSString).length)
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }

    /// Moves data row `from` so it ends up at storage index `to` (both ≥ 2; the header and the
    /// delimiter row never move). The caret follows the moved row.
    public static func moveRow(source: String, cell: CellRef, to target: Int) -> EditResult? {
        guard var block = block(at: cell.block.range.location, in: source) else { return nil }
        let from = cell.row
        guard from >= 2, from < block.rows.count else { return nil }
        let to = min(max(2, target), block.rows.count - 1)
        guard to != from else { return nil }
        let row = block.rows.remove(at: from)
        block.rows.insert(row, at: to)
        return replace(source: source, block: block, focusRow: to, focusColumn: cell.column)
    }

    /// Moves column `cell.column` so it ends up at index `to`, in every row (header, delimiter,
    /// alignment and data). The caret follows the moved column.
    public static func moveColumn(source: String, cell: CellRef, to target: Int) -> EditResult? {
        guard var block = block(at: cell.block.range.location, in: source) else { return nil }
        let cols = block.columnCount
        let from = cell.column
        guard from >= 0, from < cols else { return nil }
        let to = min(max(0, target), cols - 1)
        guard to != from else { return nil }
        for i in block.rows.indices {
            var row = padded(block.rows[i], to: cols)
            let value = row.remove(at: from)
            row.insert(value, at: to)
            block.rows[i] = row
        }
        return replace(source: source, block: block, focusRow: max(0, cell.row), focusColumn: to)
    }

    public static func setCell(source: String, location: Int, row: Int, column: Int, value: String) -> EditResult? {
        guard var block = block(at: location, in: source) else { return nil }
        guard row != 1, row >= 0, row < block.rows.count else { return nil }
        var line = padded(block.rows[row], to: block.columnCount)
        guard column >= 0, column < line.count else { return nil }
        line[column] = value.isEmpty ? " " : escapePipes(value)
        block.rows[row] = line
        return replace(source: source, block: block, focusRow: row, focusColumn: column)
    }

    public static func render(_ block: Block) -> String {
        let cols = block.columnCount
        var widths = Array(repeating: 3, count: cols)
        for (index, row) in block.rows.enumerated() {
            for c in 0..<cols {
                let raw = c < row.count ? row[c] : ""
                let value = index == 1 ? "---" : raw.trimmingCharacters(in: .whitespaces)
                widths[c] = max(widths[c], max(3, value.count))
            }
        }
        return block.rows.enumerated().map { index, row in
            let cells = (0..<cols).map { c -> String in
                let raw = c < row.count ? row[c].trimmingCharacters(in: .whitespaces) : ""
                if index == 1 {
                    // Keep GFM alignment (:--, :-:, --:) when the table is re-rendered.
                    let left = raw.hasPrefix(":"), right = raw.hasSuffix(":") && raw.count > 1
                    let dashes = max(1, widths[c] - (left ? 1 : 0) - (right ? 1 : 0))
                    return (left ? ":" : "") + String(repeating: "-", count: dashes) + (right ? ":" : "")
                }
                return raw.padding(toLength: widths[c], withPad: " ", startingAt: 0)
            }.joined(separator: " | ")
            return "| \(cells) |"
        }.joined(separator: "\n")
    }

    static func replace(source: String, block: Block, focusRow: Int, focusColumn: Int) -> EditResult {
        let rendered = render(block)
        let ns = source as NSString
        let new = ns.replacingCharacters(in: block.range, with: rendered)
        let caret = cellCaret(in: rendered, row: focusRow, column: focusColumn, base: block.range.location)
        return EditResult(text: new, selected: caret)
    }

    static func cellCaret(in rendered: String, row: Int, column: Int, base: Int) -> NSRange {
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
        guard row >= 0, row < lines.count else {
            return NSRange(location: base, length: 0)
        }
        var offset = base
        for i in 0..<row {
            offset += (String(lines[i]) as NSString).length + 1
        }
        let line = String(lines[row]) as NSString
        var pipes = 0
        var start = 0
        var i = 0
        while i < line.length {
            if line.character(at: i) == 124 {
                pipes += 1
                if pipes == column + 1 { start = i + 1 }
                if pipes == column + 2 {
                    var a = start
                    while a < i, line.character(at: a) == 32 { a += 1 }
                    var b = i
                    while b > a, line.character(at: b - 1) == 32 { b -= 1 }
                    return NSRange(location: offset + a, length: max(0, b - a))
                }
            }
            i += 1
        }
        return NSRange(location: offset, length: 0)
    }

    static func padded(_ row: [String], to count: Int) -> [String] {
        var row = row
        while row.count < count { row.append(" ") }
        return row
    }

    static func blockStarting(at index: Int, lines: [MarkdownSyntax.Line]) -> Block? {
        guard index + 1 < lines.count else { return nil }
        guard lines[index].text.contains("|"), MarkdownSyntax.isTableSeparator(lines[index + 1].text) else {
            return nil
        }
        return blockContainingLine(index, lines: lines)
    }

    static func blockContainingLine(_ index: Int, lines: [MarkdownSyntax.Line]) -> Block? {
        func isTableLine(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespaces).contains("|")
        }
        guard isTableLine(lines[index].text) else { return nil }
        var start = index
        var end = index
        while start > 0, isTableLine(lines[start - 1].text) { start -= 1 }
        while end + 1 < lines.count, isTableLine(lines[end + 1].text) { end += 1 }
        guard start + 1 <= end, MarkdownSyntax.isTableSeparator(lines[start + 1].text) else { return nil }
        let slice = Array(lines[start...end])
        let group = MarkdownSyntax.union(slice.first!.range, slice.last!.range)
        let first = slice[0].text.trimmingCharacters(in: .whitespaces)
        return Block(
            range: group,
            rows: slice.map { parseRow($0.text) },
            lineRanges: slice.map(\.range),
            hasLeadingPipe: first.hasPrefix("|"),
            hasTrailingPipe: first.hasSuffix("|")
        )
    }

    static func parseRow(_ line: String) -> [String] {
        MarkdownSyntax.splitPipes(line).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A cell value as stored: a typed `|` becomes `\|` so it does not split the cell.
    public static func escapePipes(_ value: String) -> String {
        var result = ""
        var previous: Character?
        for ch in value {
            if ch == "|", previous != "\\" { result += "\\|" } else { result.append(ch) }
            previous = ch
        }
        return result
    }
}
