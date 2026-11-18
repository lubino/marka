import AppKit
import MarkaCore

final class PagedEditorView: NSView {
    let textView: MarkdownTextView
    var geometry: PageGeometry = .init()
    var darkPaper = false
    private(set) var pageCount = 1
    var onPagesChanged: ((Int) -> Void)?
    var documentDirectory: URL?
    private var imageOverlays: [NSImageView] = []
    private var relayoutQueued = false

    override var isFlipped: Bool { true }

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvasColor(darkPaper: darkPaper).setFill()
        dirtyRect.fill()
        for i in 0..<pageCount {
            let paper = PageLayout.paperRect(pageIndex: i, geometry: geometry)
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
    }

    func queueRelayout() {
        guard !relayoutQueued else { return }
        relayoutQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.relayoutQueued = false
            self?.relayout()
        }
    }

    func relayout() {
        let pad = PageGeometry.canvasPadding
        textView.textContainer?.containerSize = CGSize(width: geometry.contentSize.width, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = false
        var pages = max(1, pageCount)
        for _ in 0..<24 {
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
            if needed == pages { break }
            pages = needed
        }
        pageCount = pages
        let canvas = PageLayout.canvasSize(pageCount: pages, geometry: geometry, padding: pad)
        setFrameSize(canvas)
        textView.frame = CGRect(
            x: pad + geometry.margin,
            y: pad + geometry.margin,
            width: geometry.contentSize.width,
            height: max(geometry.contentSize.height, PageLayout.lastContentBottom(pageCount: pages, geometry: geometry))
        )
        refreshImages()
        needsDisplay = true
        onPagesChanged?(pageCount)
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

    func snapshot(page index: Int, size: CGSize) -> NSImage {
        let paper = PageLayout.paperRect(pageIndex: index, geometry: geometry)
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
        let pad = PageGeometry.canvasPadding
        let y = max(0, clip.midY - pad)
        return min(pageCount - 1, PageLayout.pageIndex(forTextY: y, geometry: geometry))
    }

    func scrollToPage(_ index: Int, in scrollView: NSScrollView) {
        let paper = PageLayout.paperRect(pageIndex: index, geometry: geometry)
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
}
