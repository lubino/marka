import AppKit
import MarkaCore

/// One picture of the document, drawn over its hidden `![alt](src)` source. Missing or still
/// loading images show a GitHub-like placeholder with the alt text.
final class ImageBlockView: NSView {
    var picture: NSImage?
    var alt = ""
    var source = ""
    /// Location of the `![…](…)` group in the source.
    var location = 0
    var onClick: ((ImageBlockView) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovered = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let picture {
            picture.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            ImageBlockView.drawPlaceholder(alt: alt, source: source, in: bounds)
        }
        if hovered || isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.9 : 0.5).setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    static let placeholderFont = NSFont.systemFont(ofSize: 11)

    static func placeholderSize(alt: String, source: String, maxWidth: CGFloat) -> CGSize {
        let label = placeholderLabel(alt: alt, source: source) as NSString
        let width = label.size(withAttributes: [.font: placeholderFont]).width
        return CGSize(width: min(maxWidth, ceil(width) + 36), height: 26)
    }

    private static func placeholderLabel(alt: String, source: String) -> String {
        alt.isEmpty ? (source as NSString).lastPathComponent : alt
    }

    /// Broken-image box: border, image icon, alt text (or the file name).
    static func drawPlaceholder(alt: String, source: String, in rect: CGRect) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        // Fixed paper colours (see `Theme.paperSecondaryText`): also drawn off-screen and into PDF.
        NSColor(white: 0.5, alpha: 0.06).setFill()
        box.fill()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        box.lineWidth = 1
        box.stroke()
        if let icon = QuoteChromeView.tintedSymbol("photo", pointSize: 11, weight: .regular, color: NSColor(white: 0.55, alpha: 1)) {
            icon.draw(in: CGRect(x: rect.minX + 8, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let label = placeholderLabel(alt: alt, source: source) as NSString
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        label.draw(in: CGRect(x: rect.minX + 26, y: rect.midY - 7, width: max(0, rect.width - 32), height: 15),
                   withAttributes: [.font: placeholderFont, .foregroundColor: Theme.paperSecondaryText(darkPaper: false), .paragraphStyle: style])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(self) }
}

/// Loaded pictures: local files by path + modification date, web images fetched once in the
/// background (`didLoad` makes the canvases relayout when one arrives).
@MainActor
final class ImageStore {
    static let shared = ImageStore()
    private var files: [String: (date: Date?, image: NSImage?)] = [:]
    private var remote: [URL: NSImage] = [:]
    private var loading = Set<URL>()
    private var failed = Set<URL>()
    /// Posted when a web image arrives (canvases relayout).
    static let didLoad = Notification.Name("sk.lubino.marka.imageDidLoad")

    func image(for url: URL) -> NSImage? {
        if url.isFileURL {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = files[url.path], cached.date == date { return cached.image }
            let image = NSImage(contentsOf: url)
            files[url.path] = (date, image)
            return image
        }
        if let image = remote[url] { return image }
        guard url.scheme == "https" || url.scheme == "http", !loading.contains(url), !failed.contains(url) else { return nil }
        loading.insert(url)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let bytes = data
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = ImageStore.shared
                    store.loading.remove(url)
                    if let bytes, let image = NSImage(data: bytes) {
                        store.remote[url] = image
                        NotificationCenter.default.post(name: ImageStore.didLoad, object: nil)
                    } else {
                        store.failed.insert(url)
                    }
                }
            }
        }.resume()
        return nil
    }
}

extension PagedEditorView {
    struct ImageItem {
        let image: MarkdownImage
        let picture: NSImage?
        /// Frame relative to the image line's drawing area.
        var frame: CGRect
    }

    struct ImageLineItem {
        let line: ImageLine
        let items: [ImageItem]
        let height: CGFloat
    }

    static let imagePad: CGFloat = 6
    static let imageGap: CGFloat = 6

    func resolvedImageURL(_ source: String) -> URL? {
        switch Hyperlink.destination(source, relativeTo: documentDirectory) {
        case .file(let url)?, .markdown(let url)?: return url
        case .remote(let url)?: return url
        case nil: return nil
        }
    }

