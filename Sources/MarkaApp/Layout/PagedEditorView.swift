import AppKit
import MarkaCore

final class PagedEditorView: NSView {
    let textView: MarkdownTextView
    var geometry: PageGeometry = .init()
    var darkPaper = false
    var horizontalPadding: CGFloat = PageGeometry.canvasPadding
    private(set) var pageCount = 1
    var codeHeaderCount: Int { codeHeaders.count }
    var codeBackgroundCount: Int { codeBackgrounds.count }
    var tableOverlayCount: Int { pagesTables.count }
    var onPagesChanged: ((Int) -> Void)?
    var onEditContextChanged: (() -> Void)?
    var documentDirectory: URL?
    private var imageOverlays: [NSImageView] = []
    private var codeBackgrounds: [CodeBlockBackgroundView] = []
    private var codeHeaders: [CodeBlockHeaderView] = []
    private var pagesTables: [PagesTableView] = []
    private let linkCard = LinkCardView(frame: .zero)
    private var relayoutQueued = false
    private var isRelayouting = false
    private var headingRuleSource: String?
    private var headingRuleRanges: [NSRange] = []
    private var tableFocus: (location: Int, row: Int, column: Int)?
    var pendingLinkCardFocus = false
    var isLinkCardVisible: Bool { linkCard.superview != nil }
    var linkCardURL: String { linkCard.url }

