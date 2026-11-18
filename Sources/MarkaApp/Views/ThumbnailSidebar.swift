import AppKit
import MarkaCore

final class ThumbnailSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var pageCount = 1
    var currentPage = 0
    var provider: ((Int) -> NSImage?)?
    var onSelectPage: ((Int) -> Void)?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var debounce: DispatchWorkItem?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.width = 110
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 148
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 8)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSView()
        let imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.borderWidth = row == currentPage ? 2 : 1
        imageView.layer?.borderColor = (row == currentPage ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        imageView.layer?.cornerRadius = 3
        imageView.image = provider?(row)
        let label = NSTextField(labelWithString: "\(row + 1)")
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            imageView.heightAnchor.constraint(equalToConstant: 120),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 2),
            label.centerXAnchor.constraint(equalTo: cell.centerXAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        currentPage = row
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
