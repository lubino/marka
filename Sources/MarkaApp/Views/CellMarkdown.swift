import AppKit
import MarkaCore

/// Renders a table cell's inline Markdown (markers hidden) for display; editing shows the raw text.
@MainActor
enum CellMarkdown {
    static func attributed(_ raw: String, font: NSFont, color: NSColor, darkPaper: Bool, base: URL? = nil,
                           maxPictureWidth: CGFloat = 200) -> NSAttributedString {
        // `\|` is GitHub's escaped pipe inside a cell: shown as "|".
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|")
        let ns = text as NSString
        let spans = MarkdownSyntax.inlineSpans(in: text)
        let images = cellImages(text, base: base, maxWidth: maxPictureWidth)
        guard !spans.isEmpty || !images.isEmpty else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        var hidden = IndexSet()
        for span in spans where span.role == .marker {
            hidden.insert(integersIn: span.range.location..<NSMaxRange(span.range))
        }
        // Images in a cell are shown as pictures, like GitHub's cells.
        var pictures: [Int: (end: Int, picture: CellPicture)] = [:]
        for image in images {
            guard let picture = image.picture else { continue }
            pictures[image.range.location] = (NSMaxRange(image.range), picture)
        }
        let out = NSMutableAttributedString()
        var skipTo = 0
        for i in 0..<ns.length {
            if i < skipTo { continue }
            if let picture = pictures[i] {
                out.append(attachment(picture.picture, font: font))
                skipTo = picture.end
                continue
            }
            if hidden.contains(i) { continue }
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var code = false
            for span in spans where span.role == .content && NSLocationInRange(i, span.range) {
                switch span.kind {
                case .inlineCode: code = true
                case .strikethrough: attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case .link, .image:
                    attrs[.foregroundColor] = NSColor.systemBlue
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                default: break
                }
            }
            if code {
                f = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: font.fontDescriptor.symbolicTraits.contains(.bold) ? .semibold : .regular)
                attrs[.backgroundColor] = Theme.inlineCodeBox(darkPaper: darkPaper)
            }
            for span in spans where span.role == .content && NSLocationInRange(i, span.range) {
                if span.kind == .strong { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if span.kind == .emphasis { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            }
            attrs[.font] = f
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: i, length: 1)), attributes: attrs))
        }
        return out
    }

    static func imageURL(_ source: String, base: URL?) -> URL? {
        switch Hyperlink.destination(source, relativeTo: base) {
        case .file(let url)?, .markdown(let url)?, .remote(let url)?: return url
        case nil: return nil
        }
    }

    /// Tallest picture a cell shows (taller ones are scaled down).
    static let maxPictureHeight: CGFloat = 240

    /// An image in a cell's text: `![alt](src)` or `<img src width height>`, with its picture
    /// (nil when the file is missing or still loading).
    struct CellImage {
        var range: NSRange
        var source: String
        var picture: CellPicture?
    }

    static func cellImages(_ text: String, base: URL?, maxWidth: CGFloat) -> [CellImage] {
        var found: [CellImage] = []
        func add(range: NSRange, source: String, width: String, height: String) {
            let picture = imageURL(source, base: base).flatMap { ImageStore.shared.image(for: $0) }.map {
                CellPicture(image: $0, size: pictureSize($0, width: width, height: height, maxWidth: maxWidth))
            }
            found.append(CellImage(range: range, source: source, picture: picture))
        }
        for span in MarkdownSyntax.inlineSpans(in: text) where span.role == .marker && span.range.location == span.group.location {
            if case .image(let source) = span.kind { add(range: span.group, source: source, width: "", height: "") }
        }
        let ns = text as NSString
        for image in MarkdownSyntax.tableCellHTMLImages(ns) {
            add(range: image.group, source: image.source, width: image.width, height: image.height)
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Natural size (or the `<img width / height>`), never wider than the column nor taller than
    /// `maxPictureHeight`, proportions kept.
    static func pictureSize(_ image: NSImage, width: String = "", height: String = "", maxWidth: CGFloat) -> CGSize {
        var size = PagedEditorView.displaySize(natural: image.size, width: width, height: height, column: maxWidth)
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, max(1, maxWidth) / size.width, maxPictureHeight / size.height)
        size = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        return size
    }

    /// The picture as an inline attachment (its line grows to the picture's height).
    static func attachment(_ picture: CellPicture, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = picture.image
        attachment.bounds = CGRect(x: 0, y: font.descender, width: picture.size.width, height: picture.size.height)
        return NSAttributedString(attachment: attachment)
    }
}