    override var isFlipped: Bool { true }

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(textView)
        linkCard.cardDelegate = self
        linkCard.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvasColor(darkPaper: darkPaper).setFill()
        dirtyRect.fill()
        for i in 0..<pageCount {
            let paper = PageLayout.paperRect(
                pageIndex: i,
                geometry: geometry,
                paddingX: horizontalPadding,
                paddingY: PageGeometry.canvasPadding
            )
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 2 : -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.set()
            let path = NSBezierPath(rect: paper)
            Theme.paperColor(darkPaper: darkPaper).setFill()
            path.fill()
            NSShadow().set()
            NSColor.black.withAlphaComponent(0.08).setStroke()
            path.lineWidth = 1
            path.stroke()
            if geometry.showPageNumbers {
                let label = "\(i + 1)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let size = label.size(withAttributes: attrs)
                let point = CGPoint(
                    x: paper.midX - size.width / 2,
                    y: paper.maxY - geometry.margin / 2 - size.height / 2
                )
                label.draw(at: point, withAttributes: attrs)
            }
        }
        if textView.mode == .wysiwyg {
            drawHeadingRules()
        }
    }

    private func drawHeadingRules() {
        let origin = textView.frame.origin
        let padX = horizontalPadding
        let padY = PageGeometry.canvasPadding
        Theme.headingRule(darkPaper: darkPaper).setStroke()
        for range in headingRules() {
            var rect = rectForUTF16Range(range)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            let y = rect.maxY + 4
            let line = CGRect(x: origin.x, y: y, width: geometry.contentSize.width, height: 1)
            for piece in PageLayout.pageContentPieces(
                of: line,
                pageCount: pageCount,
                geometry: geometry,
                paddingX: padX,
                paddingY: padY
            ) {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: piece.minX, y: piece.midY))
                path.line(to: CGPoint(x: piece.maxX, y: piece.midY))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    func queueRelayout() {
        if isRelayouting {
            relayoutQueued = true
            return
        }
        guard !relayoutQueued else { return }
        relayoutQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutQueued = false
            self.relayout()
        }
    }

    func relayout() {
        if isRelayouting { return }
        isRelayouting = true
        headingRuleSource = nil
        let padX = horizontalPadding
        let padY = PageGeometry.canvasPadding
        textView.textContainer?.containerSize = CGSize(width: geometry.contentSize.width, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = false
        var pages = max(1, pageCount)
        var spacing = textView.mode == .wysiwyg ? textView.extraBlockSpacing : [:]
        var seen = Set<String>()
        for _ in 0..<12 {
            let signature = Self.layoutSignature(pages: pages, spacing: spacing)
            if seen.contains(signature) { break }
            seen.insert(signature)
            if textView.mode != .wysiwyg {
                spacing = [:]
            }
            if !spacingMatches(textView.extraBlockSpacing, spacing) {
                textView.extraBlockSpacing = spacing
                textView.applyStyles()
            }
            var holes = PageLayout.exclusionRects(
                pageCount: pages,
                geometry: geometry,
                containerWidth: geometry.contentSize.width
            )
            holes.append(contentsOf: pageBreakHoles(pageCount: pages))
            textView.textContainer?.exclusionPaths = holes.map { NSBezierPath(rect: $0) }
            ensureLayout()
            let used = usedHeight()
            let needed = max(1, PageLayout.pageCount(usedHeightWithExclusions: used, currentPages: pages, geometry: geometry))
            let nextSpacing = textView.mode == .wysiwyg ? measureTableSpacing() : [:]
            if needed == pages, spacingMatches(spacing, nextSpacing) { break }
            pages = needed
            spacing = nextSpacing
        }
        if !spacingMatches(textView.extraBlockSpacing, spacing) {
            textView.extraBlockSpacing = spacing
            textView.applyStyles()
            ensureLayout()
        }
        pageCount = pages
        let canvas = PageLayout.canvasSize(pageCount: pages, geometry: geometry, paddingX: padX, paddingY: padY)
        setFrameSize(canvas)
        textView.frame = CGRect(
            x: padX + geometry.margin,
            y: padY + geometry.margin,
            width: geometry.contentSize.width,
            height: max(geometry.contentSize.height, PageLayout.lastContentBottom(pageCount: pages, geometry: geometry))
        )
        refreshImages()
        refreshCodeChrome()
        refreshTables()
        refreshLinkCard()
        for header in codeHeaders {
            addSubview(header, positioned: .above, relativeTo: nil)
        }
        if isLinkCardVisible {
            addSubview(linkCard, positioned: .above, relativeTo: nil)
        }
        needsDisplay = true
        onPagesChanged?(pageCount)
        isRelayouting = false
        if relayoutQueued {
            relayoutQueued = false
            queueRelayout()
        }
    }

    private static func layoutSignature(pages: Int, spacing: [Int: CGFloat]) -> String {
        let parts = spacing.keys.sorted().map { key in
            "\(key):\(Int((spacing[key] ?? 0).rounded()))"
        }
        return "\(pages)|\(parts.joined(separator: ","))"
    }

    private func headingRules() -> [NSRange] {
        let source = textView.string
        if headingRuleSource == source { return headingRuleRanges }
        headingRuleSource = source
        headingRuleRanges = MarkdownSyntax.spans(in: source).compactMap { span in
            guard span.role == .content, case .heading(let level) = span.kind, level <= 2 else { return nil }
            return span.range
        }
        return headingRuleRanges
    }

    func ensureLayout() {
        if let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        } else {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        }
    }

    func usedHeight() -> CGFloat {
        if let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            return tlm.usageBoundsForTextContainer.height
        }
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return 0 }
        lm.ensureLayout(for: container)
        return lm.usedRect(for: container).height
    }

    func pageBreakHoles(pageCount: Int) -> [CGRect] {
        let source = textView.string
        let ranges = PageBreakMarker.ranges(in: source)
        guard !ranges.isEmpty else { return [] }
        var holes: [CGRect] = []
        ensureLayout()
        for range in ranges {
            let y = caretY(at: range.location) + 16
            let page = min(pageCount - 1, PageLayout.pageIndex(forTextY: y, geometry: geometry))
            let bottom = PageLayout.contentBottom(pageIndex: page, geometry: geometry)
            if bottom - y > 12 {
                holes.append(CGRect(x: 0, y: y, width: geometry.contentSize.width, height: bottom - y))
            }
        }
        return holes
    }

    func caretY(at utf16Offset: Int) -> CGFloat {
        if let tlm = textView.textLayoutManager, let content = textView.textContentStorage {
            let start = tlm.documentRange.location
            if let loc = content.location(start, offsetBy: utf16Offset),
               let fragment = tlm.textLayoutFragment(for: loc) {
                return fragment.layoutFragmentFrame.minY
            }
        }
        if let lm = textView.layoutManager {
            let glyph = lm.glyphIndexForCharacter(at: min(utf16Offset, max(0, textView.string.utf16.count - 1)))
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        return 0
    }

    func paperRect(page index: Int) -> CGRect {
        PageLayout.paperRect(
            pageIndex: index,
            geometry: geometry,
            paddingX: horizontalPadding,
            paddingY: PageGeometry.canvasPadding
        )
    }

    func snapshot(page index: Int, size: CGSize) -> NSImage {
        let paper = paperRect(page: index)
        let pixels = CGSize(width: max(1, size.width * 2), height: max(1, size.height * 2))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current {
            let sx = pixels.width / max(paper.width, 1)
            let sy = pixels.height / max(paper.height, 1)
            ctx.cgContext.scaleBy(x: sx, y: sy)
            ctx.cgContext.translateBy(x: -paper.minX, y: -paper.minY)
            displayIgnoringOpacity(paper, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    func visiblePageIndex(in clip: NSRect) -> Int {
        let y = max(0, clip.midY - PageGeometry.canvasPadding)
        return min(pageCount - 1, PageLayout.pageIndex(forTextY: y, geometry: geometry))
    }

    func scrollToPage(_ index: Int, in scrollView: NSScrollView) {
        let paper = paperRect(page: index)
        scrollView.contentView.scrollToVisible(paper.insetBy(dx: -8, dy: -8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func refreshImages() {
        imageOverlays.forEach { $0.removeFromSuperview() }
        imageOverlays.removeAll()
        guard textView.mode == .wysiwyg else { return }
        var seen = Set<String>()
        let spans = MarkdownSyntax.spans(in: textView.string)
        for span in spans {
            guard case .image(let path) = span.kind else { continue }
            let key = "\(span.group.location):\(path)"
            if seen.contains(key) { continue }
            seen.insert(key)
            let url: URL
            if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path)
            } else if let dir = documentDirectory {
                url = dir.appendingPathComponent(path)
            } else {
                continue
            }
            guard let image = NSImage(contentsOf: url) else { continue }
            let y = caretY(at: span.group.location)
            let maxWidth = geometry.contentSize.width
            let natural = image.size
            let scale = min(1, maxWidth / max(natural.width, 1))
            let size = CGSize(width: natural.width * scale, height: natural.height * scale)
            let view = NSImageView(frame: CGRect(
                x: textView.frame.minX,
                y: textView.frame.minY + y + 18,
                width: size.width,
                height: size.height
            ))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            addSubview(view, positioned: .above, relativeTo: textView)
            imageOverlays.append(view)
        }
    }

    func rectForUTF16Range(_ range: NSRange) -> CGRect {
        ensureLayout()
        let length = (textView.string as NSString).length
        guard length > 0 else { return .zero }
        let start = min(max(0, range.location), length - 1)
        let last = min(max(start, NSMaxRange(range) - 1), length - 1)
        let y0 = caretY(at: start)
        var y1 = y0 + 18
        if let tlm = textView.textLayoutManager, let content = textView.textContentStorage {
            let doc = tlm.documentRange.location
            if let loc = content.location(doc, offsetBy: last),
               let fragment = tlm.textLayoutFragment(for: loc) {
                y1 = fragment.layoutFragmentFrame.maxY
            }
        } else if let lm = textView.layoutManager {
            let glyph = lm.glyphIndexForCharacter(at: last)
            y1 = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY
        }
        if y1 <= y0 { y1 = y0 + 18 }
        return CGRect(x: 0, y: y0, width: geometry.contentSize.width, height: y1 - y0)
    }

    func refreshCodeChrome() {
        codeBackgrounds.forEach { $0.removeFromSuperview() }
        codeHeaders.forEach { $0.removeFromSuperview() }
        codeBackgrounds.removeAll()
        codeHeaders.removeAll()
        let origin = textView.frame.origin
        let padX = horizontalPadding
        let padY = PageGeometry.canvasPadding
        for block in MarkdownSyntax.codeBlocks(in: textView.string) {
            var rect = rectForUTF16Range(block.group)
            guard rect.height > 4 else { continue }
            rect = CGRect(
                x: origin.x,
                y: origin.y + rect.minY,
                width: geometry.contentSize.width,
                height: rect.height
            )
            let pieces = PageLayout.pageContentPieces(
                of: rect,
                pageCount: pageCount,
                geometry: geometry,
                paddingX: padX,
                paddingY: padY
            )
            let slices = pieces.isEmpty ? [rect] : pieces
            let language = textView.mode == .wysiwyg ? block.language : nil
            for (index, piece) in slices.enumerated() {
                let background = CodeBlockBackgroundView(frame: piece)
                background.darkPaper = darkPaper
                background.shapeRect = rect.offsetBy(dx: -piece.minX, dy: -piece.minY)
                background.language = index == 0 ? language : nil
                addSubview(background, positioned: .below, relativeTo: textView)
                codeBackgrounds.append(background)
            }
            guard let first = slices.first else { continue }
            var copy = block.innerText
            if copy.isEmpty, block.content.length > 0,
               NSMaxRange(block.content) <= (textView.string as NSString).length {
                copy = (textView.string as NSString).substring(with: block.content)
                    .trimmingCharacters(in: .newlines)
            }
            addCopyChip(
                hangingFrom: first,
                copyText: copy,
                runScript: ShellRunner.isShell(block.language) ? copy : nil
            )
        }
        for quote in MarkdownSyntax.quotes(in: textView.string) {
            var rect = rectForUTF16Range(quote.group)
            guard rect.height > 4 else { continue }
            rect = CGRect(
                x: origin.x,
                y: origin.y + rect.minY,
                width: geometry.contentSize.width,
                height: rect.height
            )
            let pieces = PageLayout.pageContentPieces(
                of: rect,
                pageCount: pageCount,
                geometry: geometry,
                paddingX: padX,
                paddingY: padY
            )
            let first = (pieces.isEmpty ? [rect] : pieces).first ?? rect
            addCopyChip(hangingFrom: first, copyText: quote.innerText, runScript: nil)
        }
    }

    private func addCopyChip(hangingFrom block: CGRect, copyText: String, runScript: String?) {
        let chip = CopyChipView(frame: CopyChipView.frame(hangingFrom: block, showsRun: runScript != nil))
        chip.configure(copyText: copyText, darkPaper: darkPaper, runScript: runScript)
        chip.onRun = { [weak self] script in
            ShellRunner.run(script, workingDirectory: self?.documentDirectory)
        }
        addSubview(chip, positioned: .above, relativeTo: textView)
        codeHeaders.append(chip)
    }

    func tablesStayOnPages() -> Bool {
        let padX = horizontalPadding
        let padY = PageGeometry.canvasPadding
        for overlay in pagesTables {
            for rect in overlay.chromeRects() {
                var canvas = rect
                canvas.origin.x += overlay.frame.minX
                canvas.origin.y += overlay.frame.minY
                for index in 0..<max(0, pageCount - 1) {
                    let top = PageLayout.contentRect(
                        pageIndex: index,
                        geometry: geometry,
                        paddingX: padX,
                        paddingY: padY
                    )
                    let bottom = PageLayout.contentRect(
                        pageIndex: index + 1,
                        geometry: geometry,
                        paddingX: padX,
                        paddingY: padY
                    )
                    let gap = CGRect(
                        x: top.minX,
                        y: top.maxY,
                        width: top.width,
                        height: max(0, bottom.minY - top.maxY)
                    )
                    let overlap = canvas.intersection(gap)
                    if !overlap.isNull, overlap.height > 1 {
                        return false
                    }
                }
            }
        }
        return true
    }

    func codeBackgroundsStayOnPages() -> Bool {
        let padX = horizontalPadding
        let padY = PageGeometry.canvasPadding
        for view in codeBackgrounds {
            for index in 0..<max(0, pageCount - 1) {
                let top = PageLayout.contentRect(
                    pageIndex: index,
                    geometry: geometry,
                    paddingX: padX,
                    paddingY: padY
                )
                let bottom = PageLayout.contentRect(
                    pageIndex: index + 1,
                    geometry: geometry,
                    paddingX: padX,
                    paddingY: padY
                )
                let gap = CGRect(
                    x: top.minX,
                    y: top.maxY,
                    width: top.width,
                    height: max(0, bottom.minY - top.maxY)
                )
                let overlap = view.frame.intersection(gap)
                if !overlap.isNull, overlap.height > 1 {
                    return false
                }
            }
        }
        return true
    }

    func performFirstCopy() {
        codeHeaders.first?.copyTapped()
    }

    func firstCopyButton() -> CopyCodeButton? {
        codeHeaders.first?.copyButton
    }

    func simulateCopyButtonHover() -> Bool {
        guard let button = firstCopyButton() else { return false }
        if let event = enterEvent(for: button) {
            button.mouseEntered(with: event)
        } else {
            button.resetCursorRects()
            NSCursor.pointingHand.set()
        }
        return NSCursor.current == NSCursor.pointingHand
    }

    func copyPopupIsTopRight() -> Bool {
        guard let header = codeHeaders.first, let background = codeBackgrounds.first else { return false }
        let button = header.convert(header.copyButton.frame, to: self)
        return button.maxX > background.frame.maxX - 1
            && button.minY < background.frame.minY + 2
            && button.maxX - background.frame.maxX >= 4
            && background.frame.minY - button.minY >= 4
            && button.width <= 32
            && button.height <= 32
    }

    func copyButtonHitTestSucceeds() -> Bool {
        guard let button = firstCopyButton() else { return false }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
        return hitTest(point) === button
    }

    var firstChipShowsRun: Bool { codeHeaders.first?.showsRun == true }

    func firstRunButton() -> CopyCodeButton? {
        guard let header = codeHeaders.first, header.showsRun else { return nil }
        return header.runButton
    }

    func runButtonHitTestSucceeds() -> Bool {
        guard let button = firstRunButton() else { return false }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
        return hitTest(point) === button
    }

    func tableAddColumnChipHitTestSucceeds() -> Bool {
        pagesTables.first?.addColumnChipHitTest(in: self) ?? false
    }

    func tableGuttersSitOutsideGrid() -> Bool {
        pagesTables.first?.pagesChromeIsNative() ?? false
    }

    func tableCoversHiddenSource() -> Bool {
        pagesTables.first?.coversHiddenSource() ?? false
    }

    var extraBlockSpacingSnapshot: [Int: CGFloat] { textView.extraBlockSpacing }

    var firstTableRowCount: Int { pagesTables.first?.storageRowCount ?? 0 }
    var firstTableColumnCount: Int { pagesTables.first?.storageColumnCount ?? 0 }
    var firstTableHasFieldFocus: Bool { pagesTables.first?.hasFieldFocus ?? false }
    var firstTableSliceCount: Int { pagesTables.first?.sliceCount ?? 0 }
    var firstTableRepeatsHeader: Bool { pagesTables.first?.continuationRepeatsHeader ?? false }

    func clickFirstTableAddRow() { pagesTables.first?.clickAddRow() }
    func clickFirstTableAddColumn() { pagesTables.first?.clickAddColumn() }
    func clickFirstTableDeleteRow() { pagesTables.first?.clickDeleteRow() }
    func clickFirstTableDeleteColumn() { pagesTables.first?.clickDeleteColumn() }
    func pressFirstTableTab() { pagesTables.first?.pressTab() }
    func pressFirstTableReturn() { pagesTables.first?.pressReturn() }
    func selectFirstTableRow(_ row: Int) { pagesTables.first?.selectRow(row) }
    func selectFirstTableColumn(_ column: Int) { pagesTables.first?.selectColumn(column) }
    func focusFirstTableCell(row: Int, column: Int) {
        pagesTables.first?.focusCell(row: row, column: column, stealFocus: true)
    }

    private func enterEvent(for view: NSView) -> NSEvent? {
        guard let window = view.window else { return nil }
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        )
    }

    func refreshLinkCard() {
        guard textView.mode == .wysiwyg,
              let link = MarkdownEditing.link(at: textView.selectedRange().location, in: textView.string)
        else {
            linkCard.removeFromSuperview()
            linkCard.isHidden = true
            pendingLinkCardFocus = false
            return
        }
        linkCard.configure(url: link.url)
        let textRect = glyphRect(for: link.textRange)
        let origin = textView.frame.origin
        let width = min(geometry.contentSize.width, 360)
        var x = origin.x + textRect.minX
        let y = origin.y + textRect.maxY + 4
        x = min(max(origin.x, x), origin.x + geometry.contentSize.width - width)
        linkCard.frame = CGRect(x: x, y: y, width: width, height: LinkCardView.cardHeight)
        linkCard.isHidden = false
        if linkCard.superview == nil {
            addSubview(linkCard, positioned: .above, relativeTo: nil)
        } else {
            addSubview(linkCard, positioned: .above, relativeTo: nil)
        }
        if pendingLinkCardFocus {
            pendingLinkCardFocus = false
            linkCard.focusURLField()
        }
    }

    func glyphRect(for range: NSRange) -> CGRect {
        ensureLayout()
        var result = CGRect.null
        if let tlm = textView.textLayoutManager, let content = textView.textContentStorage {
            let doc = tlm.documentRange.location
            let length = (textView.string as NSString).length
            let startOffset = min(max(0, range.location), max(0, length))
            if let start = content.location(doc, offsetBy: startOffset) {
                let endOffset = min(max(startOffset, NSMaxRange(range)), length)
                let end = content.location(doc, offsetBy: endOffset) ?? start
                if let textRange = NSTextRange(location: start, end: end) {
                    tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                        if result.isNull { result = rect } else { result = result.union(rect) }
                        return true
                    }
                }
            }
        }
        if result.isNull || result.height < 1 {
            return CGRect(x: 0, y: caretY(at: range.location), width: min(140, geometry.contentSize.width), height: 18)
        }
        return result
    }

    func measureTableSpacing() -> [Int: CGFloat] {
        var spacing: [Int: CGFloat] = [:]
        for block in TableMutator.allBlocks(in: textView.string) {
            let loc = block.range.location
            let flow = PageLayout.flowTableRows(
                startY: caretY(at: loc),
                storageRows: PagesTableView.storageRows(for: block),
                rowHeight: PagesTableView.rowHeight,
                topPad: PagesTableView.topPad,
                bottomPad: PagesTableView.bottomPad,
                geometry: geometry
            )
            spacing[loc] = flow.contentHeight
        }
        return spacing
    }

    func refreshTables() {
        if textView.mode != .wysiwyg {
            pagesTables.forEach { $0.removeFromSuperview() }
            pagesTables.removeAll()
            return
        }
        let blocks = TableMutator.allBlocks(in: textView.string)
        let origin = textView.frame.origin
        let width = geometry.contentSize.width
        var unused = pagesTables
        var next: [PagesTableView] = []
        for block in blocks {
            let loc = block.range.location
            let table: PagesTableView
            if let index = unused.firstIndex(where: { $0.block.range.location == loc }) {
                table = unused.remove(at: index)
                let focus = tableFocus.flatMap { $0.location == loc ? ($0.row, $0.column) : nil }
                table.update(block: block, darkPaper: darkPaper, focus: focus)
            } else {
                table = PagesTableView(block: block, darkPaper: darkPaper)
                table.tableDelegate = self
                addSubview(table, positioned: .above, relativeTo: textView)
                if let focus = tableFocus, focus.location == loc {
                    table.update(block: block, darkPaper: darkPaper, focus: (focus.row, focus.column))
                }
            }
            _ = table.preferredSize(fitting: width)
            let startY = caretY(at: loc)
            let flow = PageLayout.flowTableRows(
                startY: startY,
                storageRows: table.storageRowsForFlow,
                rowHeight: PagesTableView.rowHeight,
                topPad: PagesTableView.topPad,
                bottomPad: PagesTableView.bottomPad,
                geometry: geometry
            )
            table.applyFlow(flow)
            table.frame = CGRect(
                x: origin.x,
                y: origin.y + flow.startY,
                width: width,
                height: table.paginationHeight
            )
            table.layoutSubtreeIfNeeded()
            next.append(table)
        }
        unused.forEach { $0.removeFromSuperview() }
        pagesTables = next
    }

    func spacingMatchesForTests(_ a: [Int: CGFloat], _ b: [Int: CGFloat]) -> Bool {
        spacingMatches(a, b)
    }

    private func spacingMatches(_ a: [Int: CGFloat], _ b: [Int: CGFloat]) -> Bool {
        guard a.count == b.count else { return false }
        for (key, value) in a {
            guard let other = b[key], abs(other - value) < 0.5 else { return false }
        }
        return true
    }

    func focusedTableCell() -> TableMutator.CellRef? {
        if let overlay = pagesTables.first(where: { $0.containsResponder(window?.firstResponder) }) {
            return TableMutator.CellRef(block: overlay.block, row: overlay.selectedRow, column: overlay.selectedColumn)
        }
        return TableMutator.cell(at: textView.selectedRange().location, in: textView.string)
    }

    var isEditingTable: Bool { focusedTableCell() != nil }

    var canDeleteTableRow: Bool { isEditingTable }
    var canDeleteTableColumn: Bool { isEditingTable }
    var canDeleteTable: Bool { isEditingTable }

    func deleteTable() {
        guard let cell = focusedTableCell(),
              let result = TableMutator.deleteTable(source: textView.string, cell: cell) else { return }
        tableFocus = nil
        textView.applyEdit(result)
        relayout()
    }

    func focusInsertedTable() {
        let loc = textView.selectedRange().location
        guard let block = TableMutator.block(at: loc, in: textView.string) else { return }
        tableFocus = (block.range.location, 0, 0)
        refreshTables()
        pagesTables.first(where: { $0.block.range.location == block.range.location })?.focusCell(row: 0, column: 0)
    }

    func insertTableRow(_ placement: RowPlacement) {
        guard let cell = focusedTableCell(),
              let result = TableMutator.insertRow(source: textView.string, cell: cell, placement: placement) else { return }
        applyTableEdit(result)
    }

    func insertTableColumn(_ placement: ColumnPlacement) {
        guard let cell = focusedTableCell(),
              let result = TableMutator.insertColumn(source: textView.string, cell: cell, placement: placement) else { return }
        applyTableEdit(result)
    }

    func deleteTableRow() {
        guard let cell = focusedTableCell(),
              let result = TableMutator.deleteRow(source: textView.string, cell: cell) else { return }
        applyTableEdit(result)
    }

    func deleteTableColumn() {
        guard let cell = focusedTableCell(),
              let result = TableMutator.deleteColumn(source: textView.string, cell: cell) else { return }
        applyTableEdit(result)
    }

    private func rememberFocus(_ result: EditResult) {
        if let cell = TableMutator.cell(at: result.selected.location, in: result.text) {
            tableFocus = (cell.block.range.location, cell.row, cell.column)
        } else {
            tableFocus = nil
        }
    }

    private func applyTableEdit(_ result: EditResult) {
        rememberFocus(result)
        textView.applyEdit(result)
        relayout()
        restoreTableFieldFocus()
    }

    func restoreTableFieldFocusForTests() { restoreTableFieldFocus() }

    private func restoreTableFieldFocus() {
        guard let focus = tableFocus else { return }
        pagesTables.first(where: { $0.block.range.location == focus.location })?
            .focusCell(row: focus.row, column: focus.column, stealFocus: true)
    }

    enum ExportChromePhase {
        case behindText
        case aboveText
    }

    func drawExportChrome(page index: Int, phase: ExportChromePhase) {
        let padX = horizontalPadding
        let padY = PageGeometry.canvasPadding
        let paperOnCanvas = PageLayout.paperRect(pageIndex: index, geometry: geometry, paddingX: padX, paddingY: padY)
        let paper = CGRect(origin: .zero, size: geometry.paperSize)
        func pageRect(fromCanvas rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX - paperOnCanvas.minX,
                y: rect.minY - paperOnCanvas.minY,
                width: rect.width,
                height: rect.height
            )
        }
        if phase == .behindText {
            for block in MarkdownSyntax.codeBlocks(in: textView.string) {
                var rect = rectForUTF16Range(block.group)
                rect.origin.x += textView.frame.minX
                rect.origin.y += textView.frame.minY
                let pieces = PageLayout.pageContentPieces(
                    of: rect,
                    pageCount: pageCount,
                    geometry: geometry,
                    paddingX: padX,
                    paddingY: padY
                )
                let slices = pieces.isEmpty ? [rect] : pieces
                for (index, piece) in slices.enumerated() {
                    let drawn = pageRect(fromCanvas: piece)
                    guard drawn.intersects(paper) else { continue }
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: drawn).addClip()
                    Theme.drawCodeBlockFill(in: pageRect(fromCanvas: rect), darkPaper: darkPaper)
                    NSGraphicsContext.restoreGraphicsState()
                    if index == 0, let language = block.language, !language.isEmpty {
                        (language as NSString).draw(
                            at: CGPoint(x: drawn.minX + 14, y: drawn.minY + 6),
                            withAttributes: [
                                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]
                        )
                    }
                }
            }
            if textView.mode == .wysiwyg {
                Theme.headingRule(darkPaper: darkPaper).setStroke()
                let origin = textView.frame.origin
                for range in headingRules() {
                    var rect = rectForUTF16Range(range)
                    rect.origin.x += origin.x
                    rect.origin.y += origin.y
                    let line = CGRect(x: origin.x, y: rect.maxY + 4, width: geometry.contentSize.width, height: 1)
                    for piece in PageLayout.pageContentPieces(
                        of: line,
                        pageCount: pageCount,
                        geometry: geometry,
                        paddingX: padX,
                        paddingY: padY
                    ) {
                        let drawn = pageRect(fromCanvas: piece)
                        guard drawn.intersects(paper) else { continue }
                        let path = NSBezierPath()
                        path.move(to: CGPoint(x: drawn.minX, y: drawn.midY))
                        path.line(to: CGPoint(x: drawn.maxX, y: drawn.midY))
                        path.lineWidth = 1
                        path.stroke()
                    }
                }
            }
        } else if textView.mode == .wysiwyg {
            for overlay in pagesTables {
                overlay.drawExported(intoPage: paper, paperOnCanvas: paperOnCanvas)
            }
        }
    }
}

