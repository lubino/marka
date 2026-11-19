import AppKit
import MarkaCore

@MainActor
enum PDFExporter {
    static func data(from canvas: PagedEditorView) -> Data? {
        let geometry = canvas.geometry
        let pageCount = max(1, canvas.pageCount)
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: geometry.paperSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }

        let headings = MarkdownSyntax.outline(in: canvas.textView.string)
        let links = linkRegions(canvas: canvas)
        for i in 0..<pageCount {
            var box = media
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: geometry.paperSize.height)
            ctx.scaleBy(x: 1, y: -1)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            drawPage(index: i, canvas: canvas)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()

            for heading in headings {
                let y = canvas.caretY(at: heading.range.location)
                let page = PageLayout.pageIndex(forTextY: y, geometry: geometry)
                if page == i {
                    let dest = "h-\(heading.range.location)"
                    let paperY = geometry.paperSize.height - geometry.margin - (y - PageLayout.contentTop(pageIndex: i, geometry: geometry))
                    ctx.addDestination(dest as CFString, at: CGPoint(x: geometry.margin, y: paperY))
                }
            }
            // Clickable links: a URL annotation over each line of the link label.
            for link in links where link.page == i {
                let pdfRect = CGRect(
                    x: link.rect.minX,
                    y: geometry.paperSize.height - link.rect.maxY,
                    width: link.rect.width,
                    height: link.rect.height
                )
                ctx.setURL(link.url as CFURL, for: pdfRect)
            }
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }

    struct LinkRegion {
        var page: Int
        /// Page coordinates, y down from the paper's top edge.
        var rect: CGRect
        var url: URL
    }

    /// Where each link label lands on the exported pages, and the URL it points to. Web links stay
    /// web links; local files and `.md` links become absolute file URLs. Links inside tables are
    /// drawn by the table overlay, not the text, so they are skipped.
    static func linkRegions(canvas: PagedEditorView) -> [LinkRegion] {
        let geometry = canvas.geometry
        let source = canvas.textView.string
        let spans = MarkdownSyntax.spans(in: source)
        let tables = spans.compactMap { span -> NSRange? in
            if case .table = span.kind { return span.group }
            return nil
        }
        var regions: [LinkRegion] = []
        for span in spans where span.role == .content {
            guard case .link(let raw) = span.kind else { continue }
            guard !tables.contains(where: { NSLocationInRange(span.range.location, $0) }) else { continue }
            let url: URL
            switch Hyperlink.destination(raw, relativeTo: canvas.documentDirectory) {
            case .remote(let remote)?: url = remote
            case .markdown(let file)?, .file(let file)?: url = file.absoluteURL
            case nil: continue
            }
            for rect in canvas.textView.segmentRects(for: span.range) {
                let page = min(canvas.pageCount - 1, PageLayout.pageIndex(forTextY: rect.midY, geometry: geometry))
                let top = geometry.margin + (rect.minY - PageLayout.contentTop(pageIndex: page, geometry: geometry))
                regions.append(LinkRegion(
                    page: page,
                    rect: CGRect(x: geometry.margin + rect.minX, y: top, width: rect.width, height: rect.height),
                    url: url
                ))
            }
        }
        return regions
    }

    /// (page index, URL) of every link annotation in a PDF — for tests.
    static func linkAnnotations(in data: Data) -> [(page: Int, url: String, rect: CGRect)] {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else { return [] }
        var found: [(Int, String, CGRect)] = []
        for number in 1...max(1, pdf.numberOfPages) {
            guard let page = pdf.page(at: number), let dict = page.dictionary else { continue }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dict, "Annots", &annots), let annots else { continue }
            for index in 0..<CGPDFArrayGetCount(annots) {
                var annot: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, index, &annot), let annot else { continue }
                var action: CGPDFDictionaryRef?
                var uri: CGPDFStringRef?
                guard CGPDFDictionaryGetDictionary(annot, "A", &action), let action,
                      CGPDFDictionaryGetString(action, "URI", &uri), let uri,
                      let text = CGPDFStringCopyTextString(uri) as String? else { continue }
                var rectArray: CGPDFArrayRef?
                var rect = CGRect.zero
                if CGPDFDictionaryGetArray(annot, "Rect", &rectArray), let rectArray, CGPDFArrayGetCount(rectArray) == 4 {
                    var v = [CGPDFReal](repeating: 0, count: 4)
                    for k in 0..<4 { CGPDFArrayGetNumber(rectArray, k, &v[k]) }
                    rect = CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
                }
                found.append((number - 1, text, rect))
            }
        }
        return found
    }

    static func write(from canvas: PagedEditorView, to url: URL) throws {
        guard let data = data(from: canvas) else {
            throw NSError(domain: "Marka", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF"])
        }
        try data.write(to: url)
    }

    static func drawPage(index: Int, canvas: PagedEditorView) {
        let geometry = canvas.geometry
        let paper = CGRect(origin: .zero, size: geometry.paperSize)
        Theme.paperColor(darkPaper: canvas.darkPaper).setFill()
        paper.fill()
        canvas.drawExportChrome(page: index, phase: .behindText)

        let padX = canvas.horizontalPadding
        let padY = PageGeometry.canvasPadding
        let paperOnCanvas = PageLayout.paperRect(pageIndex: index, geometry: geometry, paddingX: padX, paddingY: padY)
        let textOrigin = CGPoint(x: padX + geometry.margin, y: padY + geometry.margin)

        if let tlm = canvas.textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
                var frame = fragment.layoutFragmentFrame
                frame.origin.x += textOrigin.x
                frame.origin.y += textOrigin.y
                if frame.intersects(paperOnCanvas.insetBy(dx: -1, dy: -1)) {
                    let drawAt = CGPoint(
                        x: geometry.margin + fragment.layoutFragmentFrame.minX,
                        y: geometry.margin + (fragment.layoutFragmentFrame.minY - PageLayout.contentTop(pageIndex: index, geometry: geometry))
                    )
                    if let cg = NSGraphicsContext.current?.cgContext {
                        fragment.draw(at: drawAt, in: cg)
                    }
                }
                return true
            }
        } else if let lm = canvas.textView.layoutManager, let container = canvas.textView.textContainer {
            let used = lm.usedRect(for: container)
            let origin = CGPoint(
                x: geometry.margin,
                y: geometry.margin - PageLayout.contentTop(pageIndex: index, geometry: geometry)
            )
            NSGraphicsContext.current?.cgContext.saveGState()
            NSBezierPath(rect: CGRect(x: geometry.margin, y: geometry.margin, width: geometry.contentSize.width, height: geometry.contentSize.height)).addClip()
            lm.drawBackground(forGlyphRange: lm.glyphRange(forBoundingRect: used, in: container), at: origin)
            // Inline code boxes go behind the glyphs, inline math on top (both drawn by the text view).
            canvas.textView.drawInlineCodeBoxesForExport(origin: origin)
            lm.drawGlyphs(forGlyphRange: lm.glyphRange(forBoundingRect: used, in: container), at: origin)
            canvas.textView.drawInlineMathForExport(origin: origin)
            NSGraphicsContext.current?.cgContext.restoreGState()
        }

        canvas.drawExportChrome(page: index, phase: .aboveText)

        if geometry.showPageNumbers {
            let label = "\(index + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: (paper.width - size.width) / 2, y: paper.height - geometry.margin / 2 - size.height / 2), withAttributes: attrs)
        }
    }
}

final class PrintablePagesView: NSView {
    let canvas: PagedEditorView

    init(canvas: PagedEditorView) {
        self.canvas = canvas
        super.init(frame: CGRect(origin: .zero, size: canvas.geometry.paperSize))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, canvas.pageCount))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        CGRect(origin: .zero, size: canvas.geometry.paperSize)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let current = NSPrintOperation.current?.currentPage ?? 1
        PDFExporter.drawPage(index: max(0, current - 1), canvas: canvas)
    }
}

@MainActor
enum PrintController {
    /// The standard macOS print operation for the A4 pages (what you see is what prints).
    static func operation(canvas: PagedEditorView, title: String?, printInfo: NSPrintInfo? = nil) -> NSPrintOperation {
        let info = (printInfo ?? NSPrintInfo.shared).copy() as! NSPrintInfo
        info.paperSize = canvas.geometry.paperSize
        info.leftMargin = 0
        info.rightMargin = 0
        info.topMargin = 0
        info.bottomMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let view = PrintablePagesView(canvas: canvas)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = title ?? "Marka"
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPreview, .showsPrintSelection])
        return op
    }
}
