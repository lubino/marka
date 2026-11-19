import AppKit
import MarkaCore

/// A4 page chip: white paper only, no grey frame around it.
///
/// Everything here is plain layer properties (contents, background, corner radius, shadow *with* a
/// `shadowPath`) so resizing the sidebar only moves/scales layers on the GPU — no `draw(_:)`, no
/// offscreen shadow pass, no bitmap re-render per frame.
final class ThumbnailPageCell: NSView {
    private let selectionView = NSView()
    private let sheet = NSView()
    private let pageView = NSView()
    private let numberLabel = NSTextField(labelWithString: "")
    private var selected = false
    private static let paper = PageGeometry.a4PaperSize
    static let topInset: CGFloat = 10
    static let labelHeight: CGFloat = 16
    static let selectionOutset: CGFloat = 5
    static let selectionCornerRadius: CGFloat = 10
    static let numberGap: CGFloat = 4

    static func horizontalInset(forWidth width: CGFloat) -> CGFloat {
        min(22, max(12, width * 0.12))
    }

    /// Overlay scrollers float over the cells, so the whole row width is usable.
    static func usableWidth(in bounds: CGRect) -> CGFloat {
        max(48, bounds.width)
    }

    static func pageWidth(forRowWidth width: CGFloat) -> CGFloat {
        let usable = max(48, width)
        return max(48, usable - horizontalInset(forWidth: usable) * 2)
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false

        selectionView.wantsLayer = true
        selectionView.layer?.cornerRadius = Self.selectionCornerRadius
        selectionView.isHidden = true

        sheet.wantsLayer = true
        sheet.layer?.masksToBounds = false
        sheet.layer?.shadowColor = NSColor.black.cgColor
        sheet.layer?.shadowOpacity = 0.12
        sheet.layer?.shadowRadius = 1.5
        sheet.layer?.shadowOffset = CGSize(width: 0, height: -1)

        pageView.wantsLayer = true
        pageView.layerContentsRedrawPolicy = .never
        pageView.layer?.backgroundColor = NSColor.white.cgColor
        pageView.layer?.cornerRadius = 2
        pageView.layer?.masksToBounds = true
        pageView.layer?.borderWidth = 0
        pageView.layer?.contentsGravity = .resize
        pageView.layer?.minificationFilter = .trilinear
        pageView.layer?.magnificationFilter = .linear

        numberLabel.alignment = .center
        numberLabel.font = .systemFont(ofSize: 11)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.isBezeled = false
        numberLabel.drawsBackground = false

        sheet.addSubview(pageView)
        addSubview(selectionView)
        addSubview(sheet)
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: CGImage?, page: Int, selected: Bool) {
        setImage(image)
        numberLabel.stringValue = "\(page + 1)"
        setSelected(selected)
    }

    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageView.layer?.contents = image
        CATransaction.commit()
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        selectionView.isHidden = !selected
        updateSelectionColor()
    }

    var isPageSelected: Bool { selected }

    private func updateSelectionColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        selectionView.layer?.backgroundColor = Theme.thumbnailSelectionFill(darkPaper: dark).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionColor()
    }

    var pageRect: CGRect { Self.pageRect(in: bounds) }

    static func pageRect(in bounds: CGRect) -> CGRect {
        let usable = usableWidth(in: bounds)
        let width = pageWidth(forRowWidth: usable)
        let height = width * (paper.height / paper.width)
        let x = bounds.minX + (usable - width) / 2
        return CGRect(x: x, y: topInset, width: width, height: height)
    }

    static func rowHeight(forWidth width: CGFloat) -> CGFloat {
        let page = pageRect(in: CGRect(x: 0, y: 0, width: width, height: 10_000))
        return page.maxY + numberGap + labelHeight + selectionOutset + 6
    }

    var selectionRect: CGRect {
        let page = pageRect
        let top = page.minY - Self.selectionOutset
        let bottom = page.maxY + Self.numberGap + Self.labelHeight + Self.selectionOutset
        return CGRect(
            x: page.minX - Self.selectionOutset,
            y: top,
            width: page.width + Self.selectionOutset * 2,
            height: bottom - top
        )
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let page = pageRect
        sheet.frame = page
        pageView.frame = sheet.bounds
        sheet.layer?.shadowPath = CGPath(rect: CGRect(origin: .zero, size: page.size), transform: nil)
        selectionView.frame = selectionRect
        numberLabel.frame = CGRect(
            x: page.minX,
            y: page.maxY + Self.numberGap,
            width: page.width,
            height: Self.labelHeight
        )
        CATransaction.commit()
    }

    var testBorderWidth: CGFloat { pageView.layer?.borderWidth ?? -1 }
    var testSelectionCornerRadius: CGFloat { selected ? Self.selectionCornerRadius : 0 }
    var testSelectionUsesAccentStroke: Bool { false }
    var testSelectionContainsNumber: Bool {
        selected && selectionRect.insetBy(dx: 1, dy: 1).intersects(numberLabel.frame)
    }
    var testHasImage: Bool { pageView.layer?.contents != nil }
}