extension CellMarkdown {
    /// WYSIWYG editing: styles the cell's *source* in place — markers stay in the text (so the
    /// Markdown is what gets saved) but are hidden, and content is bold / italic / code / link.
    static func styleSource(_ storage: NSTextStorage, font: NSFont, color: NSColor, darkPaper: Bool,
                            base: URL? = nil, maxPictureWidth: CGFloat = 200) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: color], range: full)
        let spans = MarkdownSyntax.inlineSpans(in: storage.string)
        for span in spans where span.role == .content {
            switch span.kind {
            case .inlineCode:
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular),
                    .backgroundColor: Theme.inlineCodeBox(darkPaper: darkPaper)
                ], range: span.range)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .link, .image:
                storage.addAttributes([
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: span.range)
            default:
                break
            }
        }
        for span in spans where span.role == .content && (span.kind == .strong || span.kind == .emphasis) {
            let trait: NSFontTraitMask = span.kind == .strong ? .boldFontMask : .italicFontMask
            storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                let base = (value as? NSFont) ?? font
                storage.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: trait), range: range)
            }
        }
        for span in spans where span.role == .marker {
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.01),
                .foregroundColor: NSColor.clear,
                .kern: -1
            ], range: span.range)
        }
        // Images show as pictures, like outside the editor: the source is hidden, the picture's
        // width reserved (kern), the line made as tall as the tallest picture, and
        // `CellFieldEditor` draws them. Clicking a picture opens the image card.
        var tallest: CGFloat = 0
        for image in cellImages(storage.string, base: base, maxWidth: maxPictureWidth) {
            guard let picture = image.picture, NSMaxRange(image.range) <= storage.length else { continue }
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.01),
                .foregroundColor: NSColor.clear,
                .kern: 0,
                .underlineStyle: 0,
                .markaCellImage: picture
            ], range: image.range)
            storage.addAttribute(.kern, value: picture.size.width, range: NSRange(location: NSMaxRange(image.range) - 1, length: 1))
            tallest = max(tallest, picture.size.height)
        }
        if tallest > 0 {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = tallest - font.descender
            storage.addAttribute(.paragraphStyle, value: style, range: full)
        }
        storage.endEditing()
    }
}

/// Table cell: shows rendered Markdown; while edited it keeps the Markdown source but shows it
/// WYSIWYG (markers hidden), restyled on every change.
final class MarkdownCellField: NSTextField {
    var render: ((String) -> NSAttributedString)?
    /// Styles the field editor's source while editing (set by the table).
    var styleEditor: ((NSTextStorage) -> Void)?
    /// A picture in the cell was clicked (index among the cell's images).
    var onImageClick: ((MarkdownCellField, Int) -> Void)?
    /// Called when the cell becomes first responder — a click, Tab, an arrow key, or code.
    var onFocus: ((MarkdownCellField) -> Void)?
    var baseTypingAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var isEditingSource = false

    /// The cell's Markdown source.
    var raw = "" {
        didSet { if !isEditingSource { showRendered() } }
    }

    /// What to commit: the live editor text while editing, else the stored source (never the
    /// rendered text, which has its markers stripped).
    var currentSource: String {
        guard isEditingSource else { return raw }
        return (currentEditor() as? NSTextView)?.string ?? raw
    }

    override func becomeFirstResponder() -> Bool {
        isEditingSource = true
        stringValue = raw
        let became = super.becomeFirstResponder()
        if became {
            restyleEditor()
            onFocus?(self)
        }
        return became
    }