    /// Lines with images, each laid out GitHub-style: natural size, never wider than the column
    /// nor taller than a page, side by side when they fit (badges), wrapping otherwise.
    func imageLineItems() -> [ImageLineItem] {
        guard textView.mode == .wysiwyg else { return [] }
        let width = geometry.contentSize.width
        let maxHeight = max(80, geometry.contentSize.height - 2 * Self.imagePad - 24)
        return MarkdownSyntax.imageLines(in: textView.string).map { line in
            var items: [ImageItem] = []
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
            for image in line.images {
                let picture = resolvedImageURL(image.source).flatMap { ImageStore.shared.image(for: $0) }
                var size: CGSize
                if let picture, picture.size.width > 0, picture.size.height > 0 {
                    size = Self.displaySize(natural: picture.size, width: image.width, height: image.height, column: width)
                    let scale = min(1, width / size.width, maxHeight / size.height)
                    size = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
                } else {
                    size = ImageBlockView.placeholderSize(alt: image.alt, source: image.source, maxWidth: width)
                }
                if x > 0, x + size.width > width {
                    x = 0
                    y += rowHeight + Self.imageGap
                    rowHeight = 0
                }
                items.append(ImageItem(image: image, picture: picture, frame: CGRect(origin: CGPoint(x: x, y: y), size: size)))
                x += size.width + Self.imageGap
                rowHeight = max(rowHeight, size.height)
            }
            // Alignment (GitHub `align` / `<p align="center">`) moves an image-only line's single row.
            if line.imageOnly, y == 0, let align = line.images.first?.align, align == "center" || align == "right" {
                let rowWidth = (items.last?.frame.maxX ?? 0)
                let shift = align == "center" ? (width - rowWidth) / 2 : width - rowWidth
                items = items.map { var item = $0; item.frame.origin.x += max(0, shift); return item }
            }
            return ImageLineItem(line: line, items: items, height: y + rowHeight)
        }
    }

    /// `width` / `height` attributes ("300", "300px", "50%"); one given keeps the aspect ratio.
    static func displaySize(natural: CGSize, width: String, height: String, column: CGFloat) -> CGSize {
        func points(_ value: String, of whole: CGFloat) -> CGFloat? {
            let v = value.trimmingCharacters(in: .whitespaces).lowercased()
            if v.hasSuffix("%"), let n = Double(v.dropLast()) { return whole * CGFloat(n) / 100 }
            let digits = v.hasSuffix("px") ? String(v.dropLast(2)) : v
            return Double(digits).map { CGFloat($0) }
        }
        let w = points(width, of: column), h = points(height, of: natural.height)
        switch (w, h) {
        case let (w?, h?): return CGSize(width: w, height: h)
        case let (w?, nil): return CGSize(width: w, height: natural.height * w / natural.width)
        case let (nil, h?): return CGSize(width: natural.width * h / natural.height, height: h)
        default: return natural
        }
    }

    /// Text-container y where a line's pictures start. An image-only line is collapsed, so they
    /// take its place; otherwise they go below the line's last text row.
    func imageTop(_ item: ImageLineItem) -> CGFloat {
        let line = item.line.line
        if item.line.imageOnly {
            return caretY(at: line.location) + Self.imagePad
        }
        let last = max(line.location, NSMaxRange(line) - 1)
        if let lm = textView.layoutManager, textView.textLayoutManager == nil {
            let glyph = lm.glyphIndexForCharacter(at: min(last, max(0, textView.string.utf16.count - 1)))
            return lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY + Self.imagePad
        }
        return caretY(at: last) + textView.editorSettings.fontSize * 1.4 + Self.imagePad
    }

    func measureImageSpacing() -> [Int: CGFloat] {
        var spacing: [Int: CGFloat] = [:]
        for item in imageLineItems() {
            spacing[item.line.line.location] = item.height + Self.imagePad * 2
        }
        return spacing
    }

    func refreshImages() {
        let lines = imageLineItems()
        let count = lines.reduce(0) { $0 + $1.items.count }
        while imageViews.count > count { imageViews.removeLast().removeFromSuperview() }
        while imageViews.count < count {
            let view = ImageBlockView()
            view.onClick = { [weak self] view in self?.showImageCard(for: view) }
            addSubview(view, positioned: .above, relativeTo: textView)
            imageViews.append(view)
        }
        let origin = textView.frame.origin
        var index = 0
        for line in lines {
            let top = imageTop(line)
            for item in line.items {
                let view = imageViews[index]
                index += 1
                view.picture = item.picture
                view.alt = item.image.alt
                view.source = item.image.source
                view.location = item.image.group.location
                view.toolTip = (item.image.alt.isEmpty ? "" : item.image.alt + " — ") + item.image.source
                view.frame = CGRect(x: origin.x + item.frame.minX, y: origin.y + top + item.frame.minY,
                                    width: item.frame.width, height: item.frame.height)
                view.isSelected = imageCardLocation == view.location && isImageCardVisible
                view.needsDisplay = true
            }
        }
        repositionImageCard()
    }

    /// PDF / print: pictures (and placeholders) at their page positions.
    func drawImages(intoPage paper: CGRect, paperOnCanvas: CGRect) {
        for view in imageViews where !view.isHidden {
            let rect = CGRect(x: view.frame.minX - paperOnCanvas.minX, y: view.frame.minY - paperOnCanvas.minY,
                              width: view.frame.width, height: view.frame.height)
            guard rect.intersects(paper) else { continue }
            if let picture = view.picture {
                picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                ImageBlockView.drawPlaceholder(alt: view.alt, source: view.source, in: rect)
            }
        }
    }

    // MARK: Image card (same look as the link card)

    var isImageCardVisible: Bool { imageCard.superview != nil && !imageCard.isHidden }

    func showImageCard(for view: ImageBlockView) {
        showImageCard(location: view.location, source: view.source, anchor: nil)
    }

