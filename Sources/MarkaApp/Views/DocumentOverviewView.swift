import AppKit
import MarkaCore

/// Everything a link can point to — the document's headings (GitHub `#anchors`) and the files
/// around it — with a filter field. From the link card a pick sets the link; from the page
/// popover it navigates (quick jump).
final class DocumentOverviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    enum Item: Equatable {
        case section(String)
        case heading(HeadingAnchor)
        case file(URL, relative: String)

        var isSelectable: Bool {
            if case .section = self { return false }
            return true
        }
    }

    var onPick: ((Item) -> Void)?
    weak var popover: NSPopover?
    private let allItems: [Item]
    private var shown: [Item] = []
    private let navigation: Bool
    private let search = NSSearchField()
    private let table = OverviewTableView()
    static let size = NSSize(width: 460, height: 440)
    private let emptyLabel = NSTextField(labelWithString: "No matches")

    /// `navigation`: titles say "Go to"; otherwise "Link to".
    init(headings: [HeadingAnchor], files: [(URL, String)], navigation: Bool) {
        var items: [Item] = []
        if !headings.isEmpty {
            items.append(.section("Headings"))
            items += headings.map { Item.heading($0) }
        }
        let markdown = files.filter { Hyperlink.markdownExtensions.contains($0.0.pathExtension.lowercased()) }
        let images = files.filter { MarkdownTextView.imageExtensions.contains($0.0.pathExtension.lowercased()) }
        let others = files.filter { file in !markdown.contains { $0.0 == file.0 } && !images.contains { $0.0 == file.0 } }
        for (title, group) in [("Documents", markdown), ("Images", images), ("Other files", others)] where !group.isEmpty {
            items.append(.section(title))
            items += group.map { Item.file($0.0, relative: $0.1) }
        }
        allItems = items
        self.navigation = navigation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: navigation ? "Go to" : "Link to")
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        search.placeholderString = "Filter headings and files"
        search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.floatsGroupRows = false
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.isClickableRow = { [weak self] row in
            guard let self, row >= 0, row < self.shown.count else { return false }
            return self.shown[row].isSelectable
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        // Scrolling moves rows under a still pointer: re-hover from the pointer's position.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)
        let empty = allItems.isEmpty
        let hint = NSTextField(labelWithString: empty
            ? "Nothing to link to yet — add headings or save the document."
            : "↑ ↓  move     ↩  \(navigation ? "go there" : "link to it")     esc  close")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let footerLine = NSBox()
        footerLine.boxType = .separator
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        let stack = NSStackView(views: [title, search, scroll, footerLine, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(6, after: footerLine)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 40),
            container.widthAnchor.constraint(equalToConstant: Self.size.width),
            container.heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
        view = container
        preferredContentSize = Self.size
        filter("")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    // MARK: Filtering

    func controlTextDidChange(_ obj: Notification) { filter(search.stringValue) }

    /// Return picks the selected (or first) item; ↑ / ↓ move through the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let row = table.selectedRow >= 0 ? table.selectedRow : shown.firstIndex { $0.isSelectable } ?? -1
            pick(row)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // esc: clear the filter first, then close.
            if search.stringValue.isEmpty {
                popover?.performClose(nil)
            } else {
                search.stringValue = ""
                filter("")
            }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            moveSelection(selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ step: Int) {
        var row = table.selectedRow
        repeat { row += step } while row >= 0 && row < shown.count && !shown[row].isSelectable
        guard row >= 0, row < shown.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func filter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            shown = allItems
            table.reloadData()
            emptyLabel.isHidden = true
            return
        }
        var result: [Item] = []
        var section: Item?
        for item in allItems {
            switch item {
            case .section:
                section = item
            case .heading(let anchor):
                if anchor.title.lowercased().contains(q) || anchor.slug.contains(q) {
                    if let s = section { result.append(s); section = nil }
                    result.append(item)
                }
            case .file(_, let relative):
                if relative.lowercased().contains(q) {
                    if let s = section { result.append(s); section = nil }
                    result.append(item)
                }
            }
        }
        shown = result
        table.reloadData()
        emptyLabel.isHidden = !result.isEmpty
        if let first = shown.firstIndex(where: { $0.isSelectable }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { !shown[row].isSelectable }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { shown[row].isSelectable }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        shown[row].isSelectable ? 28 : (row == 0 ? 22 : 30)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = OverviewRowView()
        view.isClickable = shown[row].isSelectable
        view.hovering = row == table.hoveredRow
        return view
    }

    /// One line per item: icon · title (indented by heading level) · grey detail on the right
    /// (the #anchor, or the file's folder).
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        switch shown[row] {
        case .section(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)
            ])
            return cell
        case .heading(let anchor):
            fill(cell, symbol: "number", title: anchor.title, detail: "#" + anchor.slug,
                 indent: CGFloat(max(0, anchor.level - 1)) * 14, strong: anchor.level <= 2)
        case .file(let url, let relative):
            let ext = url.pathExtension.lowercased()
            let symbol = Hyperlink.markdownExtensions.contains(ext) ? "doc.text"
                : MarkdownTextView.imageExtensions.contains(ext) ? "photo" : "doc"
            let folder = (relative as NSString).deletingLastPathComponent
            fill(cell, symbol: symbol, title: url.lastPathComponent, detail: folder, indent: 0, strong: false)
        }
        return cell
    }

    private func fill(_ cell: NSTableCellView, symbol: String, title: String, detail: String, indent: CGFloat, strong: Bool) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: strong ? .medium : .regular)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        name.toolTip = title
        let extra = NSTextField(labelWithString: detail)
        extra.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        extra.textColor = .tertiaryLabelColor
        extra.lineBreakMode = .byTruncatingHead
        extra.maximumNumberOfLines = 1
        extra.alignment = .right
        extra.setContentCompressionResistancePriority(.defaultLow - 2, for: .horizontal)
        extra.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [icon, name, extra] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8 + indent),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            extra.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            extra.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            extra.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            extra.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, multiplier: 0.42)
        ])
    }

    @objc private func clicked() { pick(table.clickedRow) }

    @objc private func listScrolled() { table.refreshHoverFromPointer() }

    func pick(_ row: Int) {
        guard row >= 0, row < shown.count, shown[row].isSelectable else { return }
        onPick?(shown[row])
    }

    // Testing
    var testItems: [Item] { shown }
    /// Hover row `a`, then (as if the list scrolled under the pointer) row `b`: rows left hovered.
    func testHoverSequence(_ a: Int, _ b: Int) -> [Int] {
        _ = view
        view.frame = NSRect(origin: .zero, size: Self.size)
        view.layoutSubtreeIfNeeded()
        table.testHover(at: a)
        table.testHover(at: b)
        return table.testHoveredRows
    }

    /// Per row: does it show the pointing hand (clickable)?
    var testRowPointers: [Bool] {
        (0..<shown.count).map { (tableView(table, rowViewForRow: $0) as? OverviewRowView)?.testHasPointer ?? false }
    }
}