/// Preview-style thumbnail pane.
///
/// Smooth resizing strategy:
/// 1. Uniform `rowHeight` (no `heightOfRow` delegate) — a width change re-tiles in O(visible rows).
/// 2. Rendered page bitmaps are cached per page and only *scaled* while the pane is resized.
/// 3. Re-rendering happens after the resize settles, only for visible rows, only when the cached
///    bitmap is too small (blurry) or far too large, in small time-boxed batches.
/// 4. Content edits bump a generation; cells keep showing the old bitmap until the new one is ready,
///    so thumbnails never flash blank.
final class ThumbnailSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        var image: CGImage
        var width: CGFloat
        var generation: Int
    }

    var pageCount = 1
    var currentPage = 0
    /// Renders page `index` at `size` (points; the renderer adds Retina pixels).
    var provider: ((Int, CGSize) -> NSImage?)?
    var onSelectPage: ((Int) -> Void)?
    private(set) var renderCount = 0
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var debounce: DispatchWorkItem?
    private var isSyncingSelection = false
    private var cache: [Int: Entry] = [:]
    private var generation = 0
    private var renderScheduled = false
    private var isLiveResizing = false
    private var lastWidthChange: TimeInterval = 0
    private var lastRowWidth: CGFloat = 0
    private var lastTopInset: CGFloat = 0
    private static let settleDelay: TimeInterval = 0.12
    private static let widthBucket: CGFloat = 16
    private static let frameBudget: TimeInterval = 0.008
    private static let keepAroundVisible = 8

    override var isFlipped: Bool { true }

    /// Width the rows actually get: the clip view, not the sidebar.
    private var rowWidth: CGFloat { max(48, scroll.contentSize.width) }

    /// Width (points) a bitmap is rendered at: the current page width rounded up to a bucket,
    /// so small drags reuse the same bitmaps.
    private var renderWidth: CGFloat {
        let width = ThumbnailPageCell.pageWidth(forRowWidth: rowWidth)
        return (width / Self.widthBucket).rounded(.up) * Self.widthBucket
    }

    var thumbnailImageSize: NSSize {
        let width = renderWidth
        let paper = PageGeometry.a4PaperSize
        return NSSize(width: width, height: (width * paper.height / paper.width).rounded())
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // No fill: the sidebar split item supplies the material (Liquid Glass on macOS 26+).
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.width = 110
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 160
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 10)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Full-height sidebar: the first page starts below the titlebar and scrolls under it.
        scroll.automaticallyAdjustsContentInsets = true
        scroll.autoresizingMask = [.width, .height]
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        clipsToBounds = true
        addSubview(scroll)
        scroll.frame = bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout / live resize

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.sizeLastColumnToFit()
        keepTopUnderInsetChange()
        let width = rowWidth
        guard abs(width - lastRowWidth) > 0.25 else { return }
        lastRowWidth = width
        lastWidthChange = ProcessInfo.processInfo.systemUptime
        let height = ThumbnailPageCell.rowHeight(forWidth: width)
        if abs(table.rowHeight - height) > 0.25 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                table.rowHeight = height
            }
        }
        scheduleRender(after: Self.settleDelay)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizing = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizing = false
        lastWidthChange = 0
        scheduleRender(after: 0)
    }

    @objc private func scrolled() {
        scheduleRender(after: 0)
    }

    // MARK: - Data

    func reload(pageCount: Int, currentPage: Int, debounce: Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = max(1, pageCount)
            let countChanged = count != self.pageCount
            self.pageCount = count
            self.currentPage = min(currentPage, count - 1)
            // Content changed: keep old bitmaps on screen, mark them stale.
            self.generation += 1
            self.cache = self.cache.filter { $0.key < count }
            if countChanged || self.table.numberOfRows != count {
                self.table.reloadData()
            }
            self.isSyncingSelection = true
            self.table.selectRowIndexes(IndexSet(integer: self.currentPage), byExtendingSelection: false)
            self.isSyncingSelection = false
            self.updateCellSelection()
            self.scheduleRender(after: 0)
        }
        self.debounce?.cancel()
        if debounce {
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            work.perform()
        }
    }

    /// Follow the page visible in the editor: move the highlight and keep that thumbnail in view.
    func showCurrentPage(_ page: Int) {
        let page = min(max(0, page), max(0, pageCount - 1))
        guard page != currentPage || table.selectedRow != page else { return }
        currentPage = page
        isSyncingSelection = true
        table.selectRowIndexes(IndexSet(integer: page), byExtendingSelection: false)
        isSyncingSelection = false
        updateCellSelection()
        if page < table.numberOfRows {
            scrollRowToVisibleRespectingInsets(page)
        }
    }

    /// The titlebar inset arrives after the first layout; a pane resting at the old top must move to
    /// the new top, or the first page hides under the window controls.
    private func keepTopUnderInsetChange() {
        let inset = scroll.contentInsets.top
        guard abs(inset - lastTopInset) > 0.5 else { return }
        let clip = scroll.contentView
        let wasAtTop = clip.bounds.minY <= -lastTopInset + 0.5
        lastTopInset = inset
        if wasAtTop {
            clip.scroll(to: NSPoint(x: 0, y: -inset))
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// `scrollRowToVisible` ignores content insets, so the row could end up under the titlebar.
    private func scrollRowToVisibleRespectingInsets(_ row: Int) {
        let clip = scroll.contentView
        let rect = table.rect(ofRow: row)
        let inset = scroll.contentInsets
        let visibleTop = clip.bounds.minY + inset.top
        let visibleBottom = clip.bounds.maxY - inset.bottom
        var y = clip.bounds.minY
        if rect.minY < visibleTop {
            y = rect.minY - inset.top
        } else if rect.maxY > visibleBottom {
            y = rect.maxY - clip.bounds.height + inset.bottom
        } else {
            return
        }
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func updateCellSelection() {
        for index in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThumbnailPageCell)?
                .setSelected(index == currentPage)
        }
    }

    // MARK: - Rendering

    private func needsRender(_ row: Int) -> Bool {
        guard let entry = cache[row] else { return true }
        if entry.generation != generation { return true }
        let target = renderWidth
        // Upscaling looks blurry; much larger bitmaps waste memory. In between, just scale.
        return entry.width < target - 0.5 || entry.width > target * 1.6
    }

    private var isResizing: Bool {
        isLiveResizing || ProcessInfo.processInfo.systemUptime - lastWidthChange < Self.settleDelay
    }

    private func scheduleRender(after delay: TimeInterval) {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.renderPass()
        }
    }

    private func visibleRows() -> [Int] {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return pageCount > 0 ? [0] : [] }
        let lower = max(0, range.location - 1)
        let upper = min(pageCount - 1, NSMaxRange(range))
        return lower <= upper ? Array(lower...upper) : []
    }

    private func renderPass() {
        if isResizing {
            scheduleRender(after: Self.settleDelay)
            return
        }
        guard provider != nil, window != nil || superview != nil else { return }
        let rows = visibleRows().filter(needsRender)
        let start = ProcessInfo.processInfo.systemUptime
        var rendered = 0
        for row in rows {
            render(row)
            rendered += 1
            if ProcessInfo.processInfo.systemUptime - start > Self.frameBudget { break }
        }
        evictFarRows()
        if rendered < rows.count {
            // Yield to the run loop so scrolling/typing stays responsive, then continue.
            scheduleRender(after: 0)
        }
    }

    private func render(_ row: Int) {
        guard let provider, row < pageCount else { return }
        let size = thumbnailImageSize
        guard let image = provider(row, size),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        renderCount += 1
        cache[row] = Entry(image: cg, width: size.width, generation: generation)
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailPageCell)?.setImage(cg)
    }

    private func evictFarRows() {
        let visible = table.rows(in: table.visibleRect)
        let lower = visible.location - Self.keepAroundVisible
        let upper = NSMaxRange(visible) + Self.keepAroundVisible
        cache = cache.filter { $0.key >= lower && $0.key <= upper }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { pageCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("page")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ThumbnailPageCell ?? ThumbnailPageCell()
        cell.identifier = id
        // Stale or differently sized bitmaps are fine to show; a fresh one follows.
        cell.configure(image: cache[row]?.image, page: row, selected: row == currentPage)
        if needsRender(row) {
            scheduleRender(after: isResizing ? Self.settleDelay : 0)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        currentPage = row
        updateCellSelection()
        // Programmatic sync from editor scrolling must not scroll the editor back.
        guard !isSyncingSelection else { return }
        onSelectPage?(row)
    }

    // MARK: - Testing

    private func firstCell() -> ThumbnailPageCell? {
        layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThumbnailPageCell else { return nil }
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    var testFirstPageBorderWidth: CGFloat { firstCell()?.testBorderWidth ?? -1 }

    var testFirstPageAspect: CGFloat {
        guard let cell = firstCell() else { return 0 }
        let page = cell.pageRect
        return page.width / max(page.height, 1)
    }

    var testFirstPageWidth: CGFloat { firstCell()?.pageRect.width ?? 0 }
    var testFirstPageHasImage: Bool { firstCell()?.testHasImage ?? false }
    var testSelectionCornerRadius: CGFloat { firstCell()?.testSelectionCornerRadius ?? 0 }
    var testSelectionUsesAccentStroke: Bool { firstCell()?.testSelectionUsesAccentStroke ?? true }
    var testSelectionContainsNumber: Bool { firstCell()?.testSelectionContainsNumber ?? false }

    var testPageCenteredInUsableWidth: Bool {
        guard let cell = firstCell() else { return false }
        let page = cell.pageRect
        let usable = ThumbnailPageCell.usableWidth(in: cell.bounds)
        return abs(page.midX - usable / 2) < 2
    }

    var testUsesSystemScrollerStyle: Bool { scroll.scrollerStyle == NSScroller.preferredScrollerStyle }

    /// How far the table is wider than its clip view (> 0 means it can scroll sideways).
    var testHorizontalOverflow: CGFloat {
        layoutSubtreeIfNeeded()
        return table.frame.width - scroll.contentView.bounds.width
    }

    func firstPageRectInView(_ view: NSView) -> CGRect {
        guard let cell = firstCell() else { return .zero }
        return cell.convert(cell.pageRect, to: view)
    }

    var testSelectedPage: Int { currentPage }
    var testHighlightedPages: [Int] {
        (0..<table.numberOfRows).filter { index in
            (table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ThumbnailPageCell)?.isPageSelected == true
        }
    }
}
