import AppKit
import MarkaCore

@MainActor
protocol TableOverlayDelegate: AnyObject {
    func tableOverlay(_ view: TableOverlayView, commit row: Int, column: Int, text: String)
    func tableOverlay(_ view: TableOverlayView, insertRow placement: RowPlacement)
    func tableOverlay(_ view: TableOverlayView, insertColumn placement: ColumnPlacement)
    func tableOverlayDeleteRow(_ view: TableOverlayView)
    func tableOverlayDeleteColumn(_ view: TableOverlayView)
    func tableOverlayDeleteTable(_ view: TableOverlayView)
    func tableOverlayDidChangeFocus(_ view: TableOverlayView)
}

/// GitHub-style editable Markdown table sitting on top of the hidden source.
final class TableOverlayView: NSView, NSTextFieldDelegate {
    weak var tableDelegate: TableOverlayDelegate?
    private(set) var block: TableMutator.Block
    private(set) var selectedRow = 2
    private(set) var selectedColumn = 0
    var darkPaper = false
    private var fields: [[NSTextField]] = []
    private var columnWidths: [CGFloat] = []
    static let rowHeight: CGFloat = 34
    private var rowHeight: CGFloat { Self.rowHeight }
    private var flow: PageLayout.TableFlow?
    private let addRowButton = TableEdgeChip(kind: .add)
    private let addColumnButton = TableEdgeChip(kind: .add)
    private let deleteRowButton = TableEdgeChip(kind: .remove)
    private let deleteColumnButton = TableEdgeChip(kind: .remove)

    static let chipSize: CGFloat = 22
    static let edgeInset: CGFloat = 11
    static let cellPadX: CGFloat = 13
    static let minColumn: CGFloat = 72
    var leftHandlePadding: CGFloat { Self.edgeInset }
    var tableBodyOriginY: CGFloat { Self.edgeInset }
    var bottomHandlePadding: CGFloat { Self.edgeInset }

    static func storageRows(for block: TableMutator.Block) -> [Int] {
        var rows = [0]
        if block.rows.count > 2 {
            rows.append(contentsOf: 2..<block.rows.count)
        }
        return rows
    }

    override var isFlipped: Bool { true }

