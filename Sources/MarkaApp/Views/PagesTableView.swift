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
    func pagesTable(_ view: PagesTableView, moveRow from: Int, to: Int)
    func pagesTable(_ view: PagesTableView, moveColumn from: Int, to: Int)
    /// A picture in a cell was clicked: the cell's source is committed, then the image card opens.
    func pagesTable(_ view: PagesTableView, clickedImage index: Int, row: Int, column: Int, cellRect: CGRect)
}

/// Pages-style Markdown table: native grid, row/column headers, one slice per page.
/// A GFM table drawn the way GitHub renders it: bold header, 1 px grid, striped rows. No editing
/// chrome on the table itself (no column letters, row numbers, or +/− chips) — row and column
/// commands live in Format → Table and the cell's context menu and act on the focused cell.
/// Cells stay editable in place; Tab / Return move between them.
final class PagesTableView: NSView, NSTextFieldDelegate {
    weak var tableDelegate: PagesTableDelegate?
    private(set) var block: TableMutator.Block
    private(set) var selectedRow = 0
    private(set) var selectedColumn = 0
    var darkPaper = false
    /// For images in cells (relative paths).
    var documentDirectory: URL? { (tableDelegate as? PagedEditorView)?.documentDirectory }

    static let rowHeight: CGFloat = 28
    static let headerBar: CGFloat = 0
    static let rowBar: CGFloat = 0
    static let cellPadX: CGFloat = 13
    static let minColumn: CGFloat = 56
    static let topPad: CGFloat = 0
    static let bottomPad: CGFloat = 12
    static let edgeInset: CGFloat = topPad

    private var flow: PageLayout.TableFlow?
    private var slices: [TableSliceView] = []
    private var columnWidths: [CGFloat] = []

    // Editing chrome: only while the cursor is in one of this table's cells.
    enum Command: CaseIterable {
        case rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn

        var title: String {
            switch self {
            case .rowAbove: return "Insert Row Above"
            case .rowBelow: return "Insert Row Below"
            case .columnLeft: return "Insert Column Left"
            case .columnRight: return "Insert Column Right"
            case .deleteRow: return "Delete Row"
            case .deleteColumn: return "Delete Column"
            }
        }
    }