extension PagedEditorView: @MainActor LinkCardDelegate {
    func linkCard(_ view: LinkCardView, commitURL url: String) {
        guard let result = MarkdownEditing.setLinkURL(
            source: textView.string,
            location: textView.selectedRange().location,
            url: url
        ) else { return }
        textView.applyEdit(result)
    }

    func linkCardOpen(_ view: LinkCardView) {
        Hyperlink.open(view.url, relativeTo: documentDirectory)
    }

    func linkCardCopy(_ view: LinkCardView) {
        Hyperlink.copy(view.url)
    }

    func linkCardRemove(_ view: LinkCardView) {
        guard let result = MarkdownEditing.removeLink(
            source: textView.string,
            location: textView.selectedRange().location
        ) else { return }
        textView.applyEdit(result)
        refreshLinkCard()
    }
}

extension PagedEditorView: @MainActor PagesTableDelegate {
    func pagesTable(_ view: PagesTableView, commit row: Int, column: Int, text: String) {
        let loc = view.block.range.location
        let current = row < view.block.rows.count && column < view.block.rows[row].count
            ? view.block.rows[row][column].trimmingCharacters(in: .whitespaces)
            : ""
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if current == trimmed { return }
        tableFocus = (loc, row, column)
        if let result = TableMutator.setCell(
            source: textView.string,
            location: loc,
            row: row,
            column: column,
            value: trimmed
        ) {
            applyTableEdit(result)
        }
    }

