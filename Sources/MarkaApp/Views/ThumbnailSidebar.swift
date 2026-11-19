import AppKit
import MarkaCore

/// A4 page chip: white paper only, no grey frame around it.
final class ThumbnailPageCell: NSView {
    let pageView = NSImageView()
    private let sheet = NSView()
    private let numberLabel = NSTextField(labelWithString: "")
    private var selected = false
    private static let paper = PageGeometry.a4PaperSize
    static let horizontalInset: CGFloat = 12
    static let topInset: CGFloat = 8
    static let labelHeight: CGFloat = 18

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        sheet.wantsLayer = true
        sheet.layer?.masksToBounds = false
        sheet.shadow = NSShadow()
        sheet.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.16)
        sheet.shadow?.shadowBlurRadius = 5
        sheet.shadow?.shadowOffset = NSSize(width: 0, height: 1)
        pageView.imageScaling = .scaleAxesIndependently
        pageView.imageAlignment = .alignCenter
        pageView.wantsLayer = true
        pageView.layer?.masksToBounds = true
        pageView.layer?.cornerRadius = 2
        pageView.layer?.backgroundColor = NSColor.white.cgColor
        pageView.layer?.borderWidth = 0
        numberLabel.alignment = .center
        numberLabel.font = .systemFont(ofSize: 11)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.isBezeled = false
        numberLabel.drawsBackground = false
        sheet.addSubview(pageView)
        addSubview(sheet)
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: NSImage?, page: Int, selected: Bool) {
        pageView.image = image
        numberLabel.stringValue = "\(page + 1)"
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        needsDisplay = true
    }

    var pageRect: CGRect { Self.pageRect(in: bounds) }

    static func pageRect(in bounds: CGRect) -> CGRect {
        let maxWidth = max(48, bounds.width - horizontalInset * 2)
        let height = maxWidth * (paper.height / paper.width)
        let x = bounds.minX + (bounds.width - maxWidth) / 2
        return CGRect(x: x, y: topInset, width: maxWidth, height: height)
    }

    static func rowHeight(forWidth width: CGFloat) -> CGFloat {
        let page = pageRect(in: CGRect(x: 0, y: 0, width: width, height: 10_000))
        return page.maxY + labelHeight + 4
    }

    override func layout() {
        super.layout()
        let page = pageRect
        sheet.frame = page
        pageView.frame = sheet.bounds
        numberLabel.frame = CGRect(x: 0, y: page.maxY + 2, width: bounds.width, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard selected else { return }
        let ring = pageRect.insetBy(dx: -2.5, dy: -2.5)
        let path = NSBezierPath(roundedRect: ring, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    var testBorderWidth: CGFloat { pageView.layer?.borderWidth ?? -1 }
}

final class ThumbnailSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var pageCount = 1
    var currentPage = 0
    var provider: ((Int) -> NSImage?)?
    var onSelectPage: ((Int) -> Void)?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var debounce: DispatchWorkItem?

    override var isFlipped: Bool { true }

    var thumbnailImageSize: NSSize {
        let width = max(72, bounds.width - ThumbnailPageCell.horizontalInset * 2)
        let paper = PageGeometry.a4PaperSize
        return NSSize(width: width, height: width * (paper.height / paper.width))
    }

    var testFirstPageBorderWidth: CGFloat {
        (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThumbnailPageCell)?.testBorderWidth ?? -1
    }

    var testFirstPageAspect: CGFloat {
        guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThumbnailPageCell else { return 0 }
        let page = cell.pageRect
        return page.width / max(page.height, 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.width = 110
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 160
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 6)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        clipsToBounds = true
        addSubview(scroll)
        scroll.frame = bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.tableColumns.first?.width = max(80, bounds.width - 16)
        let height = ThumbnailPageCell.rowHeight(forWidth: bounds.width)
        if abs(table.rowHeight - height) > 0.5 {
            table.rowHeight = height
            if pageCount > 0 {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<pageCount))
            }
        }
    }

    func reload(pageCount: Int, currentPage: Int, debounce: Bool) {
        self.pageCount = max(1, pageCount)
        self.currentPage = currentPage
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.table.reloadData()
            self.table.selectRowIndexes(IndexSet(integer: self.currentPage), byExtendingSelection: false)
        }
        self.debounce?.cancel()
        if debounce {
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            work.perform()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pageCount }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        ThumbnailPageCell.rowHeight(forWidth: bounds.width)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("page")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ThumbnailPageCell ?? ThumbnailPageCell()
        cell.identifier = id
        cell.configure(image: provider?(row), page: row, selected: row == currentPage)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        currentPage = row
        for index in 0..<pageCount {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThumbnailPageCell)?
                .setSelected(index == currentPage)
        }
        onSelectPage?(row)
    }
}

final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    func update(page: Int, pageCount: Int, words: Int, characters: Int, path: String) {
        let displayPath = path.isEmpty ? "Untitled" : path
        label.stringValue = "Page \(page) / \(pageCount)  ·  \(words) words  ·  \(characters) characters  ·  \(displayPath)"
    }
}