    /// Green + on each side of a grip (where the new row / column appears) and a red − beside it.
    private(set) var buttons: [Command: TableCircleButton] = [:]
    let rowGrip = TableGripView(axis: .row)
    let columnGrip = TableGripView(axis: .column)
    private let dropIndicator = NSView()
    private(set) var isEditingChromeVisible = false
    private var chromeViews: [NSView] {
        [rowGrip, columnGrip, dropIndicator] + Command.allCases.compactMap { buttons[$0] }
    }

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
        for command in Command.allCases {
            let kind: TableCircleButton.Kind = (command == .deleteRow || command == .deleteColumn) ? .remove : .add
            let button = TableCircleButton(kind: kind, title: command.title)
            button.target = self
            button.action = #selector(circleTapped(_:))
            buttons[command] = button
        }
        rowGrip.onDrag = { [weak self] phase, point in self?.dragRow(phase, point) }
        columnGrip.onDrag = { [weak self] phase, point in self?.dragColumn(phase, point) }
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1
        for view in chromeViews {
            view.isHidden = true
            addSubview(view)
        }
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
            return Self.headerBar + Self.storageRows(for: block).map { height(of: $0) }.reduce(0, +) + Self.bottomPad
        }
        return max(Self.rowHeight, flow.endY - flow.startY)
    }

    /// Per storage row: taller where a cell shows a picture.
    private(set) var rowHeights: [Int: CGFloat] = [:]

    func height(of storageRow: Int) -> CGFloat { rowHeights[storageRow] ?? Self.rowHeight }

    /// Widest picture a column's cells may show.
    func pictureMaxWidth(_ column: Int) -> CGFloat {
        max(16, (column < columnWidths.count ? columnWidths[column] : Self.minColumn) - Self.cellPadX * 2)
    }

    /// Column widths from what cells *show* (text without Markdown, pictures at their size, never
    /// more than 55 % of the table each), then row heights from the pictures in each row.
    static func layoutMetrics(block: TableMutator.Block, maxWidth: CGFloat, base: URL?) -> (columns: [CGFloat], rowHeights: [Int: CGFloat]) {
        let cols = max(1, block.columnCount)
        var widths = Array(repeating: Self.minColumn, count: cols)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let cap = maxWidth * 0.55
        for row in block.rows.enumerated() where row.offset != 1 {
            for (c, cell) in row.element.enumerated() where c < cols {
                let shown = CellMarkdown.attributed(cell, font: font, color: .black, darkPaper: false, base: base,
                                                    maxPictureWidth: cap - Self.cellPadX * 2)
                let w = ceil(shown.size().width) + Self.cellPadX * 2
                widths[c] = max(widths[c], min(w, cap))
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
        var heights: [Int: CGFloat] = [:]
        for row in block.rows.indices where row != 1 {
            var tallest: CGFloat = 0
            for (c, cell) in block.rows[row].enumerated() where c < cols {
                for image in CellMarkdown.cellImages(cell.replacingOccurrences(of: "\\|", with: "|"), base: base,
                                                     maxWidth: max(16, widths[c] - Self.cellPadX * 2)) {
                    tallest = max(tallest, image.picture?.size.height ?? 0)
                }
            }
            if tallest > 0 { heights[row] = max(Self.rowHeight, tallest + 12) }
        }
        return (widths, heights)
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
            var y = Self.headerBar
            let rows = (0..<visibleRowCount).map { display -> PageLayout.TableFlow.Row in
                let storage = storageRow(forDisplay: display)
                let row = PageLayout.TableFlow.Row(storageRow: storage, y: y, page: 0, isRepeatedHeader: false, height: height(of: storage))
                y += height(of: storage)
                return row
            }
            let height = y + Self.bottomPad
            pageSlices = [PageLayout.TablePageSlice(page: 0, rows: rows, y: 0, height: height)]
        }
        while slices.count > pageSlices.count {
            slices.removeLast().removeFromSuperview()
        }
        while slices.count < pageSlices.count {
            let slice = TableSliceView(parent: self)
            addSubview(slice, positioned: .below, relativeTo: rowGrip)
            slices.append(slice)
        }
        let startY = flow?.startY ?? 0
        for (index, spec) in pageSlices.enumerated() {
            let slice = slices[index]
            slice.configure(spec: spec, startY: startY, block: block, darkPaper: darkPaper)
        }
    }

    private func measureColumns(maxWidth: CGFloat) {
        let metrics = Self.layoutMetrics(block: block, maxWidth: maxWidth, base: documentDirectory)
        columnWidths = metrics.columns
        rowHeights = metrics.rowHeights
    }

    /// From a slice's field: commit the cell, then let the canvas open the image card there.
    func cellImageClicked(_ field: MarkdownCellField, index: Int) {
        let row = field.tag / 1000, column = field.tag % 1000
        let rect = field.convert(field.bounds, to: superview)
        tableDelegate?.pagesTable(self, clickedImage: index, row: row, column: column, cellRect: rect)
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
        layoutEditChrome()
    }

    // MARK: - Editing chrome

    func setEditingChrome(_ visible: Bool) {
        guard visible != isEditingChromeVisible else {
            if visible { layoutEditChrome() }
            return
        }
        isEditingChromeVisible = visible
        for view in chromeViews { view.isHidden = !visible }
        dropIndicator.isHidden = true
        if visible { layoutEditChrome() }
    }

    private var tableWidth: CGFloat { max(8, columnWidths.reduce(0, +)) }

    private func columnX(_ column: Int) -> CGFloat {
        columnWidths.prefix(max(0, column)).reduce(0, +)
    }

    /// The slice (page piece) that shows `storageRow`.
    private func slice(showing storageRow: Int) -> TableSliceView? {
        slices.first { $0.spec.rows.contains { $0.storageRow == storageRow && !$0.isRepeatedHeader } } ?? slices.first
    }

    private func place(_ command: Command, centeredAt point: CGPoint, visible: Bool = true) {
        guard let button = buttons[command] else { return }
        button.isHidden = !visible
        let size = TableCircleButton.size
        button.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    /// Row cluster in the left margin: grip beside the row, + on the row's top and bottom edges,
    /// − to the grip's left. Column cluster above the table: grip above the column, + on its left
    /// and right edges, − above the grip. The header row has only "+ below".
    private func layoutEditChrome() {
        guard isEditingChromeVisible else { return }
        let gap: CGFloat = 3
        let size = TableCircleButton.size
        if let y = primaryY(for: selectedRow) {
            let gripX = -TableGripView.rowSize.width - 8
            rowGrip.frame = CGRect(
                x: gripX,
                y: y + (height(of: selectedRow) - TableGripView.rowSize.height) / 2,
                width: TableGripView.rowSize.width,
                height: TableGripView.rowSize.height
            )
            let body = selectedRow >= 2
            rowGrip.isHidden = !body
            let midX = rowGrip.frame.midX
            place(.rowAbove, centeredAt: CGPoint(x: midX, y: y), visible: body)
            place(.rowBelow, centeredAt: CGPoint(x: midX, y: y + height(of: selectedRow)))
            place(.deleteRow, centeredAt: CGPoint(x: rowGrip.frame.minX - gap - size / 2, y: rowGrip.frame.midY), visible: body)
        }
        if selectedColumn < columnWidths.count, let piece = slice(showing: selectedRow) {
            let x = columnX(selectedColumn)
            let w = columnWidths[selectedColumn]
            columnGrip.isHidden = false
            columnGrip.frame = CGRect(
                x: x + (w - TableGripView.columnSize.width) / 2,
                y: piece.frame.minY - TableGripView.columnSize.height - 6,
                width: TableGripView.columnSize.width,
                height: TableGripView.columnSize.height
            )
            let midY = columnGrip.frame.midY
            place(.columnLeft, centeredAt: CGPoint(x: x, y: midY))
            place(.columnRight, centeredAt: CGPoint(x: x + w, y: midY))
            place(.deleteColumn, centeredAt: CGPoint(x: columnGrip.frame.midX, y: columnGrip.frame.minY - gap - size / 2))
        } else {
            columnGrip.isHidden = true
            [Command.columnLeft, .columnRight, .deleteColumn].forEach { buttons[$0]?.isHidden = true }
        }
        for view in chromeViews { addSubview(view, positioned: .above, relativeTo: nil) }
    }

    @objc private func circleTapped(_ sender: TableCircleButton) {
        guard let command = buttons.first(where: { $0.value === sender })?.key else { return }
        perform(command)
    }

    func perform(_ command: Command) {
        commitPendingEdit()
        switch command {
        case .rowAbove: tableDelegate?.pagesTable(self, insertRow: .above)
        case .rowBelow: tableDelegate?.pagesTable(self, insertRow: .below)
        case .columnLeft: tableDelegate?.pagesTable(self, insertColumn: .left)
        case .columnRight: tableDelegate?.pagesTable(self, insertColumn: .right)
        case .deleteRow: tableDelegate?.pagesTableDeleteRow(self)
        case .deleteColumn: tableDelegate?.pagesTableDeleteColumn(self)
        }
    }

    /// Drop target for a row drag at `y`: insertion boundary (storage index the row goes before)
    /// and the moved row's final index.
    func rowDrop(atY y: CGFloat) -> (boundary: Int, target: Int, lineY: CGFloat) {
        let body = Array(2..<max(2, block.rows.count))
        var boundary = block.rows.count
        var lineY = (primaryY(for: body.last ?? 0) ?? 0) + height(of: body.last ?? 0)
        for row in body {
            if let rowY = primaryY(for: row), y < rowY + height(of: row) / 2 {
                boundary = row
                lineY = rowY
                break
            }
        }
        let target = boundary > selectedRow ? boundary - 1 : boundary
        return (boundary, target, lineY)
    }

    func columnDrop(atX x: CGFloat) -> (target: Int, lineX: CGFloat) {
        var boundary = columnWidths.count
        var lineX = tableWidth
        var cursor: CGFloat = 0
        for (index, w) in columnWidths.enumerated() {
            if x < cursor + w / 2 {
                boundary = index
                lineX = cursor
                break
            }
            cursor += w
        }
        let target = boundary > selectedColumn ? boundary - 1 : boundary
        return (target, lineX)
    }

    private func dragRow(_ phase: NSEvent.Phase, _ point: CGPoint) {
        let drop = rowDrop(atY: point.y)
        switch phase {
        case .ended:
            dropIndicator.isHidden = true
            if drop.target != selectedRow {
                commitPendingEdit()
                tableDelegate?.pagesTable(self, moveRow: selectedRow, to: drop.target)
            }
        default:
            dropIndicator.isHidden = false
            dropIndicator.frame = CGRect(x: 0, y: drop.lineY - 1, width: tableWidth, height: 2)
            rowGrip.frame.origin.y = point.y - rowGrip.frame.height / 2
        }
    }

    private func dragColumn(_ phase: NSEvent.Phase, _ point: CGPoint) {
        let drop = columnDrop(atX: point.x)
        switch phase {
        case .ended:
            dropIndicator.isHidden = true
            if drop.target != selectedColumn {
                commitPendingEdit()
                tableDelegate?.pagesTable(self, moveColumn: selectedColumn, to: drop.target)
            }
        default:
            let piece = slice(showing: selectedRow)
            dropIndicator.isHidden = false
            dropIndicator.frame = CGRect(x: drop.lineX - 1, y: piece?.frame.minY ?? 0, width: 2, height: piece?.frame.height ?? bounds.height)
            columnGrip.frame.origin.x = point.x - columnGrip.frame.width / 2
        }
    }

    /// Chrome (bar, grips) sits partly outside the table's frame; hit-test it first.
    func editChromeHit(_ point: NSPoint) -> NSView? {
        guard isEditingChromeVisible else { return nil }
        let local = convert(point, from: superview)
        for button in buttons.values where !button.isHidden && button.frame.contains(local) { return button }
        for grip in [rowGrip, columnGrip] where !grip.isHidden && grip.frame.contains(local) { return grip }
        return nil
    }

    // Testing: simulate grip drags exactly as mouse events would report them.
    func testDragRow(beforeStorageRow target: Int) {
        guard let y = target < block.rows.count ? primaryY(for: target) : (primaryY(for: block.rows.count - 1)).map({ $0 + height(of: block.rows.count - 1) + 2 }) else { return }
        let start = CGPoint(x: rowGrip.frame.midX, y: rowGrip.frame.midY)
        dragRow(.began, start)
        dragRow(.changed, CGPoint(x: start.x, y: y + 2))
        dragRow(.ended, CGPoint(x: start.x, y: y + 2))
    }

    func testDragColumn(beforeColumn target: Int) {
        let x = target < columnWidths.count ? columnX(target) + 2 : tableWidth - 1
        let start = CGPoint(x: columnGrip.frame.midX, y: columnGrip.frame.midY)
        dragColumn(.began, start)
        dragColumn(.changed, CGPoint(x: x, y: start.y))
        dragColumn(.ended, CGPoint(x: x, y: start.y))
    }

    /// The canvas hit-tests the "+ row below" button (it hangs outside the table frame).
    func testBarButtonHit(in canvas: NSView) -> Bool {
        guard let button = buttons[.rowBelow], !button.isHidden else { return false }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: canvas)
        return canvas.hitTest(point) === button
    }

    var testGripsVisible: (row: Bool, column: Bool) { (!rowGrip.isHidden, !columnGrip.isHidden) }

    /// Visible controls and whether each + / − sits where it acts (row edges, column edges, beside grips).
    var testControlLayout: (visible: Set<String>, placedOnEdges: Bool) {
        layoutSubtreeIfNeeded()
        var visible = Set<String>()
        for (command, button) in buttons where !button.isHidden { visible.insert("\(command)") }
        var ok = true
        if let y = primaryY(for: selectedRow) {
            if let below = buttons[.rowBelow], !below.isHidden { ok = ok && abs(below.frame.midY - (y + height(of: selectedRow))) < 1 }
            if let above = buttons[.rowAbove], !above.isHidden { ok = ok && abs(above.frame.midY - y) < 1 }
            if let delete = buttons[.deleteRow], !delete.isHidden { ok = ok && delete.frame.maxX <= rowGrip.frame.minX && abs(delete.frame.midY - rowGrip.frame.midY) < 1 }
        }
        if selectedColumn < columnWidths.count {
            let x = columnX(selectedColumn)
            if let left = buttons[.columnLeft] { ok = ok && abs(left.frame.midX - x) < 1 }
            if let right = buttons[.columnRight] { ok = ok && abs(right.frame.midX - (x + columnWidths[selectedColumn])) < 1 }
            if let delete = buttons[.deleteColumn] { ok = ok && delete.frame.maxY <= columnGrip.frame.minY }
        }
        return (visible, ok)
    }

    /// What a mouse click does: the cell field just becomes first responder (no keystroke).
    func testClickCell(row: Int, column: Int) {
        layoutSubtreeIfNeeded()
        for slice in slices {
            if let field = slice.field(row: row, column: column) {
                window?.makeFirstResponder(field)
                return
            }
        }
    }

    var testSelectedCell: (row: Int, column: Int) { (selectedRow, selectedColumn) }

    /// Row grip sits beside the selected row and the column grip above the selected column.
    var testGripsFollowSelection: Bool {
        layoutSubtreeIfNeeded()
        guard isEditingChromeVisible else { return false }
        var ok = true
        if selectedRow >= 2, let y = primaryY(for: selectedRow) {
            ok = ok && rowGrip.frame.midY > y && rowGrip.frame.midY < y + height(of: selectedRow)
        }
        if selectedColumn < columnWidths.count {
            let x = columnX(selectedColumn)
            ok = ok && columnGrip.frame.midX > x && columnGrip.frame.midX < x + columnWidths[selectedColumn]
        }
        return ok
    }

    /// (shown text, bold?) of a cell field — rendered unless the cell is being edited.
    func testCellDisplay(row: Int, column: Int) -> (text: String, bold: Bool)? {
        layoutSubtreeIfNeeded()
        for slice in slices {
            if let field = slice.field(row: row, column: column) {
                let shown = field.attributedStringValue
                let font = shown.length > 0 ? shown.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
                return (field.stringValue, font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
            }
        }
        return nil
    }

    func editChromeContains(windowPoint: NSPoint) -> Bool {
        guard isEditingChromeVisible, let superview else { return false }
        return editChromeHit(superview.convert(windowPoint, from: nil)) != nil
    }

    /// Top of `storageRow` in table coordinates (its own page slice, not a repeated header).
    private func primaryY(for storageRow: Int) -> CGFloat? {
        for slice in slices {
            if let row = slice.spec.rows.first(where: { $0.storageRow == storageRow && !$0.isRepeatedHeader }) {
                return slice.frame.minY + (row.y - slice.spec.y)
            }
        }
        return nil
    }

    func chromeRects() -> [CGRect] {
        slices.map(\.frame)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if let chrome = editChromeHit(point) { return chrome }
        guard frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    /// A click between cells (on a border) still edits the nearest cell.
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let slice = slices.first(where: { $0.frame.contains(local) }),
           let row = slice.storageRow(atY: local.y - slice.frame.minY),
           let column = columnIndex(atX: local.x) {
            focusCell(row: row, column: column)
            return
        }
        super.mouseDown(with: event)
    }

    private func columnIndex(atX x: CGFloat) -> Int? {
        var cursor: CGFloat = 0
        for (index, width) in columnWidths.enumerated() {
            if x <= cursor + width { return index }
            cursor += width
        }
        return columnWidths.isEmpty ? 0 : columnWidths.count - 1
    }

    func focusCell(row: Int, column: Int, stealFocus: Bool = true) {
        selectedRow = row
        selectedColumn = column
        if stealFocus {
            for slice in slices {
                if slice.focusField(row: row, column: column) { break }
            }
        }
        setEditingChrome(true)
        needsLayout = true
        needsDisplay = true
        slices.forEach { $0.needsDisplay = true }
    }

    /// GitHub look: nothing but the page slices (which hold the cells) — no chips or handles — and
    /// the grid starts at the content's left edge (no row-number gutter).
    var hasOnlyGitHubGrid: Bool {
        // The edit bar and grips appear only while a cell is being edited; nothing else is drawn.
        subviews.allSatisfy { $0 is TableSliceView || chromeViews.contains($0) } && Self.rowBar == 0 && Self.headerBar == 0
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

    func pressTab() {
        commitCurrent()
        moveSelection(columnDelta: 1, rowDelta: 0)
    }
    func pressReturn() {
        commitCurrent()
        moveSelection(columnDelta: 0, rowDelta: 1)
    }

    /// A cell became first responder (click, Tab, arrows, code). `controlTextDidBeginEditing` only
    /// fires on the first keystroke, so selection, grips, bar and menu commands follow this instead.
    func cellDidFocus(_ field: NSTextField) {
        let row = field.tag / 1000
        let column = field.tag % 1000
        let changed = row != selectedRow || column != selectedColumn || !isEditingChromeVisible
        selectedRow = row
        selectedColumn = column
        setEditingChrome(true)
        layoutEditChrome()
        if changed {
            needsDisplay = true
            tableDelegate?.pagesTableDidChangeFocus(self)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        (obj.object as? MarkdownCellField)?.restyleEditor()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        selectedRow = field.tag / 1000
        selectedColumn = field.tag % 1000
        setEditingChrome(true)
        needsLayout = true
        needsDisplay = true
        tableDelegate?.pagesTableDidChangeFocus(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let source = (field as? MarkdownCellField)?.currentSource ?? field.stringValue
        tableDelegate?.pagesTable(self, commit: field.tag / 1000, column: field.tag % 1000, text: source)
        // Hide the chrome once focus has really left the table (Tab into the next cell keeps it).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasFieldFocus else { return }
            self.setEditingChrome(false)
        }
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
        // Arrow keys: ↑ / ↓ always change row; ← / → leave the cell at the start / end of its text.
        let caret = textView.selectedRange()
        let length = (textView.string as NSString).length
        switch commandSelector {
        case #selector(moveUp(_:)):
            return navigate(rowDelta: -1)
        case #selector(moveDown(_:)):
            return navigate(rowDelta: 1)
        case #selector(moveLeft(_:)) where caret.length == 0 && caret.location == 0:
            return navigate(columnDelta: -1)
        case #selector(moveRight(_:)) where caret.length == 0 && caret.location >= length:
            return navigate(columnDelta: 1)
        default:
            return false
        }
    }

    /// Arrow navigation: clamped to the table (never inserts rows); the delimiter row is skipped.
    @discardableResult
    func navigate(columnDelta: Int = 0, rowDelta: Int = 0) -> Bool {
        let rows = [0] + Array(2..<max(2, block.rows.count))
        guard let index = rows.firstIndex(of: selectedRow) else { return false }
        let targetRow = rows[min(max(0, index + rowDelta), rows.count - 1)]
        let targetColumn = min(max(0, selectedColumn + columnDelta), max(0, block.columnCount - 1))
        guard targetRow != selectedRow || targetColumn != selectedColumn else { return true }
        commitCurrent()
        focusCell(row: targetRow, column: targetColumn)
        // Coming from the right, land at the end; otherwise at the start.
        if let editor = window?.firstResponder as? NSTextView {
            let end = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: columnDelta < 0 ? end : 0, length: 0))
        }
        return true
    }

    /// Stop editing the focused cell without committing (its text was committed already).
    func detachEditingField() {
        slices.forEach { $0.detachEditingField() }
    }

    /// Write the focused cell's pending text before a structural edit changes the coordinates.
    func commitPendingEdit() {
        guard hasFieldFocus else { return }
        commitCurrent()
    }

    private func commitCurrent() {
        for slice in slices {
            if let field = slice.field(row: selectedRow, column: selectedColumn) {
                let source = (field as? MarkdownCellField)?.currentSource ?? field.stringValue
                tableDelegate?.pagesTable(self, commit: selectedRow, column: selectedColumn, text: source)
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

    @objc private func rowAbove() { commitPendingEdit(); tableDelegate?.pagesTable(self, insertRow: .above) }
    @objc private func rowBelow() { commitPendingEdit(); tableDelegate?.pagesTable(self, insertRow: .below) }
    @objc private func colLeft() { commitPendingEdit(); tableDelegate?.pagesTable(self, insertColumn: .left) }
    @objc private func colRight() { commitPendingEdit(); tableDelegate?.pagesTable(self, insertColumn: .right) }
    @objc private func delRow() { commitPendingEdit(); tableDelegate?.pagesTableDeleteRow(self) }
    @objc private func delCol() { commitPendingEdit(); tableDelegate?.pagesTableDeleteColumn(self) }
    @objc private func delTable() { tableDelegate?.pagesTableDeleteTable(self) }

    func drawExported(intoPage paper: CGRect, paperOnCanvas: CGRect) {
        for slice in slices {
            slice.drawExported(intoPage: paper, paperOnCanvas: paperOnCanvas, origin: frame.origin)
        }
    }

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
            !$0.isRepeatedHeader && y >= $0.y - spec.y && y <= $0.y - spec.y + $0.height
        })?.storageRow
    }

    func detachEditingField() {
        for field in fields where field.currentEditor() != nil {
            field.delegate = nil
            field.abortEditing()
        }
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
        // Old fields belong to the previous table shape: never let them commit their text into the
        // new one (that wrote stale values into moved/inserted rows and columns).
        for field in fields {
            field.delegate = nil
            field.abortEditing()
            field.removeFromSuperview()
        }
        fields = []
        let cols = max(1, block.columnCount)
        for row in spec.rows where !row.isRepeatedHeader {
            let display = row.storageRow == 0 ? 0 : row.storageRow - 1
            for c in 0..<cols {
                let field = MarkdownCellField()
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
                let cellFont = field.font ?? .systemFont(ofSize: 12)
                let ink = Theme.bodyColor(darkPaper: darkPaper)
                let dark = darkPaper
                let alignment = c < block.alignments.count ? block.alignments[c] : .none
                field.alignment = alignment == .center ? .center : alignment == .right ? .right : .natural
                let base = parent.documentDirectory
                // The column's picture width is read when drawing: columns are measured after the
                // fields exist, so a captured width would be the minimum one.
                let column = c
                field.render = { [weak parent] in
                    TableSliceView.aligned(CellMarkdown.attributed($0, font: cellFont, color: ink, darkPaper: dark, base: base,
                                                                   maxPictureWidth: parent?.pictureMaxWidth(column) ?? 200), alignment)
                }
                field.onImageClick = { [weak parent] cell, index in parent?.cellImageClicked(cell, index: index) }
                field.allowsEditingTextAttributes = true   // the field editor shows the styled source
                field.styleEditor = { CellMarkdown.styleSource($0, font: cellFont, color: ink, darkPaper: dark, base: base,
                                                                         maxPictureWidth: parent.pictureMaxWidth(column)) }
                field.baseTypingAttributes = [.font: cellFont, .foregroundColor: ink]
                field.onFocus = { [weak parent] cell in parent?.cellDidFocus(cell) }
                field.raw = value.trimmingCharacters(in: .whitespaces)
                field.placeholderString = display == 0 ? "Header" : ""
                addSubview(field)
                fields.append(field)
            }
        }
    }

    func layoutFields() {
        let tableX: CGFloat = 0
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
            let frame = CGRect(
                x: x + PagesTableView.cellPadX - 2,
                y: (row.y - spec.y) + 5,
                width: max(20, w - PagesTableView.cellPadX * 2 + 4),
                height: max(18, row.height - 10)
            )
            let resized = abs(field.frame.width - frame.width) > 0.5
            field.frame = frame
            // A new column width changes picture sizes: re-render (not while the cell is edited).
            if resized, let cell = field as? MarkdownCellField, !cell.isEditingSource { cell.showRendered() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paperColor(darkPaper: darkPaper).setFill()
        bounds.fill()
        guard let block else { return }
        drawGrid(block: block)
        drawRepeatedHeaderText(block: block)
    }

    /// GitHub: even data rows striped, 1 px border around every cell.
    static func isStriped(_ storageRow: Int) -> Bool {
        storageRow >= 2 && (storageRow - 1) % 2 == 0
    }

    private func drawGrid(block: TableMutator.Block) {
        let tableW = max(8, columnWidths.reduce(0, +))
        for row in spec.rows {
            let y = row.y - spec.y
            let rect = CGRect(x: 0, y: y, width: tableW, height: row.height)
            if Self.isStriped(row.storageRow) {
                Theme.tableHeaderFill(darkPaper: darkPaper).setFill()
                rect.fill()
            }
        }
        Theme.tableBorder(darkPaper: darkPaper).setStroke()
        for row in spec.rows {
            let y = row.y - spec.y
            var x: CGFloat = 0
            for w in columnWidths {
                let cell = NSBezierPath(rect: CGRect(x: x + 0.5, y: y + 0.5, width: w - 1, height: row.height))
                cell.lineWidth = 1
                cell.stroke()
                x += w
            }
        }
    }

    /// GFM column alignment applied to a cell's text.
    static func aligned(_ text: NSAttributedString, _ alignment: ColumnAlignment) -> NSAttributedString {
        guard alignment != .none, text.length > 0 else { return text }
        let styled = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment == .center ? .center : alignment == .right ? .right : .left
        style.lineBreakMode = .byTruncatingTail
        styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
        return styled
    }

    private func drawRepeatedHeaderText(block: TableMutator.Block) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for row in spec.rows where row.isRepeatedHeader {
            var x: CGFloat = 0
            for c in 0..<max(1, block.columnCount) {
                let w = c < columnWidths.count ? columnWidths[c] : PagesTableView.minColumn
                let raw = c < (block.rows.first?.count ?? 0) ? block.rows[0][c] : ""
                let text = Self.aligned(CellMarkdown.attributed(raw, font: font, color: Theme.bodyColor(darkPaper: darkPaper), darkPaper: darkPaper,
                                                                base: parent?.documentDirectory, maxPictureWidth: parent?.pictureMaxWidth(c) ?? 200),
                                        c < block.alignments.count ? block.alignments[c] : .none)
                if text.length > 0 {
                    text.draw(
                        with: CGRect(x: x + PagesTableView.cellPadX, y: row.y - spec.y + 6, width: max(8, w - PagesTableView.cellPadX * 2), height: max(16, row.height - 12)),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
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
        let tableW = max(8, columnWidths.reduce(0, +))
        for row in spec.rows {
            let y = row.y - spec.y
            let rect = toPage(CGRect(x: 0, y: y, width: tableW, height: row.height))
            guard rect.intersects(paper) else { continue }
            (Self.isStriped(row.storageRow) ? Theme.tableHeaderFill(darkPaper: darkPaper) : Theme.paperColor(darkPaper: darkPaper)).setFill()
            rect.fill()
            Theme.tableBorder(darkPaper: darkPaper).setStroke()
            var cx: CGFloat = 0
            for w in columnWidths {
                NSBezierPath(rect: toPage(CGRect(x: cx + 0.5, y: y + 0.5, width: w - 1, height: row.height))).stroke()
                cx += w
            }
            let font: NSFont = row.storageRow == 0
                ? .systemFont(ofSize: 12, weight: .semibold)
                : .systemFont(ofSize: 12, weight: .regular)
            var x: CGFloat = 0
            for c in 0..<max(1, block.columnCount) {
                let w = c < columnWidths.count ? columnWidths[c] : PagesTableView.minColumn
                let raw = row.storageRow < block.rows.count && c < block.rows[row.storageRow].count
                    ? block.rows[row.storageRow][c]
                    : ""
                let text = Self.aligned(CellMarkdown.attributed(raw, font: font, color: Theme.bodyColor(darkPaper: darkPaper), darkPaper: darkPaper,
                                                                base: parent?.documentDirectory, maxPictureWidth: parent?.pictureMaxWidth(c) ?? 200),
                                        c < block.alignments.count ? block.alignments[c] : .none)
                if text.length > 0 {
                    let cell = toPage(CGRect(
                        x: x + PagesTableView.cellPadX,
                        y: y + 6,
                        width: max(8, w - PagesTableView.cellPadX * 2),
                        height: max(16, row.height - 12)
                    ))
                    text.draw(with: cell, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
                x += w
            }
        }
    }
}