    func pagesTable(_ view: PagesTableView, insertRow placement: RowPlacement) {
        let cell = TableMutator.CellRef(block: view.block, row: view.selectedRow, column: view.selectedColumn)
        guard let result = TableMutator.insertRow(source: textView.string, cell: cell, placement: placement) else { return }
        applyTableEdit(result)
    }

    func pagesTable(_ view: PagesTableView, insertColumn placement: ColumnPlacement) {
        let cell = TableMutator.CellRef(block: view.block, row: view.selectedRow, column: view.selectedColumn)
        guard let result = TableMutator.insertColumn(source: textView.string, cell: cell, placement: placement) else { return }
        applyTableEdit(result)
    }

    func pagesTableDeleteRow(_ view: PagesTableView) {
        let cell = TableMutator.CellRef(block: view.block, row: view.selectedRow, column: view.selectedColumn)
        guard let result = TableMutator.deleteRow(source: textView.string, cell: cell) else { return }
        applyTableEdit(result)
    }

    func pagesTableDeleteColumn(_ view: PagesTableView) {
        let cell = TableMutator.CellRef(block: view.block, row: view.selectedRow, column: view.selectedColumn)
        guard let result = TableMutator.deleteColumn(source: textView.string, cell: cell) else { return }
        applyTableEdit(result)
    }

    func pagesTableDeleteTable(_ view: PagesTableView) {
        guard let result = TableMutator.deleteTable(source: textView.string, block: view.block) else { return }
        tableFocus = nil
        textView.applyEdit(result)
        relayout()
    }

    func pagesTableDidChangeFocus(_ view: PagesTableView) {
        tableFocus = (view.block.range.location, view.selectedRow, view.selectedColumn)
        onEditContextChanged?()
    }
}
