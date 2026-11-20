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
    var imageViews: [ImageBlockView] = []
    let imageCard = LinkCardView(imageMode: true)
    var imageCardLocation: Int?
    /// Where the image card points for a picture in a table cell (canvas rect).
    var imageCardAnchor: CGRect?
    private var codeBackgrounds: [CodeBlockBackgroundView] = []
    private(set) var codeHeaders: [CodeBlockHeaderView] = []
    private var pagesTables: [PagesTableView] = []
    /// Drawn ```math / $$ / ```mermaid blocks (RenderedBlocks.swift).
    var renderedViews: [RenderedBlockView] = []
    var renderedEditor: RenderedSourceEditor?
    let linkCard = LinkCardView(frame: .zero)
    var quoteChromes: [QuoteChromeView] = []
    var overviewPopover: NSPopover?
    var imageOptionsPopover: NSPopover?
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
        textView.pointerHotspot = { [weak self] point in
            guard let self else { return false }
            return self.codeHeaders.contains { $0.containsIcon(atWindowPoint: point) }
                || self.pagesTables.contains { $0.editChromeContains(windowPoint: point) }
                || self.linkCard.buttonContains(windowPoint: point)
                || self.imageCard.buttonContains(windowPoint: point)
                || (self.imageViews as [NSView] + self.renderedViews as [NSView]).contains { view in
                    !view.isHidden && view.frame.contains(self.convert(point, from: nil))
                }
        }
        linkCard.cardDelegate = self
        linkCard.isHidden = true
        imageCard.cardDelegate = self
        imageCard.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(imageDidLoad), name: ImageStore.didLoad, object: nil)
    }

    @objc private func imageDidLoad() { queueRelayout() }

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
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 1 : -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
            shadow.set()
            let path = NSBezierPath(rect: paper)
            Theme.paperColor(darkPaper: darkPaper).setFill()
            path.fill()
            NSShadow().set()
            NSColor.black.withAlphaComponent(0.04).setStroke()
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

    /// Another relayout pass is queued after the current one (the layout has not settled yet).
    /// The pass that is running right now does not count: `onPagesChanged` fires at its end.
    var hasPendingRelayout: Bool { relayoutQueued }

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
            let needed = contentPageCount(laidOutPages: pages)
            let nextSpacing = textView.mode == .wysiwyg
                ? measureTableSpacing().merging(measureRenderedSpacing()) { $1 }.merging(measureImageSpacing()) { $1 }
                : [:]
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
        refreshRenderedBlocks()
        refreshLinkCard()
        for header in codeHeaders {
            addSubview(header, positioned: .above, relativeTo: nil)
        }
        if isLinkCardVisible {
            addSubview(linkCard, positioned: .above, relativeTo: nil)
        }
        needsDisplay = true
        applyTableAnchor()
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

    /// Pages the content needs: through the last non-whitespace character (its line fragment
    /// includes paragraph spacing, so a table's overlay space counts) and the caret's page. Can
    /// shrink; trailing blank lines never add an empty page.
    func contentPageCount(laidOutPages: Int) -> Int {
        let ns = textView.string as NSString
        var last = ns.length - 1
        while last >= 0, let scalar = UnicodeScalar(ns.character(at: last)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            last -= 1
        }
        var bottom: CGFloat = 0
        if last >= 0 {
            bottom = lineBottom(at: last)
        }
        var pages = last < 0 ? 1 : PageLayout.pageIndex(forTextY: max(0, bottom - 1), geometry: geometry) + 1
        let caret = textView.selectedRange().location
        if caret > last + 1, caret <= ns.length, textView.window?.firstResponder === textView {
            // Blank lines being typed at the end: keep the page that shows the caret.
            pages = max(pages, PageLayout.pageIndex(forTextY: caretY(at: caret) + 1, geometry: geometry) + 1)
        }
        // Text that overflows the last laid-out page (no exclusion hole yet) needs another page.
        if bottom > PageLayout.lastContentBottom(pageCount: laidOutPages, geometry: geometry) + 0.5 {
            pages = max(pages, laidOutPages + 1)
        }
        return max(1, pages)
    }

    /// Bottom (text-container y) of the line fragment holding `utf16Offset`, paragraph spacing included.
    private func lineBottom(at utf16Offset: Int) -> CGFloat {
        if let tlm = textView.textLayoutManager, let content = textView.textContentStorage,
           let loc = content.location(tlm.documentRange.location, offsetBy: utf16Offset),
           let fragment = tlm.textLayoutFragment(for: loc) {
            return fragment.layoutFragmentFrame.maxY
        }
        if let lm = textView.layoutManager {
            let glyph = lm.glyphIndexForCharacter(at: utf16Offset)
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY
        }
        return 0
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

    /// 0-based page that holds the given source location (e.g. the caret).
    func pageIndex(forCharacterAt utf16Offset: Int) -> Int {
        let length = textView.string.utf16.count
        guard length > 0 else { return 0 }
        let y = caretY(at: min(max(0, utf16Offset), length))
        return min(pageCount - 1, PageLayout.pageIndex(forTextY: y, geometry: geometry))
    }

    /// Source range laid out on each page (by layout fragment), `pageCount` entries.
    func pageTextRanges() -> [NSRange] {
        var ranges = Array(repeating: NSRange(location: NSNotFound, length: 0), count: max(1, pageCount))
        func add(_ range: NSRange, minY: CGFloat) {
            let page = min(ranges.count - 1, PageLayout.pageIndex(forTextY: minY, geometry: geometry))
            ranges[page] = ranges[page].location == NSNotFound ? range : NSUnionRange(ranges[page], range)
        }
        if let tlm = textView.textLayoutManager, let content = textView.textContentStorage {
            let start = tlm.documentRange.location
            tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                let range = fragment.rangeInElement
                let location = content.offset(from: start, to: range.location)
                let length = content.offset(from: range.location, to: range.endLocation)
                add(NSRange(location: location, length: length), minY: fragment.layoutFragmentFrame.minY)
                return true
            }
        }
        return ranges.map { $0.location == NSNotFound ? NSRange(location: 0, length: 0) : $0 }
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
        quoteChromes.forEach { $0.removeFromSuperview() }
        quoteChromes.removeAll()
        codeBackgrounds.forEach { $0.removeFromSuperview() }
        codeHeaders.forEach { $0.removeFromSuperview() }
        codeBackgrounds.removeAll()
        codeHeaders.removeAll()
        let origin = textView.frame.origin
        let padX = horizontalPadding
        let padY = PageGeometry.canvasPadding
        for block in MarkdownSyntax.codeBlocks(in: textView.string) {
            // ```math / ```mermaid are drawn, not shown as code (source mode shows them as code).
            if textView.mode == .wysiwyg, MarkdownSyntax.isRendered(language: block.language) { continue }
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
                runScript: ShellRunner.isRunnable(block.language) ? copy : nil,
                runLanguage: block.language
            )
        }
        let alerts = Dictionary(MarkdownSyntax.alerts(in: textView.string).map { ($0.group.location, $0) }) { a, _ in a }
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
            if textView.mode == .wysiwyg {
                // GitHub left bar (coloured for alerts) and, for alerts, the icon + title row.
                let alert = alerts[quote.group.location]
                var titleRect: CGRect?
                if let alert {
                    var line = rectForUTF16Range(alert.marker)
                    line.origin.y += origin.y
                    titleRect = CGRect(x: origin.x + 18, y: line.minY, width: geometry.contentSize.width - 18, height: line.height)
                }
                for piece in pieces.isEmpty ? [rect] : pieces {
                    let chrome = QuoteChromeView(frame: piece)
                    chrome.alert = alert?.kind
                    chrome.darkPaper = darkPaper
                    chrome.fontSize = textView.editorSettings.fontSize
                    chrome.barRect = CGRect(x: 2, y: 1, width: 3, height: max(0, piece.height - 2))
                    chrome.titleRect = titleRect.flatMap { $0.intersects(piece) ? $0.offsetBy(dx: -piece.minX, dy: -piece.minY) : nil }
                    addSubview(chrome, positioned: .below, relativeTo: textView)
                    quoteChromes.append(chrome)
                }
            }
            let first = (pieces.isEmpty ? [rect] : pieces).first ?? rect
            addCopyChip(hangingFrom: first, copyText: quote.innerText, runScript: nil)
        }
    }

    private func addCopyChip(hangingFrom block: CGRect, copyText: String, runScript: String?, runLanguage: String? = nil) {
        let chip = CopyChipView(frame: CopyChipView.frame(hangingFrom: block, showsRun: runScript != nil))
        chip.configure(copyText: copyText, darkPaper: darkPaper, runScript: runScript)
        chip.onRun = { [weak self] script in
            ShellRunner.run(script, language: runLanguage, workingDirectory: self?.documentDirectory)
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
        let button = header.copyButton.convert(header.copyButton.bounds, to: self)
        return button.maxX > background.frame.maxX - 1
            && button.minY < background.frame.minY + 2
            && button.maxX - background.frame.maxX >= 4
            && background.frame.minY - button.minY >= 4
            && button.width <= 32
            && button.height <= 32
    }

    /// The text view reports the pointing hand over a chip icon (not its I-beam).
    func textViewUsesPointerOverCopyIcon() -> Bool {
        guard let button = firstCopyButton() else { return false }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        return textView.pointerHotspot?(point) == true
    }

    var firstCopyButtonSize: CGSize { firstCopyButton()?.bounds.size ?? .zero }
    var firstCopyButtonIsBorderless: Bool { firstCopyButton()?.isBordered == false }

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

    var firstTable: PagesTableView? { pagesTables.first }

    func tableHasOnlyGitHubGrid() -> Bool {
        pagesTables.first?.hasOnlyGitHubGrid ?? false
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

    func pressFirstTableTab() { pagesTables.first?.pressTab() }
    func pressFirstTableReturn() { pagesTables.first?.pressReturn() }
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
        linkCard.fieldFontSize = textView.editorSettings.fontSize
        linkCard.configure(url: link.url)
        let textRect = glyphRect(for: link.textRange)
        let origin = textView.frame.origin
        let width = min(geometry.contentSize.width, 300)
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
                rowHeights: PagesTableView.layoutMetrics(block: block, maxWidth: max(40, geometry.contentSize.width - PagesTableView.rowBar),
                                                         base: documentDirectory).rowHeights,
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
                rowHeights: table.rowHeights,
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

    /// Menu commands (Format → Table) commit the focused cell first, then work on fresh coordinates.
    private func commitFocusedTableCell() {
        pagesTables.first(where: { $0.containsResponder(window?.firstResponder) })?.commitPendingEdit()
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
        commitFocusedTableCell()
        guard let cell = focusedTableCell(),
              let result = TableMutator.insertRow(source: textView.string, cell: cell, placement: placement) else { return }
        applyTableEdit(result)
    }

    func insertTableColumn(_ placement: ColumnPlacement) {
        commitFocusedTableCell()
        guard let cell = focusedTableCell(),
              let result = TableMutator.insertColumn(source: textView.string, cell: cell, placement: placement) else { return }
        applyTableEdit(result)
    }

    func deleteTableRow() {
        commitFocusedTableCell()
        guard let cell = focusedTableCell(),
              let result = TableMutator.deleteRow(source: textView.string, cell: cell) else { return }
        applyTableEdit(result)
    }

    func alignTableColumn(_ alignment: ColumnAlignment) {
        commitFocusedTableCell()
        guard let cell = focusedTableCell(),
              let result = TableMutator.setAlignment(source: textView.string, cell: cell, alignment: alignment) else { return }
        applyTableEdit(result)
    }

    func deleteTableColumn() {
        commitFocusedTableCell()
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

    /// True while a table edit replaces the text (the controller skips its caret anchor).
    private(set) var isApplyingTableEdit = false
    /// The edited table's position relative to the visible area, kept until relayout settles.
    private var tableAnchor: (location: Int, offset: CGFloat, time: TimeInterval)?

    /// Scroll so the anchored table sits where it was before the edit (queued relayout passes can
    /// still shift it, so this runs after each pass until none is pending).
    private func applyTableAnchor() {
        guard let anchor = tableAnchor, let clip = enclosingScrollView?.contentView else { return }
        if !relayoutQueued || ProcessInfo.processInfo.systemUptime - anchor.time > 1 { tableAnchor = nil }
        guard let table = pagesTables.first(where: { $0.block.range.location == anchor.location }) else { return }
        let delta = (table.frame.minY - clip.bounds.minY) - anchor.offset
        guard abs(delta) > 0.25 else { return }
        let origin = NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    private func applyTableEdit(_ result: EditResult) {
        rememberFocus(result)
        // Keep the table where it is on screen: measure before, restore after the relayout.
        let location = tableFocus?.location
        let clip = enclosingScrollView?.contentView
        let before = location.flatMap { loc in pagesTables.first { $0.block.range.location == loc } }
            .map { $0.frame.minY - (clip?.bounds.minY ?? 0) }
        // The edited cell was already committed; detach it so resigning focus during the edit
        // cannot commit its stale text into the new table shape.
        pagesTables.forEach { $0.detachEditingField() }
        isApplyingTableEdit = true
        // A zero-length caret: a selection inside the hidden table source would be drawn.
        textView.applyEdit(EditResult(text: result.text, selected: NSRange(location: result.selected.location, length: 0)))
        isApplyingTableEdit = false
        if let before, let loc = tableFocus?.location ?? location {
            tableAnchor = (loc, before, ProcessInfo.processInfo.systemUptime)
        }
        relayout()
        restoreTableFieldFocus()
        applyTableAnchor()
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
                if textView.mode == .wysiwyg, MarkdownSyntax.isRendered(language: block.language) { continue }
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
            drawRenderedBlocks(intoPage: paper, paperOnCanvas: paperOnCanvas)
            drawImages(intoPage: paper, paperOnCanvas: paperOnCanvas)
            // Quote bars and alert titles (drawn after the text here; they never overlap it).
            for chrome in quoteChromes {
                let rect = CGRect(x: chrome.frame.minX - paperOnCanvas.minX, y: chrome.frame.minY - paperOnCanvas.minY,
                                  width: chrome.frame.width, height: chrome.frame.height)
                guard rect.intersects(paper) else { continue }
                QuoteChromeView.draw(alert: chrome.alert, bar: chrome.barRect.offsetBy(dx: rect.minX, dy: rect.minY),
                                     title: chrome.titleRect?.offsetBy(dx: rect.minX, dy: rect.minY),
                                     fontSize: chrome.fontSize, darkPaper: darkPaper)
            }
        }
    }
}

extension PagedEditorView: LinkCardDelegate {
    func linkCard(_ view: LinkCardView, commitURL url: String) {
        if view === imageCard {
            if let location = imageCardLocation, !url.isEmpty,
               MarkdownSyntax.image(at: location, in: textView.string)?.source != url {
                setImageSource(at: location, to: url)
            }
            return
        }
        guard let result = MarkdownEditing.setLinkURL(
            source: textView.string,
            location: textView.selectedRange().location,
            url: url
        ) else { return }
        textView.applyEdit(result)
    }

    func linkCardOpen(_ view: LinkCardView) {
        if view === imageCard {
            if let url = resolvedImageURL(view.url) { NSWorkspace.shared.open(url) }
            return
        }
        textView.openLink(view.url)
    }

    func linkCardCopy(_ view: LinkCardView) {
        if view === imageCard { return imageCardCopy() }
        Hyperlink.copy(view.url)
    }

    /// Folder button: pick a file and point the link at it (copy / original asked like images).
    func linkCardChooseFile(_ view: LinkCardView) {
        if view === imageCard { return imageCardChooseFile() }
        let location = textView.selectedRange().location
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Link"
        panel.message = "Choose the file this link should point to."
        if let directory = documentDirectory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let isImage = MarkdownTextView.imageExtensions.contains(file.pathExtension.lowercased())
        FileReference.resolve(
            file,
            kind: isImage ? .image : .link,
            documentDirectory: documentDirectory,
            trackedRoot: textView.markdownDelegate?.trackedRoot,
            window: window
        ) { [weak self] path in
            guard let self, let path,
                  let result = MarkdownEditing.setLinkURL(source: self.textView.string, location: location, url: path) else { return }
            self.textView.applyEdit(result)
            self.refreshLinkCard()
        }
    }

    func linkCardOverview(_ view: LinkCardView, from button: NSView) {
        if view === imageCard { return showImageOptions(from: button) }
        let location = textView.selectedRange().location
        let controller = DocumentOverviewViewController(
            headings: MarkdownSyntax.headingAnchors(in: textView.string),
            files: documentDirectory.map { DocumentOverviewViewController.linkableFiles(in: $0, excluding: textView.markdownDelegate?.documentFileURL) } ?? [],
            navigation: false
        )
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = DocumentOverviewViewController.size
        controller.popover = popover
        controller.onPick = { [weak self, weak popover] item in
            popover?.performClose(nil)
            guard let self else { return }
            let target: String
            switch item {
            case .heading(let anchor): target = "#" + anchor.slug
            case .file(let url, _):
                target = self.documentDirectory.map { FileReference.relativeMarkdownPath(of: url, from: $0) } ?? url.path
            case .section: return
            }
            guard let result = MarkdownEditing.setLinkURL(source: self.textView.string, location: location, url: target) else { return }
            self.textView.applyEdit(result)
            self.refreshLinkCard()
        }
        overviewPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func linkCardRemove(_ view: LinkCardView) {
        if view === imageCard {
            if let location = imageCardLocation { removeImage(at: location) }
            return
        }
        guard let result = MarkdownEditing.removeLink(
            source: textView.string,
            location: textView.selectedRange().location
        ) else { return }
        textView.applyEdit(result)
        refreshLinkCard()
    }
}

extension PagedEditorView: PagesTableDelegate {
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

    func pagesTable(_ view: PagesTableView, moveRow from: Int, to: Int) {
        let cell = TableMutator.CellRef(block: view.block, row: from, column: view.selectedColumn)
        guard let result = TableMutator.moveRow(source: textView.string, cell: cell, to: to) else { return }
        applyTableEdit(result)
    }

    /// A picture in a cell: commit the cell, find that image in the document, open the image card
    /// on the cell (same card as for pictures in the text).
    func pagesTable(_ view: PagesTableView, clickedImage index: Int, row: Int, column: Int, cellRect: CGRect) {
        let tableLocation = view.block.range.location
        commitFocusedTableCell()
        tableFocus = nil
        window?.makeFirstResponder(textView)
        relayout()
        guard let block = TableMutator.block(at: tableLocation, in: textView.string),
              let cell = TableMutator.cellRange(in: textView.string, block: block, row: row, column: column) else { return }
        let images = MarkdownSyntax.tableImages(in: textView.string).filter { NSLocationInRange($0.group.location, cell) }
        guard index < images.count else { return }
        showImageCard(location: images[index].group.location, source: images[index].source, anchor: cellRect)
    }

    func pagesTable(_ view: PagesTableView, moveColumn from: Int, to: Int) {
        let cell = TableMutator.CellRef(block: view.block, row: view.selectedRow, column: from)
        guard let result = TableMutator.moveColumn(source: textView.string, cell: cell, to: to) else { return }
        applyTableEdit(result)
    }

    func pagesTableDidChangeFocus(_ view: PagesTableView) {
        tableFocus = (view.block.range.location, view.selectedRow, view.selectedColumn)
        onEditContextChanged?()
    }
}