    /// Re-apply WYSIWYG styling to the field editor's text (attributes only, selection kept).
    func restyleEditor() {
        guard isEditingSource, !isRestyling, let editor = currentEditor() as? NSTextView, let storage = editor.textStorage else { return }
        isRestyling = true
        defer { isRestyling = false }
        let selection = editor.selectedRanges
        styleEditor?(storage)
        editor.selectedRanges = selection
        editor.typingAttributes = baseTypingAttributes
        editor.needsDisplay = true
    }
    private var isRestyling = false

    /// Cells edit in a `CellFieldEditor`, which draws pictures over hidden image Markdown.
    override class var cellClass: AnyClass? {
        get { MarkdownCellFieldCell.self }
        set { super.cellClass = newValue }
    }

    override func textDidEndEditing(_ notification: Notification) {
        // Capture the source *before* AppKit ends editing: afterwards `stringValue` is the field
        // editor's display value, which lost the hidden markers ("**Bold**" → "Bold").
        let edited = (currentEditor() as? NSTextView)?.string ?? stringValue
        super.textDidEndEditing(notification)   // the delegate commits `currentSource` here
        isEditingSource = false
        raw = edited
    }

    override func abortEditing() -> Bool {
        let aborted = super.abortEditing()
        isEditingSource = false
        showRendered()
        return aborted
    }

    func showRendered() {
        if let render {
            attributedStringValue = render(raw)
        } else {
            stringValue = raw
        }
    }
}

extension NSAttributedString.Key {
    /// A picture drawn by `CellFieldEditor` over a cell's hidden `![alt](path)`.
    static let markaCellImage = NSAttributedString.Key("MarkaCellImage")
}

/// The table cell's cell: hands out the shared picture-drawing field editor.
final class MarkdownCellFieldCell: NSTextFieldCell {
    @MainActor static let editor: CellFieldEditor = {
        let editor = CellFieldEditor(usingTextLayoutManager: false)   // TextKit 1: glyph positions
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        MainActor.assumeIsolated { Self.editor }
    }
}

/// A picture in a cell and the size it is shown at.
final class CellPicture: NSObject {
    let image: NSImage
    let size: CGSize
    init(image: NSImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// Field editor for table cells: draws `.markaCellImage` pictures on their reserved space, keeps
/// the caret out of an image's hidden Markdown, and reports clicks on a picture (image card).
final class CellFieldEditor: NSTextView {
    /// Pictures with their rects (this view's coordinates) and character ranges.
    func pictureRects() -> [(rect: CGRect, range: NSRange, picture: CellPicture)] {
        guard let storage = textStorage, let lm = layoutManager, storage.length > 0 else { return [] }
        var result: [(CGRect, NSRange, CellPicture)] = []
        storage.enumerateAttribute(.markaCellImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let picture = value as? CellPicture, range.length > 0 else { return }
            let glyph = lm.glyphIndexForCharacter(at: range.location)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = lm.location(forGlyphAt: glyph)
            let baseline = line.minY + location.y
            let font = typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
            result.append((CGRect(x: textContainerOrigin.x + line.minX + location.x,
                                  y: textContainerOrigin.y + baseline - font.descender - picture.size.height,
                                  width: picture.size.width, height: picture.size.height), range, picture))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for item in pictureRects() {
            item.picture.image.draw(in: item.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pictures = pictureRects()
        // Through AnyObject: Swift treats a direct NSTextViewDelegate → NSTextField cast as
        // impossible and compiles it to "always nil", but the field editor's delegate is the cell.
        if let index = pictures.firstIndex(where: { $0.rect.contains(point) }), let field = (delegate as AnyObject?) as? MarkdownCellField {
            field.onImageClick?(field, index)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for item in pictureRects() { addCursorRect(item.rect, cursor: .pointingHand) }
    }

    /// The caret never lands inside an image's hidden Markdown: it moves to the image's edge.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var adjusted = ranges
        if ranges.count == 1, ranges[0].rangeValue.length == 0 {
            let caret = ranges[0].rangeValue.location
            let previous = selectedRange().location
            for item in pictureRects() where caret > item.range.location && caret < NSMaxRange(item.range) {
                let forward = caret >= previous
                adjusted = [NSValue(range: NSRange(location: forward ? NSMaxRange(item.range) : item.range.location, length: 0))]
            }
        }
        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelecting)
    }
}
