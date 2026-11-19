import AppKit
import MarkaCore

/// Renders a table cell's inline Markdown (markers hidden) for display; editing shows the raw text.
enum CellMarkdown {
    static func attributed(_ raw: String, font: NSFont, color: NSColor, darkPaper: Bool) -> NSAttributedString {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let ns = text as NSString
        let spans = MarkdownSyntax.inlineSpans(in: text)
        guard !spans.isEmpty else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        var hidden = IndexSet()
        for span in spans where span.role == .marker {
            hidden.insert(integersIn: span.range.location..<NSMaxRange(span.range))
        }
        let out = NSMutableAttributedString()
        for i in 0..<ns.length where !hidden.contains(i) {
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
}

extension CellMarkdown {
    /// WYSIWYG editing: styles the cell's *source* in place — markers stay in the text (so the
    /// Markdown is what gets saved) but are hidden, and content is bold / italic / code / link.
    static func styleSource(_ storage: NSTextStorage, font: NSFont, color: NSColor, darkPaper: Bool) {
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
        storage.endEditing()
    }
}

/// Table cell: shows rendered Markdown; while edited it keeps the Markdown source but shows it
/// WYSIWYG (markers hidden), restyled on every change.
final class MarkdownCellField: NSTextField {
    var render: ((String) -> NSAttributedString)?
    /// Styles the field editor's source while editing (set by the table).
    var styleEditor: ((NSTextStorage) -> Void)?
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
        guard isEditingSource, let editor = currentEditor() as? NSTextView, let storage = editor.textStorage else { return }
        let selection = editor.selectedRanges
        styleEditor?(storage)
        editor.selectedRanges = selection
        editor.typingAttributes = baseTypingAttributes
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