    /// The card for the image starting at `location`; `anchor` (canvas rect) for images without
    /// their own view — pictures in table cells.
    func showImageCard(location: Int, source: String, anchor: CGRect?) {
        linkCard.removeFromSuperview()
        imageCardLocation = location
        imageCardAnchor = anchor
        imageCard.configure(url: source)
        imageCard.isHidden = false
        addSubview(imageCard, positioned: .above, relativeTo: nil)
        imageViews.forEach { $0.isSelected = $0.location == location }
        repositionImageCard()
    }

    func hideImageCard() {
        guard imageCard.superview != nil else { return }
        imageCard.removeFromSuperview()
        imageCard.isHidden = true
        imageCardLocation = nil
        imageCardAnchor = nil
        imageViews.forEach { $0.isSelected = false }
    }

    /// Under the picture (above it when the picture ends near the bottom of the visible area).
    func repositionImageCard() {
        guard isImageCardVisible, let location = imageCardLocation,
              let image = MarkdownSyntax.image(at: location, in: textView.string),
              let frame = imageViews.first(where: { $0.location == location })?.frame ?? imageCardAnchor else {
            if isImageCardVisible { hideImageCard() }
            return
        }
        imageCard.fieldFontSize = textView.editorSettings.fontSize
        imageCard.configure(url: image.source)
        let width = min(geometry.contentSize.width, 300)
        let x = min(max(textView.frame.minX, frame.minX), textView.frame.minX + geometry.contentSize.width - width)
        var y = frame.maxY + 6
        if y + LinkCardView.cardHeight > visibleRect.maxY, frame.minY - LinkCardView.cardHeight - 6 > visibleRect.minY {
            y = frame.minY - LinkCardView.cardHeight - 6
        }
        imageCard.frame = CGRect(x: x, y: y, width: width, height: LinkCardView.cardHeight)
        addSubview(imageCard, positioned: .above, relativeTo: nil)
    }

    func imageCardChooseFile() {
        guard let location = imageCardLocation else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        panel.message = "Choose a different image."
        if let directory = documentDirectory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        FileReference.resolve(file, kind: .image, documentDirectory: documentDirectory,
                              trackedRoot: textView.markdownDelegate?.trackedRoot, window: window) { [weak self] path in
            guard let self, let path else { return }
            self.setImageSource(at: location, to: path)
        }
    }

    /// Gear: alt text, title, width, height, alignment — GitHub's `<img>` attributes.
    func showImageOptions(from button: NSView) {
        guard let location = imageCardLocation, let image = MarkdownSyntax.image(at: location, in: textView.string) else { return }
        let natural = resolvedImageURL(image.source).flatMap { ImageStore.shared.image(for: $0) }?.size
        let controller = ImageOptionsViewController(options: ImageOptions(image), naturalSize: natural)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = controller
        controller.popover = popover
        _ = controller.view
        popover.contentSize = controller.preferredContentSize
        controller.onApply = { [weak self] options in self?.applyImageOptions(at: location, options) }
        imageOptionsPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func applyImageOptions(at location: Int, _ options: ImageOptions) {
        guard let image = MarkdownSyntax.image(at: location, in: textView.string),
              ImageOptions(image) != options,
              let result = MarkdownEditing.setImageOptions(source: textView.string, imageAt: location, options: options) else { return }
        textView.applyEdit(EditResult(text: result.text, selected: textView.selectedRange()))
        relayout()
        // The image now starts where its <img> / ![ begins: keep the card on it.
        imageCardLocation = result.selected.location
        repositionImageCard()
    }

    func setImageSource(at location: Int, to source: String) {
        guard let result = MarkdownEditing.setImageSource(source: textView.string, imageAt: location, to: source) else { return }
        let selection = textView.selectedRange()
        textView.applyEdit(EditResult(text: result.text, selected: selection.location <= (result.text as NSString).length ? selection : result.selected))
        relayout()
    }

    func removeImage(at location: Int) {
        guard let result = MarkdownEditing.removeImage(source: textView.string, imageAt: location) else { return }
        hideImageCard()
        textView.applyEdit(result)
        relayout()
    }

    /// The image's file path (or web address) — "copy its name with location".
    func imageCardCopy() {
        guard let location = imageCardLocation, let source = MarkdownSyntax.image(at: location, in: textView.string)?.source else { return }
        let url = resolvedImageURL(source)
        Hyperlink.copy(url.map { $0.isFileURL ? $0.path : $0.absoluteString } ?? source)
    }

    // MARK: Testing

    var testImageFrames: [CGRect] { imageViews.map(\.frame) }
    var testImagePlaceholders: [Bool] { imageViews.map { $0.picture == nil } }
    func testClickImage(_ index: Int) { if index < imageViews.count { showImageCard(for: imageViews[index]) } }
    var testImageCardURL: String? { isImageCardVisible ? imageCard.url : nil }
    func testImageCardCommit(_ source: String) { if let location = imageCardLocation { setImageSource(at: location, to: source) } }
    func testImageCardRemove() { if let location = imageCardLocation { removeImage(at: location) } }
}
