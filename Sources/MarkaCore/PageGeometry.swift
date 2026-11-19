import CoreGraphics
import Foundation

/// A4 page metrics in PostScript points (1 in = 72 pt = 25.4 mm).
public struct PageGeometry: Equatable, Sendable {
    public var paperSize: CGSize
    public var margin: CGFloat
    public var interPageGap: CGFloat
    public var showPageNumbers: Bool

    public static let millimetresPerPoint: CGFloat = 25.4 / 72.0
    public static let pointsPerMillimetre: CGFloat = 72.0 / 25.4

    public static let zoomSteps: [CGFloat] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    public static let canvasPadding: CGFloat = 28

    public init(
        paperSize: CGSize = PageGeometry.a4PaperSize,
        margin: CGFloat = 20 * PageGeometry.pointsPerMillimetre,
        interPageGap: CGFloat = 24,
        showPageNumbers: Bool = true
    ) {
        self.paperSize = paperSize
        self.margin = margin
        self.interPageGap = interPageGap
        self.showPageNumbers = showPageNumbers
    }

    public static var a4PaperSize: CGSize {
        CGSize(width: 210 * pointsPerMillimetre, height: 297 * pointsPerMillimetre)
    }

    public static func a4(marginMillimetres: CGFloat, showPageNumbers: Bool) -> PageGeometry {
        PageGeometry(
            paperSize: a4PaperSize,
            margin: marginMillimetres * pointsPerMillimetre,
            showPageNumbers: showPageNumbers
        )
    }

    public var contentSize: CGSize {
        CGSize(
            width: max(1, paperSize.width - 2 * margin),
            height: max(1, paperSize.height - 2 * margin)
        )
    }

    public var marginMillimetres: CGFloat {
        margin * Self.millimetresPerPoint
    }

    public static func == (lhs: PageGeometry, rhs: PageGeometry) -> Bool {
        lhs.paperSize.width == rhs.paperSize.width
            && lhs.paperSize.height == rhs.paperSize.height
            && lhs.margin == rhs.margin
            && lhs.interPageGap == rhs.interPageGap
            && lhs.showPageNumbers == rhs.showPageNumbers
    }
}

public enum PageLayout {
    public static func contentTop(pageIndex: Int, geometry: PageGeometry) -> CGFloat {
        CGFloat(pageIndex) * (geometry.paperSize.height + geometry.interPageGap)
    }

    public static func contentBottom(pageIndex: Int, geometry: PageGeometry) -> CGFloat {
        contentTop(pageIndex: pageIndex, geometry: geometry) + geometry.contentSize.height
    }

    public static func exclusionRects(pageCount: Int, geometry: PageGeometry, containerWidth: CGFloat) -> [CGRect] {
        guard pageCount > 1 else { return [] }
        var rects: [CGRect] = []
        let contentH = geometry.contentSize.height
        let stride = geometry.paperSize.height + geometry.interPageGap
        let hole = geometry.interPageGap + 2 * geometry.margin
        for i in 0..<(pageCount - 1) {
            let y = CGFloat(i) * stride + contentH
            rects.append(CGRect(x: 0, y: y, width: containerWidth, height: hole))
        }
        return rects
    }

    public static func lastContentBottom(pageCount: Int, geometry: PageGeometry) -> CGFloat {
        contentBottom(pageIndex: max(0, pageCount - 1), geometry: geometry)
    }

    public static func pageCountFitting(usedTextHeight: CGFloat, geometry: PageGeometry, minimum: Int = 1) -> Int {
        guard usedTextHeight > 0 else { return max(1, minimum) }
        var n = max(1, minimum)
        while n < 500 {
            let bottom = lastContentBottom(pageCount: n, geometry: geometry)
            if usedTextHeight <= bottom + 0.5 {
                return n
            }
            n += 1
        }
        return n
    }

    /// Pages needed when `usedTextHeight` is the height of text laid out *with* exclusions for `currentPages`.
    public static func pageCount(usedHeightWithExclusions used: CGFloat, currentPages: Int, geometry: PageGeometry) -> Int {
        let bottom = lastContentBottom(pageCount: max(1, currentPages), geometry: geometry)
        if used <= bottom + 0.5 {
            return max(1, currentPages)
        }
        return pageCountFitting(usedTextHeight: used, geometry: geometry, minimum: currentPages + 1)
    }

    public static func pageIndex(forTextY y: CGFloat, geometry: PageGeometry) -> Int {
        let stride = geometry.paperSize.height + geometry.interPageGap
        guard stride > 0 else { return 0 }
        return max(0, Int(floor(y / stride)))
    }

    public static func canvasSize(
        pageCount: Int,
        geometry: PageGeometry,
        padding: CGFloat = PageGeometry.canvasPadding
    ) -> CGSize {
        canvasSize(pageCount: pageCount, geometry: geometry, paddingX: padding, paddingY: padding)
    }

