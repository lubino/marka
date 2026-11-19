import AppKit
import MarkaCore

@MainActor
protocol PagesTableDelegate: AnyObject {
    func pagesTable(_ view: PagesTableView, commit row: Int, column: Int, text: String)
    func pagesTable(_ view: PagesTableView, insertRow placement: RowPlacement)
    func pagesTable(_ view: PagesTableView, insertColumn placement: ColumnPlacement)
    func pagesTableDeleteRow(_ view: PagesTableView)
    func pagesTableDeleteColumn(_ view: PagesTableView)
    func pagesTableDeleteTable(_ view: PagesTableView)
    func pagesTableDidChangeFocus(_ view: PagesTableView)
}

/// Pages-style Markdown table: native grid, row/column headers, one slice per page.
final class PagesTableView: NSView, NSTextFieldDelegate {
    enum Axis { case cell, row, column, table }

    weak var tableDelegate: PagesTableDelegate?
    private(set) var block: TableMutator.Block
    private(set) var selectedRow = 0
    private(set) var selectedColumn = 0
    private(set) var axis: Axis = .cell
    var darkPaper = false

    static let rowHeight: CGFloat = 28
    static let headerBar: CGFloat = 18
    static let rowBar: CGFloat = 22
    static let insertSize: CGFloat = 16
    static let cellPadX: CGFloat = 10
    static let minColumn: CGFloat = 64
    static let topPad: CGFloat = headerBar
    static let bottomPad: CGFloat = 18
    static let edgeInset: CGFloat = topPad

    private var flow: PageLayout.TableFlow?
    private var slices: [TableSliceView] = []
    private var columnWidths: [CGFloat] = []
    private let addRowButton = PagesInsertButton()
    private let addColumnButton = PagesInsertButton()
    private let deleteButton = PagesInsertButton(kind: .remove)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static func storageRows(for block: TableMutator.Block) -> [Int] {
        var rows = [0]
        if block.rows.count > 2 {
            rows.append(contentsOf: 2..<block.rows.count)
        }
        return rows
    }

    var storageRowsForFlow: [Int] { Self.storageRows(for: block) }
    var leftHandlePadding: CGFloat { Self.rowBar }
    var tableBodyOriginY: CGFloat { Self.headerBar }
    var bottomHandlePadding: CGFloat { Self.bottomPad }

    init(block: TableMutator.Block, darkPaper: Bool) {
        self.block = block
        self.darkPaper = darkPaper
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
        addRowButton.toolTip = "Add row"
        addRowButton.target = self
        addRowButton.action = #selector(rowBelow)
        addColumnButton.toolTip = "Add column"
        addColumnButton.target = self
        addColumnButton.action = #selector(colRight)
        deleteButton.kind = .remove
        deleteButton.toolTip = "Delete"
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelection)
        addSubview(addRowButton)
        addSubview(addColumnButton)
        addSubview(deleteButton)
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(block: TableMutator.Block, darkPaper: Bool, focus: (Int, Int)?) {
        let unchanged = self.block == block && self.darkPaper == darkPaper
        self.block = block
        self.darkPaper = darkPaper
        if !unchanged {
            rebuild()
        }
        if let focus {
            focusCell(row: focus.0, column: focus.1, stealFocus: !unchanged)
        } else {
            needsDisplay = true
        }
    }