extension DocumentOverviewViewController {
    /// Files a link can point to, under `directory` (hidden folders, .git, node_modules and build
    /// output skipped; at most `limit`, shallow folders first).
    static func linkableFiles(in directory: URL, excluding current: URL?, limit: Int = 300) -> [(URL, String)] {
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv"]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [(URL, String)] = []
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) || enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory, url.standardizedFileURL != current?.standardizedFileURL else { continue }
            files.append((url, FileReference.relativeMarkdownPath(of: url, from: directory).removingPercentEncoding ?? url.lastPathComponent))
            if files.count >= limit { break }
        }
        return files.sorted { a, b in
            let da = a.1.components(separatedBy: "/").count, db = b.1.components(separatedBy: "/").count
            return da != db ? da < db : a.1.localizedStandardCompare(b.1) == .orderedAscending
        }
    }
}

/// The overview list: exactly one hovered row, following the pointer — also while the list
/// scrolls under a still pointer (row-level enter / exit events do not fire then, which left
/// several rows highlighted) — and the pointing hand over clickable rows.
final class OverviewTableView: NSTableView {
    var isClickableRow: ((Int) -> Bool)?
    private(set) var hoveredRow = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            if oldValue >= 0, oldValue < numberOfRows { (rowView(atRow: oldValue, makeIfNecessary: false) as? OverviewRowView)?.hovering = false }
            if hoveredRow >= 0, hoveredRow < numberOfRows { (rowView(atRow: hoveredRow, makeIfNecessary: false) as? OverviewRowView)?.hovering = true }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(windowPoint: event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { updateHover(windowPoint: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { updateHover(windowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        hoveredRow = -1
        NSCursor.arrow.set()
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
        refreshHoverFromPointer()
    }

    /// After scrolling (or reloading): whatever row is under the pointer now.
    func refreshHoverFromPointer() {
        guard let window else { return }
        updateHover(windowPoint: window.mouseLocationOutsideOfEventStream)
    }

    func updateHover(windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let row = visibleRect.contains(point) ? row(at: point) : -1
        let clickable = row >= 0 && (isClickableRow?(row) ?? true)
        hoveredRow = clickable ? row : -1
        if visibleRect.contains(point) { (clickable ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }

    // Testing
    func testHover(at row: Int) {
        guard row >= 0, row < numberOfRows else { hoveredRow = -1; return }
        hoveredRow = (isClickableRow?(row) ?? true) ? row : -1
    }
    var testHoveredRows: [Int] {
        (0..<numberOfRows).filter { (rowView(atRow: $0, makeIfNecessary: false) as? OverviewRowView)?.hovering == true }
    }
}

/// Overview row: draws the rounded hover / selection fill; the table decides which row is hovered.
final class OverviewRowView: NSTableRowView {
    var isClickable = true
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, isClickable, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        // A light accent fill keeps the dark title and grey detail readable.
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    var testHasPointer: Bool { isClickable }
}