    public static func canvasSize(
        pageCount: Int,
        geometry: PageGeometry,
        paddingX: CGFloat,
        paddingY: CGFloat
    ) -> CGSize {
        let n = max(1, pageCount)
        let height = paddingY * 2
            + CGFloat(n) * geometry.paperSize.height
            + CGFloat(n - 1) * geometry.interPageGap
        return CGSize(width: paddingX * 2 + geometry.paperSize.width, height: height)
    }

    public static func paperRect(pageIndex: Int, geometry: PageGeometry, padding: CGFloat = PageGeometry.canvasPadding) -> CGRect {
        paperRect(pageIndex: pageIndex, geometry: geometry, paddingX: padding, paddingY: padding)
    }

    public static func paperRect(
        pageIndex: Int,
        geometry: PageGeometry,
        paddingX: CGFloat,
        paddingY: CGFloat
    ) -> CGRect {
        let y = paddingY + CGFloat(pageIndex) * (geometry.paperSize.height + geometry.interPageGap)
        return CGRect(x: paddingX, y: y, width: geometry.paperSize.width, height: geometry.paperSize.height)
    }

    public static func contentRect(
        pageIndex: Int,
        geometry: PageGeometry,
        paddingX: CGFloat,
        paddingY: CGFloat
    ) -> CGRect {
        paperRect(pageIndex: pageIndex, geometry: geometry, paddingX: paddingX, paddingY: paddingY)
            .insetBy(dx: geometry.margin, dy: geometry.margin)
    }

    /// Splits a canvas-space rect so each piece sits on one page's content area (cuts at the page gap).
    public static func pageContentPieces(
        of rect: CGRect,
        pageCount: Int,
        geometry: PageGeometry,
        paddingX: CGFloat,
        paddingY: CGFloat
    ) -> [CGRect] {
        guard rect.width > 0.5, rect.height > 0.5 else { return [] }
        var pieces: [CGRect] = []
        for index in 0..<max(1, pageCount) {
            let piece = rect.intersection(
                contentRect(pageIndex: index, geometry: geometry, paddingX: paddingX, paddingY: paddingY)
            )
            if !piece.isNull, piece.width > 0.5, piece.height > 0.5 {
                pieces.append(piece)
            }
        }
        return pieces
    }

    public static func nearestZoomStep(_ value: CGFloat) -> CGFloat {
        PageGeometry.zoomSteps.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1
    }

    public static func stepZoom(from current: CGFloat, delta: Int) -> CGFloat {
        let steps = PageGeometry.zoomSteps
        let nearest = nearestZoomStep(current)
        guard let idx = steps.firstIndex(of: nearest) else { return 1 }
        let next = min(steps.count - 1, max(0, idx + delta))
        return steps[next]
    }

    /// Packs table rows into page content, repeating the header after each page break (Pages).
    public struct TableFlow: Equatable, Sendable {
        public struct Row: Equatable, Sendable {
            public var storageRow: Int
            public var y: CGFloat
            public var page: Int
            public var isRepeatedHeader: Bool

            public init(storageRow: Int, y: CGFloat, page: Int, isRepeatedHeader: Bool) {
                self.storageRow = storageRow
                self.y = y
                self.page = page
                self.isRepeatedHeader = isRepeatedHeader
            }
        }

        public var rows: [Row]
        public var startY: CGFloat
        public var endY: CGFloat
        public var contentHeight: CGFloat
    }

    public static func flowTableRows(
        startY: CGFloat,
        storageRows: [Int],
        rowHeight: CGFloat,
        topPad: CGFloat,
        bottomPad: CGFloat,
        geometry: PageGeometry
    ) -> TableFlow {
        func page(of y: CGFloat) -> Int { pageIndex(forTextY: y, geometry: geometry) }
        func bottom(of y: CGFloat) -> CGFloat { contentBottom(pageIndex: page(of: y), geometry: geometry) }
        func nextTop(of y: CGFloat) -> CGFloat { contentTop(pageIndex: page(of: y) + 1, geometry: geometry) }

        var y = startY
        var content: CGFloat = 0
        func ensure(_ height: CGFloat) {
            var hops = 0
            while bottom(of: y) - y < height - 0.5, hops < 64 {
                y = nextTop(of: y)
                hops += 1
            }
        }

        ensure(topPad + rowHeight)
        y += topPad
        content += topPad

        var rows: [TableFlow.Row] = []
        let header = storageRows.first ?? 0
        func place(_ storage: Int, repeated: Bool) {
            ensure(rowHeight)
            rows.append(TableFlow.Row(storageRow: storage, y: y, page: page(of: y), isRepeatedHeader: repeated))
            y += rowHeight
            content += rowHeight
        }

        for (index, storage) in storageRows.enumerated() {
            if index == 0 {
                place(storage, repeated: false)
                continue
            }
            if bottom(of: y) - y < rowHeight - 0.5 {
                y = nextTop(of: y)
                place(header, repeated: true)
            }
            place(storage, repeated: false)
        }
        ensure(bottomPad)
        y += bottomPad
        content += bottomPad
        return TableFlow(rows: rows, startY: startY, endY: y, contentHeight: content)
    }
}