    init(block: TableMutator.Block, darkPaper: Bool) {
        self.block = block
        self.darkPaper = darkPaper
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        buildHandles()
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
        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    var paginationHeight: CGFloat {
        guard let flow else {
            return tableBodyOriginY + CGFloat(visibleRowCount) * rowHeight + 1 + bottomHandlePadding
        }
        return max(rowHeight, flow.endY - flow.startY)
    }

    var paginationSpacing: CGFloat {
        flow?.contentHeight ?? paginationHeight
    }

    func preferredSize(fitting width: CGFloat) -> CGSize {
        measureColumns(maxWidth: max(40, width - Self.edgeInset * 2))
        return CGSize(width: width, height: paginationHeight)
    }

    var storageRowsForFlow: [Int] { Self.storageRows(for: block) }

    private var rowPlacements: [PageLayout.TableFlow.Row] {
        if let flow, !flow.rows.isEmpty {
            return flow.rows.map { row in
                var local = row
                local.y = row.y - flow.startY
                return local
            }
        }
        return (0..<visibleRowCount).map { display in
            PageLayout.TableFlow.Row(
                storageRow: storageRow(forDisplay: display),
                y: tableBodyOriginY + CGFloat(display) * rowHeight,
                page: 0,
                isRepeatedHeader: false
            )
        }
    }

    private func primaryPlacement(for storageRow: Int) -> PageLayout.TableFlow.Row? {
        rowPlacements.first(where: { $0.storageRow == storageRow && !$0.isRepeatedHeader })
            ?? rowPlacements.first(where: { $0.storageRow == storageRow })
    }

    private var visibleRowCount: Int {
        max(1, block.rows.count - 1) // skip separator
    }

    private func displayRowIndex(_ storageRow: Int) -> Int? {
        if storageRow == 0 { return 0 }
        if storageRow >= 2 { return storageRow - 1 }
        return nil
    }

    private func storageRow(forDisplay display: Int) -> Int {
        display == 0 ? 0 : display + 1
    }

    private func buildHandles() {
        configureChip(addRowButton, tooltip: "Add row", action: #selector(rowBelow))
        configureChip(addColumnButton, tooltip: "Add column", action: #selector(colRight))
        configureChip(deleteRowButton, tooltip: "Delete row", action: #selector(delRow), destructive: true)
        configureChip(deleteColumnButton, tooltip: "Delete column", action: #selector(delCol), destructive: true)
        addSubview(addRowButton)
        addSubview(addColumnButton)
        addSubview(deleteRowButton)
        addSubview(deleteColumnButton)
    }

    private func configureChip(_ chip: TableEdgeChip, tooltip: String, action: Selector, destructive: Bool = false) {
        chip.toolTip = tooltip
        chip.target = self
        chip.action = action
        chip.destructive = destructive
        chip.darkPaper = darkPaper
    }

    private func rebuild() {
        fields.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        fields = []
        let cols = max(1, block.columnCount)
        let displayRows = visibleRowCount
        for r in 0..<displayRows {
            var rowFields: [NSTextField] = []
            let storageRow = storageRow(forDisplay: r)
            for c in 0..<cols {
                let field = NSTextField()
                field.isBordered = false
                field.drawsBackground = false
                field.focusRingType = .none
                field.font = r == 0
                    ? .systemFont(ofSize: 12.5, weight: .semibold)
                    : .systemFont(ofSize: 12.5, weight: .regular)
                field.textColor = Theme.bodyColor(darkPaper: darkPaper)
                field.delegate = self
                field.lineBreakMode = .byTruncatingTail
                field.cell?.wraps = false
                field.tag = storageRow * 1000 + c
                let value = storageRow < block.rows.count && c < block.rows[storageRow].count
                    ? block.rows[storageRow][c]
                    : ""
                field.stringValue = value.trimmingCharacters(in: .whitespaces)
                field.placeholderString = r == 0 ? "Header" : ""
                addSubview(field)
                rowFields.append(field)
            }
            fields.append(rowFields)
        }
        needsLayout = true
        needsDisplay = true
    }

    private func measureColumns(maxWidth: CGFloat) {
        let cols = max(1, block.columnCount)
        var widths = Array(repeating: Self.minColumn, count: cols)
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        for row in block.rows.enumerated() where row.offset != 1 {
            for (c, cell) in row.element.enumerated() where c < cols {
                let text = cell.trimmingCharacters(in: .whitespaces) as NSString
                let w = text.size(withAttributes: [.font: font]).width + Self.cellPadX * 2
                widths[c] = max(widths[c], min(w, maxWidth * 0.6))
            }
        }
        let total = widths.reduce(0, +)
        if total < maxWidth {
            let extra = maxWidth - total
            let each = extra / CGFloat(cols)
            widths = widths.map { $0 + each }
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
        let tableX = leftHandlePadding
        let tableW = max(40, bounds.width - leftHandlePadding * 2)
        measureColumns(maxWidth: tableW)
        addRowButton.darkPaper = darkPaper
        addColumnButton.darkPaper = darkPaper
        deleteRowButton.darkPaper = darkPaper
        deleteColumnButton.darkPaper = darkPaper
        let placements = rowPlacements
        let selectedPlacement = primaryPlacement(for: selectedRow) ?? placements.first
        let selectedY = selectedPlacement?.y ?? tableBodyOriginY
        let lastBottom = placements.last.map { $0.y + rowHeight } ?? (tableBodyOriginY + rowHeight)
        let piece = chromeRects().first(where: { $0.minY - 1 <= selectedY && selectedY <= $0.maxY + 1 })
            ?? chromeRects().first
            ?? CGRect(x: tableX, y: tableBodyOriginY, width: tableW, height: rowHeight)
        let chip = Self.chipSize
        addColumnButton.frame = CGRect(
            x: tableX + tableW - chip / 2,
            y: piece.midY - chip / 2,
            width: chip,
            height: chip
        )
        addRowButton.frame = CGRect(
            x: tableX + max(0, (tableW - chip) / 2),
            y: lastBottom - chip / 2,
            width: chip,
            height: chip
        )
        deleteRowButton.toolTip = (selectedRow <= 1 || block.dataRowCount <= 1) ? "Delete table" : "Delete row"
        deleteRowButton.frame = CGRect(
            x: tableX - chip / 2,
            y: selectedY + max(0, (rowHeight - chip) / 2),
            width: chip,
            height: chip
        )
        var colX = tableX
        for i in 0..<selectedColumn where i < columnWidths.count {
            colX += columnWidths[i]
        }
        let colW = selectedColumn < columnWidths.count ? columnWidths[selectedColumn] : Self.minColumn
        deleteColumnButton.toolTip = block.columnCount <= 1 ? "Delete table" : "Delete column"
        deleteColumnButton.frame = CGRect(
            x: colX + max(0, (colW - chip) / 2),
            y: selectedY - chip / 2,
            width: chip,
            height: chip
        )
        for (r, rowFields) in fields.enumerated() {
            let storage = storageRow(forDisplay: r)
            let y = primaryPlacement(for: storage)?.y ?? tableBodyOriginY + CGFloat(r) * rowHeight
            var x: CGFloat = tableX
            for (c, field) in rowFields.enumerated() {
                let w = c < columnWidths.count ? columnWidths[c] : Self.minColumn
                field.frame = CGRect(
                    x: x + Self.cellPadX - 2,
                    y: y + 7,
                    width: max(24, w - Self.cellPadX * 2 + 4),
                    height: 20
                )
                x += w
            }
        }
    }

    private var tableOriginY: CGFloat { tableBodyOriginY }

    func chromeRects() -> [CGRect] {
        let tableX = leftHandlePadding
        let tableW = max(8, bounds.width - leftHandlePadding * 2)
        var rects: [CGRect] = []
        for row in rowPlacements {
            if let last = rects.last, abs(last.maxY - row.y) < 1.5 {
                rects[rects.count - 1].size.height = row.y + rowHeight + 1 - last.minY
            } else {
                rects.append(CGRect(x: tableX, y: row.y, width: tableW, height: rowHeight + 1))
            }
        }
        return rects
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for handle in [addRowButton, addColumnButton, deleteRowButton, deleteColumnButton] where !handle.isHidden {
            if handle.frame.contains(local) { return handle }
        }
        let inRow = rowPlacements.contains { local.y >= $0.y && local.y <= $0.y + rowHeight && local.x >= leftHandlePadding }
        guard inRow else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let selectedLocal = primaryPlacement(for: selectedRow)?.y
        for rect in chromeRects() {
            drawTableChrome(in: rect, highlightSelection: true, selectedRowY: selectedLocal)
        }
        drawRepeatedHeaders()
    }

    private func drawRepeatedHeaders() {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        for row in rowPlacements where row.isRepeatedHeader {
            var x = leftHandlePadding
            for c in 0..<max(1, block.columnCount) {
                let w = c < columnWidths.count ? columnWidths[c] : Self.minColumn
                let raw = c < (block.rows.first?.count ?? 0) ? block.rows[0][c] : ""
                let text = raw.trimmingCharacters(in: .whitespaces) as NSString
                if text.length > 0 {
                    text.draw(
                        in: CGRect(x: x + Self.cellPadX, y: row.y + 8, width: max(8, w - Self.cellPadX * 2), height: 18),
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

    /// Chrome + cell glyphs for PDF/print. Toolbar is omitted.
    func drawExported(intoPage paper: CGRect, paperOnCanvas: CGRect) {
        let origin = frame.origin
        func toPage(_ local: CGRect) -> CGRect {
            CGRect(
                x: origin.x + local.minX - paperOnCanvas.minX,
                y: origin.y + local.minY - paperOnCanvas.minY,
                width: local.width,
                height: local.height
            )
        }
        for rect in chromeRects() {
            let drawn = toPage(rect)
            guard drawn.intersects(paper) else { continue }
            drawTableChrome(in: drawn, highlightSelection: false, selectedRowY: nil)
        }
        for row in rowPlacements {
            let font: NSFont = row.storageRow == 0
                ? .systemFont(ofSize: 12.5, weight: .semibold)
                : .systemFont(ofSize: 12.5, weight: .regular)
            var x = leftHandlePadding
            for c in 0..<max(1, block.columnCount) {
                let w = c < columnWidths.count ? columnWidths[c] : Self.minColumn
                let raw = row.storageRow < block.rows.count && c < block.rows[row.storageRow].count
                    ? block.rows[row.storageRow][c]
                    : ""
                let text = raw.trimmingCharacters(in: .whitespaces) as NSString
                if text.length > 0 {
                    let cell = toPage(CGRect(
                        x: x + Self.cellPadX,
                        y: row.y + 8,
                        width: max(8, w - Self.cellPadX * 2),
                        height: 18
                    ))
                    guard cell.intersects(paper) else {
                        x += w
                        continue
                    }
                    text.draw(
                        in: cell,
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

    private func drawTableChrome(in tableRect: CGRect, highlightSelection: Bool, selectedRowY: CGFloat?) {
        let tableY = tableRect.minY
        let path = NSBezierPath(roundedRect: tableRect, xRadius: 6, yRadius: 6)
        Theme.paperColor(darkPaper: darkPaper).setFill()
        path.fill()
        Theme.tableBorder(darkPaper: darkPaper).setStroke()
        path.lineWidth = 1
        path.stroke()

        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        let header = CGRect(x: tableRect.minX, y: tableY, width: tableRect.width, height: min(rowHeight, tableRect.height))
        Theme.tableHeaderFill(darkPaper: darkPaper).setFill()
        header.fill()

        Theme.tableBorder(darkPaper: darkPaper).setStroke()
        let rows = max(1, Int(round((tableRect.height - 1) / rowHeight)))
        for r in 0...rows {
            let y = tableY + CGFloat(r) * rowHeight
            guard y <= tableRect.maxY + 0.5 else { break }
            let line = NSBezierPath()
            line.move(to: CGPoint(x: tableRect.minX, y: y + 0.5))
            line.line(to: CGPoint(x: tableRect.maxX, y: y + 0.5))
            line.lineWidth = 1
            line.stroke()
        }
        var x = tableRect.minX
        for (i, w) in columnWidths.enumerated() {
            if i > 0 {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: x + 0.5, y: tableY))
                line.line(to: CGPoint(x: x + 0.5, y: tableRect.maxY))
                line.lineWidth = 1
                line.stroke()
            }
            x += w
        }

        if highlightSelection, selectedRow != 1, let selectedRowY, selectedColumn < columnWidths.count,
           selectedRowY + 1 >= tableRect.minY, selectedRowY < tableRect.maxY {
            var hx = tableRect.minX
            for i in 0..<selectedColumn { hx += columnWidths[i] }
            let highlight = CGRect(
                x: hx + 1,
                y: selectedRowY + 1,
                width: columnWidths[selectedColumn] - 2,
                height: rowHeight - 2
            )
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 3, yRadius: 3).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    func focusCell(row: Int, column: Int, stealFocus: Bool = true) {
        selectedRow = row
        selectedColumn = column
        if stealFocus,
           let display = displayRowIndex(row),
           display < fields.count,
           column < fields[display].count {
            let field = fields[display][column]
            if window?.firstResponder !== field {
                window?.makeFirstResponder(field)
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    func addColumnChipHitTest(in canvas: NSView) -> Bool {
        let point = addColumnButton.convert(
            NSPoint(x: addColumnButton.bounds.midX, y: addColumnButton.bounds.midY),
            to: canvas
        )
        return canvas.hitTest(point) === addColumnButton
    }

    func chipsSitOnEdges() -> Bool {
        let tableX = leftHandlePadding
        let tableW = max(8, bounds.width - leftHandlePadding * 2)
        let right = tableX + tableW
        let lastBottom = rowPlacements.last.map { $0.y + rowHeight } ?? (tableBodyOriginY + rowHeight)
        let selectedY = primaryPlacement(for: selectedRow)?.y ?? tableBodyOriginY
        let onRight = abs(addColumnButton.frame.midX - right) < 1.5
        let onBottom = abs(addRowButton.frame.midY - lastBottom) < 1.5
        let onLeft = abs(deleteRowButton.frame.midX - tableX) < 1.5
        let onTop = abs(deleteColumnButton.frame.midY - selectedY) < 1.5
        return onRight && onBottom && onLeft && onTop
    }

    func chipIdleAlphaIsTranslucent() -> Bool {
        addColumnButton.idleFillAlpha < 0.7 && addColumnButton.idleFillAlpha > 0.3
    }

    var storageRowCount: Int { block.rows.count }
    var storageColumnCount: Int { block.columnCount }
    var hasFieldFocus: Bool { containsResponder(window?.firstResponder) }

    func clickAddRow() { rowBelow() }
    func clickAddColumn() { colRight() }
    func clickDeleteRow() { delRow() }
    func clickDeleteColumn() { delCol() }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        selectedRow = field.tag / 1000
        selectedColumn = field.tag % 1000
        needsLayout = true
        needsDisplay = true
        tableDelegate?.tableOverlayDidChangeFocus(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = field.tag / 1000
        let col = field.tag % 1000
        tableDelegate?.tableOverlay(self, commit: row, column: col, text: field.stringValue)
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
        guard let display = displayRowIndex(selectedRow),
              display < fields.count,
              selectedColumn < fields[display].count else { return }
        let field = fields[display][selectedColumn]
        tableDelegate?.tableOverlay(self, commit: selectedRow, column: selectedColumn, text: field.stringValue)
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
                tableDelegate?.tableOverlay(self, insertRow: .below)
                return
            }
            col = 0
            row += (row <= 1 ? 2 : 1)
        }
        if col < 0 { col = block.columnCount - 1; row = row <= 2 ? 0 : row - 1 }
        if rowDelta > 0, row > block.rows.count - 1 {
            tableDelegate?.tableOverlay(self, insertRow: .below)
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

    @objc private func rowAbove() { tableDelegate?.tableOverlay(self, insertRow: .above) }
    @objc private func rowBelow() { tableDelegate?.tableOverlay(self, insertRow: .below) }
    @objc private func colLeft() { tableDelegate?.tableOverlay(self, insertColumn: .left) }
    @objc private func colRight() { tableDelegate?.tableOverlay(self, insertColumn: .right) }
    @objc private func delRow() { tableDelegate?.tableOverlayDeleteRow(self) }
    @objc private func delCol() { tableDelegate?.tableOverlayDeleteColumn(self) }
    @objc private func delTable() { tableDelegate?.tableOverlayDeleteTable(self) }
}

/// Semi-transparent +/− chip that sits on a table grid line.
final class TableEdgeChip: NSButton {
    enum Kind { case add, remove }
    let kind: Kind
    var darkPaper = false
    var destructive = false
    private var hovered = false
    var idleFillAlpha: CGFloat { 0.52 }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        image = nil
        title = ""
        focusRingType = .none
        refusesFirstResponder = true
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow?.shadowBlurRadius = 5
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
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
        let alpha: CGFloat = hovered ? 0.92 : idleFillAlpha
        let fill = darkPaper
            ? NSColor.black.withAlphaComponent(alpha)
            : NSColor.white.withAlphaComponent(alpha)
        let chip = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        fill.setFill()
        chip.fill()
        NSColor.separatorColor.withAlphaComponent(hovered ? 0.5 : 0.28).setStroke()
        chip.lineWidth = 0.6
        chip.stroke()
        let ink: NSColor
        if destructive {
            ink = NSColor.systemRed.withAlphaComponent(hovered ? 0.95 : 0.8)
        } else {
            ink = (darkPaper ? NSColor.white : NSColor(white: 0.22, alpha: 1))
                .withAlphaComponent(hovered ? 0.95 : 0.8)
        }
        ink.setStroke()
        let cx = bounds.midX
        let cy = bounds.midY
        let arm: CGFloat = 4.4
        let stroke = NSBezierPath()
        stroke.lineWidth = 1.6
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