    func applyFlow(_ flow: PageLayout.TableFlow) {
        self.flow = flow
        rebuildSlices()
        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    var paginationHeight: CGFloat {
        guard let flow else {
            return Self.headerBar + CGFloat(visibleRowCount) * Self.rowHeight + Self.bottomPad
        }
        return max(Self.rowHeight, flow.endY - flow.startY)
    }

    var paginationSpacing: CGFloat { flow?.contentHeight ?? paginationHeight }

    func preferredSize(fitting width: CGFloat) -> CGSize {
        measureColumns(maxWidth: max(40, width - Self.rowBar))
        return CGSize(width: width, height: paginationHeight)
    }

    private var visibleRowCount: Int { max(1, block.rows.count - 1) }

    private func storageRow(forDisplay display: Int) -> Int {
        display == 0 ? 0 : display + 1
    }

    private func rebuild() {
        slices.forEach { $0.removeFromSuperview() }
        slices = []
        rebuildSlices()
        needsLayout = true
        needsDisplay = true
    }

    private func rebuildSlices() {
        let pageSlices: [PageLayout.TablePageSlice]
        if let flow {
            pageSlices = PageLayout.tablePageSlices(
                flow: flow,
                rowHeight: Self.rowHeight,
                topPad: Self.topPad,
                bottomPad: Self.bottomPad
            )
        } else {
            let rows = (0..<visibleRowCount).map { display in
                PageLayout.TableFlow.Row(
                    storageRow: storageRow(forDisplay: display),
                    y: Self.headerBar + CGFloat(display) * Self.rowHeight,
                    page: 0,
                    isRepeatedHeader: false
                )
            }
            let height = Self.headerBar + CGFloat(visibleRowCount) * Self.rowHeight + Self.bottomPad
            pageSlices = [PageLayout.TablePageSlice(page: 0, rows: rows, y: 0, height: height)]
        }
        while slices.count > pageSlices.count {
            slices.removeLast().removeFromSuperview()
        }
        while slices.count < pageSlices.count {
            let slice = TableSliceView(parent: self)
            addSubview(slice, positioned: .below, relativeTo: addRowButton)
            slices.append(slice)
        }
        let startY = flow?.startY ?? 0
        for (index, spec) in pageSlices.enumerated() {
            let slice = slices[index]
            slice.configure(spec: spec, startY: startY, block: block, darkPaper: darkPaper)
        }
    }

    private func measureColumns(maxWidth: CGFloat) {
        let cols = max(1, block.columnCount)
        var widths = Array(repeating: Self.minColumn, count: cols)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for row in block.rows.enumerated() where row.offset != 1 {
            for (c, cell) in row.element.enumerated() where c < cols {
                let text = cell.trimmingCharacters(in: .whitespaces) as NSString
                let w = text.size(withAttributes: [.font: font]).width + Self.cellPadX * 2
                widths[c] = max(widths[c], min(w, maxWidth * 0.55))
            }
        }
        let total = widths.reduce(0, +)
        if total < maxWidth {
            let extra = (maxWidth - total) / CGFloat(cols)
            widths = widths.map { $0 + extra }
        } else if total > maxWidth {
            let scale = maxWidth / total
            widths = widths.map { $0 * scale }
        }
        columnWidths = widths
    }

    func containsResponder(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }

    override func layout() {
        super.layout()
        let tableW = max(40, bounds.width - Self.rowBar)
        measureColumns(maxWidth: tableW)
        let startY = flow?.startY ?? 0
        for slice in slices {
            slice.columnWidths = columnWidths
            slice.frame = CGRect(
                x: 0,
                y: slice.spec.y - startY,
                width: bounds.width,
                height: slice.spec.height
            )
            slice.rebuildFieldsIfNeeded()
            slice.layoutFields()
        }
        layoutChrome()
    }

    private func layoutChrome() {
        let rail = Self.insertSize
        let last = slices.last
        let first = slices.first
        addColumnButton.darkPaper = darkPaper
        addRowButton.darkPaper = darkPaper
        deleteButton.darkPaper = darkPaper
        if let first {
            addColumnButton.frame = CGRect(
                x: bounds.width - rail - 2,
                y: first.frame.minY + max(1, (Self.headerBar - rail) / 2),
                width: rail,
                height: rail
            )
        }
        if let last {
            addRowButton.frame = CGRect(
                x: max(2, (Self.rowBar - rail) / 2),
                y: last.frame.maxY - Self.bottomPad + max(1, (Self.bottomPad - rail) / 2),
                width: rail,
                height: rail
            )
        }
        positionDeleteButton(rail: rail)
        addSubview(addRowButton, positioned: .above, relativeTo: nil)
        addSubview(addColumnButton, positioned: .above, relativeTo: nil)
        addSubview(deleteButton, positioned: .above, relativeTo: nil)
    }

    private func positionDeleteButton(rail: CGFloat) {
        switch axis {
        case .row:
            guard let y = primaryY(for: selectedRow) else {
                deleteButton.isHidden = true
                return
            }
            deleteButton.toolTip = (selectedRow <= 1 || block.dataRowCount <= 1) ? "Delete table" : "Delete row"
            deleteButton.frame = CGRect(
                x: max(2, (Self.rowBar - rail) / 2),
                y: y + max(1, (Self.rowHeight - rail) / 2),
                width: rail,
                height: rail
            )
            deleteButton.isHidden = false
        case .column:
            var x = Self.rowBar
            for i in 0..<selectedColumn where i < columnWidths.count {
                x += columnWidths[i]
            }
            let w = selectedColumn < columnWidths.count ? columnWidths[selectedColumn] : Self.minColumn
            let selectedY = primaryY(for: selectedRow)
            let barY = slices.first(where: { slice in
                guard let selectedY else { return false }
                return selectedY >= slice.frame.minY && selectedY <= slice.frame.maxY
            })?.frame.minY ?? slices.first?.frame.minY ?? 0
            deleteButton.toolTip = block.columnCount <= 1 ? "Delete table" : "Delete column"
            deleteButton.frame = CGRect(
                x: x + max(1, (w - rail) / 2),
                y: barY + max(1, (Self.headerBar - rail) / 2),
                width: rail,
                height: rail
            )
            deleteButton.isHidden = false
        case .table:
            deleteButton.toolTip = "Delete table"
            deleteButton.frame = CGRect(x: 2, y: (slices.first?.frame.minY ?? 0) + 1, width: rail, height: rail)
            deleteButton.isHidden = false
        case .cell:
            deleteButton.isHidden = true
        }
    }

    private func primaryY(for storageRow: Int) -> CGFloat? {
        for slice in slices {
            if let row = slice.spec.rows.first(where: { $0.storageRow == storageRow && !$0.isRepeatedHeader })
                ?? slice.spec.rows.first(where: { $0.storageRow == storageRow }) {
                return slice.frame.minY + (row.y - slice.spec.y)
            }
        }
        return nil
    }

    func chromeRects() -> [CGRect] {
        slices.map(\.frame)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for handle in [deleteButton, addRowButton, addColumnButton] where !handle.isHidden {
            if handle.frame.contains(local) { return handle }
        }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let slice = slices.first(where: { $0.frame.contains(local) }) {
            let inSlice = CGPoint(x: local.x, y: local.y - slice.frame.minY)
            if inSlice.y < Self.headerBar, inSlice.x >= Self.rowBar, let column = columnIndex(atX: inSlice.x) {
                selectColumn(column)
                window?.makeFirstResponder(self)
                return
            }
            if inSlice.x < Self.rowBar, let row = slice.storageRow(atY: inSlice.y) {
                selectRow(row)
                window?.makeFirstResponder(self)
                return
            }
            if inSlice.x < Self.rowBar, inSlice.y < Self.headerBar {
                selectTable()
                window?.makeFirstResponder(self)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]
        if deleteKeys.contains(event.keyCode), axis != .cell {
            deleteSelection()
            return
        }
        super.keyDown(with: event)
    }

    private func columnIndex(atX x: CGFloat) -> Int? {
        guard x >= Self.rowBar else { return nil }
        var cursor = Self.rowBar
        for (index, width) in columnWidths.enumerated() {
            if x <= cursor + width { return index }
            cursor += width
        }
        return columnWidths.isEmpty ? 0 : columnWidths.count - 1
    }

    func selectRow(_ row: Int) {
        axis = .row
        selectedRow = row == 1 ? 0 : row
        needsLayout = true
        needsDisplay = true
        slices.forEach { $0.needsDisplay = true }
        tableDelegate?.pagesTableDidChangeFocus(self)
    }

    func selectColumn(_ column: Int) {
        axis = .column
        selectedColumn = max(0, column)
        needsLayout = true
        needsDisplay = true
        slices.forEach { $0.needsDisplay = true }
        tableDelegate?.pagesTableDidChangeFocus(self)
    }

    func selectTable() {
        axis = .table
        needsLayout = true
        needsDisplay = true
        tableDelegate?.pagesTableDidChangeFocus(self)
    }

    func focusCell(row: Int, column: Int, stealFocus: Bool = true) {
        axis = .cell
        selectedRow = row
        selectedColumn = column
        if stealFocus {
            for slice in slices {
                if slice.focusField(row: row, column: column) { break }
            }
        }
        needsLayout = true
        needsDisplay = true
        slices.forEach { $0.needsDisplay = true }
    }

    func addColumnChipHitTest(in canvas: NSView) -> Bool {
        let point = addColumnButton.convert(
            NSPoint(x: addColumnButton.bounds.midX, y: addColumnButton.bounds.midY),
            to: canvas
        )
        return canvas.hitTest(point) === addColumnButton
    }

    func pagesChromeIsNative() -> Bool {
        guard let first = slices.first, let last = slices.last else { return false }
        let colOnHeader = addColumnButton.frame.maxY <= first.frame.minY + Self.headerBar + 1.5
        let rowOnIndex = addRowButton.frame.maxX <= Self.rowBar + 1.5
            && addRowButton.frame.minY >= last.frame.maxY - Self.bottomPad - 1
        return colOnHeader && rowOnIndex && sliceCount >= 1
    }

    func coversHiddenSource() -> Bool {
        slices.allSatisfy(\.fillsPaper)
    }

    var sliceCount: Int { slices.count }
    var continuationRepeatsHeader: Bool {
        slices.dropFirst().allSatisfy(\.spec.isContinuation)
    }
    var storageRowCount: Int { block.rows.count }
    var storageColumnCount: Int { block.columnCount }
    var hasFieldFocus: Bool { containsResponder(window?.firstResponder) }

    func clickAddRow() { rowBelow() }
    func clickAddColumn() { colRight() }
    func clickDeleteRow() { delRow() }
    func clickDeleteColumn() { delCol() }
    func pressTab() {
        commitCurrent()
        moveSelection(columnDelta: 1, rowDelta: 0)
    }
    func pressReturn() {
        commitCurrent()
        moveSelection(columnDelta: 0, rowDelta: 1)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        axis = .cell
        selectedRow = field.tag / 1000
        selectedColumn = field.tag % 1000
        needsLayout = true
        needsDisplay = true
        tableDelegate?.pagesTableDidChangeFocus(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        tableDelegate?.pagesTable(self, commit: field.tag / 1000, column: field.tag % 1000, text: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertTab(_:)) {
            commitCurrent()
            moveSelection(columnDelta: 1, rowDelta: 0)
            return true
        }
        if commandSelector == #selector(insertBacktab(_:)) {
            commitCurrent()
            moveSelection(columnDelta: -1, rowDelta: 0)
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            commitCurrent()
            moveSelection(columnDelta: 0, rowDelta: 1)
            return true
        }
        return false
    }

    private func commitCurrent() {
        for slice in slices {
            if let field = slice.field(row: selectedRow, column: selectedColumn) {
                tableDelegate?.pagesTable(self, commit: selectedRow, column: selectedColumn, text: field.stringValue)
                return
            }
        }
    }

    private func moveSelection(columnDelta: Int, rowDelta: Int) {
        var col = selectedColumn + columnDelta
        var row = selectedRow
        if rowDelta != 0 {
            if row <= 1 { row = rowDelta > 0 ? 2 : 0 }
            else { row += rowDelta }
            if row == 1 { row += rowDelta > 0 ? 1 : -1 }
        }
        if col >= block.columnCount {
            if row >= block.rows.count - 1 {
                tableDelegate?.pagesTable(self, insertRow: .below)
                return
            }
            col = 0
            row += (row <= 1 ? 2 : 1)
        }
        if col < 0 { col = block.columnCount - 1; row = row <= 2 ? 0 : row - 1 }
        if rowDelta > 0, row > block.rows.count - 1 {
            tableDelegate?.pagesTable(self, insertRow: .below)
            return
        }
        row = min(max(row == 1 ? 0 : row, 0), block.rows.count - 1)
        if row == 1 { row = 0 }
        focusCell(row: row, column: max(0, col))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Insert Row Above", action: #selector(rowAbove), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Row Below", action: #selector(rowBelow), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Column Left", action: #selector(colLeft), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Column Right", action: #selector(colRight), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Row", action: #selector(delRow), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Column", action: #selector(delCol), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Table", action: #selector(delTable), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func rowAbove() { tableDelegate?.pagesTable(self, insertRow: .above) }
    @objc private func rowBelow() { tableDelegate?.pagesTable(self, insertRow: .below) }
    @objc private func colLeft() { tableDelegate?.pagesTable(self, insertColumn: .left) }
    @objc private func colRight() { tableDelegate?.pagesTable(self, insertColumn: .right) }
    @objc private func delRow() { tableDelegate?.pagesTableDeleteRow(self) }
    @objc private func delCol() { tableDelegate?.pagesTableDeleteColumn(self) }
    @objc private func delTable() { tableDelegate?.pagesTableDeleteTable(self) }
    @objc private func deleteSelection() {
        switch axis {
        case .column:
            delCol()
        case .table:
            delTable()
        case .row, .cell:
            delRow()
        }
    }

    func drawExported(intoPage paper: CGRect, paperOnCanvas: CGRect) {
        for slice in slices {
            slice.drawExported(intoPage: paper, paperOnCanvas: paperOnCanvas, origin: frame.origin)
        }
    }

    fileprivate var currentAxis: Axis { axis }
    fileprivate var currentRow: Int { selectedRow }
    fileprivate var currentColumn: Int { selectedColumn }
    fileprivate var currentColumnWidths: [CGFloat] { columnWidths }
}

// MARK: - Page slice

private final class TableSliceView: NSView {
    weak var parent: PagesTableView?
    private(set) var spec = PageLayout.TablePageSlice(page: 0, rows: [], y: 0, height: 0)
    var columnWidths: [CGFloat] = []
    private var fields: [NSTextField] = []
    private var fieldKey = ""
    private var darkPaper = false
    private var block: TableMutator.Block?
    var fillsPaper: Bool { true }

    override var isFlipped: Bool { true }

    init(parent: PagesTableView) {
        self.parent = parent
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(spec: PageLayout.TablePageSlice, startY: CGFloat, block: TableMutator.Block, darkPaper: Bool) {
        self.spec = spec
        self.block = block
        self.darkPaper = darkPaper
        layer?.backgroundColor = Theme.paperColor(darkPaper: darkPaper).cgColor
        needsDisplay = true
    }

    func storageRow(atY y: CGFloat) -> Int? {
        spec.rows.first(where: {
            !$0.isRepeatedHeader && y >= $0.y - spec.y && y <= $0.y - spec.y + PagesTableView.rowHeight
        })?.storageRow
    }

    func field(row: Int, column: Int) -> NSTextField? {
        fields.first { $0.tag == row * 1000 + column }
    }

    @discardableResult
    func focusField(row: Int, column: Int) -> Bool {
        guard let field = field(row: row, column: column) else { return false }
        window?.makeFirstResponder(field)
        return true
    }

    func rebuildFieldsIfNeeded() {
        guard let parent, let block else { return }
        let cells = block.rows.map { $0.joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
        let key = "\(block.range.location)-\(block.rows.count)-\(block.columnCount)-\(spec.page)-\(spec.rows.count)-\(cells)"
        if key == fieldKey { return }
        fieldKey = key
        fields.forEach { $0.removeFromSuperview() }
        fields = []
        let cols = max(1, block.columnCount)
        for row in spec.rows where !row.isRepeatedHeader {
            let display = row.storageRow == 0 ? 0 : row.storageRow - 1
            for c in 0..<cols {
                let field = NSTextField()
                field.isBordered = false
                field.drawsBackground = false
                field.focusRingType = .none
                field.font = row.storageRow == 0
                    ? .systemFont(ofSize: 12, weight: .semibold)
                    : .systemFont(ofSize: 12, weight: .regular)
                field.textColor = Theme.bodyColor(darkPaper: darkPaper)
                field.delegate = parent
                field.lineBreakMode = .byTruncatingTail
                field.cell?.wraps = false
                field.tag = row.storageRow * 1000 + c
                let value = row.storageRow < block.rows.count && c < block.rows[row.storageRow].count
                    ? block.rows[row.storageRow][c]
                    : ""
                field.stringValue = value.trimmingCharacters(in: .whitespaces)
                field.placeholderString = display == 0 ? "Header" : ""
                addSubview(field)
                fields.append(field)
            }
        }
    }

    func layoutFields() {
        let tableX = PagesTableView.rowBar
        for field in fields {
            let storage = field.tag / 1000
            let column = field.tag % 1000
            guard let row = spec.rows.first(where: { $0.storageRow == storage && !$0.isRepeatedHeader }) else {
                field.isHidden = true
                continue
            }
            var x = tableX
            for i in 0..<column where i < columnWidths.count {
                x += columnWidths[i]
            }
            let w = column < columnWidths.count ? columnWidths[column] : PagesTableView.minColumn
            field.frame = CGRect(
                x: x + PagesTableView.cellPadX - 2,
                y: (row.y - spec.y) + 5,
                width: max(20, w - PagesTableView.cellPadX * 2 + 4),
                height: 18
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paperColor(darkPaper: darkPaper).setFill()
        bounds.fill()
        guard let parent, let block else { return }
        drawHeaders(parent: parent, block: block)
        drawGrid(parent: parent, block: block)
        drawRepeatedHeaderText(block: block)
    }

    private func drawHeaders(parent: PagesTableView, block: TableMutator.Block) {
        Theme.tableGutterFill(darkPaper: darkPaper).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: PagesTableView.headerBar).fill()
        CGRect(x: 0, y: 0, width: PagesTableView.rowBar, height: bounds.height).fill()
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let color = NSColor.secondaryLabelColor
        var x = PagesTableView.rowBar
        for c in 0..<max(1, block.columnCount) {
            let w = c < columnWidths.count ? columnWidths[c] : PagesTableView.minColumn
            let selected = parent.currentAxis == .column && parent.currentColumn == c
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                CGRect(x: x, y: 0, width: w, height: PagesTableView.headerBar).fill()
            }
            let letter = PageLayout.columnLetter(c) as NSString
            letter.draw(
                in: CGRect(x: x, y: 2, width: w, height: 14),
                withAttributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: centered()
                ]
            )
            x += w
        }
        for row in spec.rows where !row.isRepeatedHeader {
            let y = row.y - spec.y
            let selected = parent.currentAxis == .row && parent.currentRow == row.storageRow
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                CGRect(x: 0, y: y, width: PagesTableView.rowBar, height: PagesTableView.rowHeight).fill()
            }
            let number = displayNumber(row.storageRow) as NSString
            number.draw(
                in: CGRect(x: 0, y: y + 6, width: PagesTableView.rowBar, height: 14),
                withAttributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: centered()
                ]
            )
        }
    }

    private func displayNumber(_ storageRow: Int) -> String {
        if storageRow == 0 { return "1" }
        if storageRow >= 2 { return "\(storageRow)" }
        return ""
    }

    private func centered() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }

    private func drawGrid(parent: PagesTableView, block: TableMutator.Block) {
        let tableX = PagesTableView.rowBar
        let tableW = max(8, bounds.width - PagesTableView.rowBar)
        for (index, row) in spec.rows.enumerated() {
            let y = row.y - spec.y
            let rect = CGRect(x: tableX, y: y, width: tableW, height: PagesTableView.rowHeight)
            if row.storageRow == 0 {
                Theme.tableHeaderFill(darkPaper: darkPaper).setFill()
                rect.fill()
            }
            if parent.currentAxis == .cell,
               row.storageRow == parent.currentRow,
               !row.isRepeatedHeader,
               parent.currentColumn < columnWidths.count {
                var hx = tableX
                for i in 0..<parent.currentColumn { hx += columnWidths[i] }
                NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
                CGRect(x: hx + 1, y: y + 1, width: columnWidths[parent.currentColumn] - 2, height: PagesTableView.rowHeight - 2).fill()
            }
            Theme.tableBorder(darkPaper: darkPaper).setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: tableX, y: y + 0.5))
            line.line(to: CGPoint(x: tableX + tableW, y: y + 0.5))
            line.lineWidth = 1
            line.stroke()
            if index == spec.rows.count - 1 {
                let bottom = NSBezierPath()
                bottom.move(to: CGPoint(x: tableX, y: y + PagesTableView.rowHeight + 0.5))
                bottom.line(to: CGPoint(x: tableX + tableW, y: y + PagesTableView.rowHeight + 0.5))
                bottom.lineWidth = 1
                bottom.stroke()
            }
        }
        var x = tableX
        let firstY = (spec.rows.first?.y ?? spec.y) - spec.y
        let lastY = (spec.rows.last?.y ?? spec.y) - spec.y + PagesTableView.rowHeight
        for (i, w) in columnWidths.enumerated() {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x + 0.5, y: firstY))
            line.line(to: CGPoint(x: x + 0.5, y: lastY))
            line.lineWidth = 1
            Theme.tableBorder(darkPaper: darkPaper).setStroke()
            line.stroke()
            x += w
            if i == columnWidths.count - 1 {
                let edge = NSBezierPath()
                edge.move(to: CGPoint(x: x + 0.5, y: firstY))
                edge.line(to: CGPoint(x: x + 0.5, y: lastY))
                edge.stroke()
            }
        }
    }

    private func drawRepeatedHeaderText(block: TableMutator.Block) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for row in spec.rows where row.isRepeatedHeader {
            var x = PagesTableView.rowBar
            for c in 0..<max(1, block.columnCount) {
                let w = c < columnWidths.count ? columnWidths[c] : PagesTableView.minColumn
                let raw = c < (block.rows.first?.count ?? 0) ? block.rows[0][c] : ""
                let text = raw.trimmingCharacters(in: .whitespaces) as NSString
                if text.length > 0 {
                    text.draw(
                        in: CGRect(x: x + PagesTableView.cellPadX, y: row.y - spec.y + 6, width: max(8, w - PagesTableView.cellPadX * 2), height: 16),
                        withAttributes: [
                            .font: font,
                            .foregroundColor: Theme.bodyColor(darkPaper: darkPaper)
                        ]
                    )
                }
                x += w
            }
        }
    }

    func drawExported(intoPage paper: CGRect, paperOnCanvas: CGRect, origin: CGPoint) {
        func toPage(_ local: CGRect) -> CGRect {
            CGRect(
                x: origin.x + frame.minX + local.minX - paperOnCanvas.minX,
                y: origin.y + frame.minY + local.minY - paperOnCanvas.minY,
                width: local.width,
                height: local.height
            )
        }
        guard let block else { return }
        let tableX = PagesTableView.rowBar
        let tableW = max(8, bounds.width - PagesTableView.rowBar)
        for row in spec.rows {
            let y = row.y - spec.y
            let rect = toPage(CGRect(x: tableX, y: y, width: tableW, height: PagesTableView.rowHeight))
            guard rect.intersects(paper) else { continue }
            if row.storageRow == 0 {
                Theme.tableHeaderFill(darkPaper: darkPaper).setFill()
                rect.fill()
            }
            Theme.paperColor(darkPaper: darkPaper).setFill()
            if row.storageRow != 0 { rect.fill() }
            if row.storageRow == 0 {
                Theme.tableHeaderFill(darkPaper: darkPaper).setFill()
                rect.fill()
            }
            Theme.tableBorder(darkPaper: darkPaper).setStroke()
            NSBezierPath(rect: rect).stroke()
            let font: NSFont = row.storageRow == 0
                ? .systemFont(ofSize: 12, weight: .semibold)
                : .systemFont(ofSize: 12, weight: .regular)
            var x = tableX
            for c in 0..<max(1, block.columnCount) {
                let w = c < columnWidths.count ? columnWidths[c] : PagesTableView.minColumn
                let raw = row.storageRow < block.rows.count && c < block.rows[row.storageRow].count
                    ? block.rows[row.storageRow][c]
                    : ""
                let text = raw.trimmingCharacters(in: .whitespaces) as NSString
                if text.length > 0 {
                    let cell = toPage(CGRect(
                        x: x + PagesTableView.cellPadX,
                        y: y + 6,
                        width: max(8, w - PagesTableView.cellPadX * 2),
                        height: 16
                    ))
                    text.draw(in: cell, withAttributes: [
                        .font: font,
                        .foregroundColor: Theme.bodyColor(darkPaper: darkPaper)
                    ])
                }
                x += w
            }
        }
    }
}

/// Pages-style circular insert / delete control.
final class PagesInsertButton: NSButton {
    enum Kind { case add, remove }
    var kind: Kind = .add
    var darkPaper = false
    private var hovered = false

    convenience init(kind: Kind) {
        self.init(frame: .zero)
        self.kind = kind
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        image = nil
        title = ""
        focusRingType = .none
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSCursor.pointingHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        if kind == .remove {
            fill = NSColor.systemRed.withAlphaComponent(hovered ? 0.95 : 0.8)
        } else {
            fill = NSColor.systemGreen.withAlphaComponent(hovered ? 0.95 : 0.82)
        }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        fill.setFill()
        circle.fill()
        NSColor.white.setStroke()
        let cx = bounds.midX
        let cy = bounds.midY
        let arm: CGFloat = 3.4
        let stroke = NSBezierPath()
        stroke.lineWidth = 1.5
        stroke.lineCapStyle = .round
        stroke.move(to: CGPoint(x: cx - arm, y: cy))
        stroke.line(to: CGPoint(x: cx + arm, y: cy))
        if kind == .add {
            stroke.move(to: CGPoint(x: cx, y: cy - arm))
            stroke.line(to: CGPoint(x: cx, y: cy + arm))
        }
        stroke.stroke()
    }
}
