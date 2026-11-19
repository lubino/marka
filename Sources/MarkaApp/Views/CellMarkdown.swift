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

/// Table cell: shows rendered Markdown; switches to the raw source while it is being edited.
final class MarkdownCellField: NSTextField {
    var render: ((String) -> NSAttributedString)?
    private(set) var isEditingSource = false

    /// The cell's Markdown source.
    var raw = "" {
        didSet { if !isEditingSource { showRendered() } }
    }

    /// What to commit: the live editor text while editing, else the stored source (never the
    /// rendered text, which has its markers stripped).
    var currentSource: String { isEditingSource ? stringValue : raw }

    override func becomeFirstResponder() -> Bool {
        isEditingSource = true
        stringValue = raw
        return super.becomeFirstResponder()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)   // the delegate commits `stringValue` (raw) here
        let edited = stringValue
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
