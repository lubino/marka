import AppKit
import MarkaCore

enum EditorMode: String {
    case wysiwyg
    case source
}

enum Theme {
    static func bodyFont(_ settings: EditorSettings) -> NSFont {
        font(named: settings.fontName, size: settings.fontSize, weight: .regular, design: .serif)
    }

    static func headingFont(_ settings: EditorSettings, level: Int) -> NSFont {
        let scale: [CGFloat] = [0, 2.0, 1.6, 1.35, 1.18, 1.08, 1.0]
        let size = settings.fontSize * (scale.indices.contains(level) ? scale[level] : 1.0)
        return font(named: settings.fontName, size: size, weight: .semibold, design: .serif)
    }

    static func codeFont(_ settings: EditorSettings) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: max(11.5, settings.fontSize + 0.5), weight: .regular)
    }

    static func font(named name: String, size: CGFloat, weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign) -> NSFont {
        if let named = NSFont(name: name, size: size) { return named }
        if name.lowercased().contains("new york"), let ny = NSFont(name: "NewYork-Regular", size: size) {
            return ny
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(design) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }

    static func bodyColor(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.92, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.14, blue: 0.15, alpha: 1)
    }

    static func paperColor(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.12, alpha: 1) : .white
    }

    static func canvasColor(darkPaper: Bool) -> NSColor {
        if darkPaper { return NSColor(white: 0.08, alpha: 1) }
        return NSColor(calibratedWhite: 0.78, alpha: 1)
    }

    /// GitHub light `pre` / `.highlight` fill `#f6f8fa`.
    static func codeBlockFill(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.16, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
    }

    static func codeBlockBorder(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.28, alpha: 1) : NSColor(srgbRed: 0.816, green: 0.843, blue: 0.871, alpha: 1)
    }

    static func drawCodeBlockFill(in rect: CGRect, darkPaper: Bool) {
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        codeBlockFill(darkPaper: darkPaper).setFill()
        path.fill()
        codeBlockBorder(darkPaper: darkPaper).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func inlineCodeFill(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.22, alpha: 1) : NSColor(srgbRed: 0.175, green: 0.184, blue: 0.193, alpha: 0.12)
    }

    static func tableHeaderFill(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.18, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
    }

    static func tableBorder(darkPaper: Bool) -> NSColor {
        codeBlockBorder(darkPaper: darkPaper)
    }

    /// GitHub heading underline (`h1` / `h2` border-bottom).
    static func headingRule(darkPaper: Bool) -> NSColor {
        darkPaper
            ? NSColor(white: 0.32, alpha: 1)
            : NSColor(srgbRed: 0.816, green: 0.843, blue: 0.871, alpha: 1)
    }

    /// Space under h1/h2 that holds the GitHub rule. Not a typeable row.
    static let headingRuleGap: CGFloat = 10

    static func headingParagraph(level: Int) -> NSParagraphStyle {
        let before: CGFloat
        let after: CGFloat
        switch level {
        case 1:
            before = 12
            after = headingRuleGap + 6
        case 2:
            before = 10
            after = headingRuleGap + 4
        default:
            before = 8
            after = 4
        }
        return bodyParagraph(spacingBefore: before, spacingAfter: after)
    }

    static func bodyParagraph(
        indent: CGFloat = 0,
        tailIndent: CGFloat = 0,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 4,
        alignment: NSTextAlignment = .left,
        lineHeight: CGFloat = 1.18
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore
        style.lineHeightMultiple = lineHeight
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.tailIndent = tailIndent == 0 ? 0 : -tailIndent
        style.alignment = alignment
        return style
    }
}

enum StyleEngine {
    static func apply(
        to storage: NSTextStorage,
        mode: EditorMode,
        settings: EditorSettings,
        selection _: NSRange,
        extraBlockSpacing: [Int: CGFloat] = [:]
    ) {
        let full = NSRange(location: 0, length: storage.length)
        let body = Theme.bodyFont(settings)
        let bodyColor = Theme.bodyColor(darkPaper: settings.darkPaper)
        let baseStyle = Theme.bodyParagraph()
        storage.setAttributes([
            .font: body,
            .foregroundColor: bodyColor,
            .paragraphStyle: baseStyle
        ], range: full)

        guard storage.length > 0 else { return }
        let spans = MarkdownSyntax.spans(in: storage.string)
        let ns = storage.string as NSString
        for span in spans {
            guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
            if case .table = span.kind, mode == .wysiwyg {
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -1
                ], range: span.range)
                if NSMaxRange(span.range) == NSMaxRange(span.group) {
                    let lastLine = ns.lineRange(for: NSRange(location: max(span.group.location, NSMaxRange(span.group) - 1), length: 0))
                    if lastLine.length > 0, NSMaxRange(lastLine) <= storage.length {
                        let extra = extraBlockSpacing[span.group.location] ?? 0
                        storage.addAttributes([
                            .paragraphStyle: Theme.bodyParagraph(spacingAfter: extra)
                        ], range: lastLine)
                    }
                }
                continue
            }

            if span.role == .marker && mode == .wysiwyg {
                var hide: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -1
                ]
                if case .codeBlock = span.kind {
                    let isOpen = span.range.location == span.group.location
                    hide[.paragraphStyle] = Theme.bodyParagraph(
                        indent: 16,
                        tailIndent: 16,
                        spacingBefore: isOpen ? 6 : 8,
                        spacingAfter: isOpen ? 10 : 6
                    )
                }
                storage.addAttributes(hide, range: span.range)
                continue
            }
            storage.addAttributes(
                attributes(span: span, settings: settings, markerRevealed: span.role == .marker, mode: mode),
                range: span.range
            )
        }
        if mode == .wysiwyg {
            for span in spans {
                if case .heading(let level) = span.kind, span.role == .content {
                    let line = ns.lineRange(for: NSRange(location: span.group.location, length: 0))
                    if line.length > 0, NSMaxRange(line) <= storage.length {
                        storage.addAttributes([
                            .paragraphStyle: Theme.headingParagraph(level: level)
                        ], range: line)
                    }
                }
                if case .heading = span.kind, span.role == .marker {
                    let line = ns.lineRange(for: NSRange(location: span.range.location, length: 0))
                    var text = ns.substring(with: line)
                    if text.hasSuffix("\n") { text.removeLast() }
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "=" || $0 == "-" }) {
                        storage.addAttributes([
                            .font: NSFont.systemFont(ofSize: 0.01),
                            .foregroundColor: NSColor.clear,
                            .kern: -1,
                            .paragraphStyle: Theme.bodyParagraph(spacingBefore: 0, spacingAfter: 0, lineHeight: 0.01)
                        ], range: line)
                    }
                }
            }
            for span in spans {
                guard case .link = span.kind, span.role == .content else { continue }
                guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
                storage.addAttributes([
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .cursor: NSCursor.pointingHand
                ], range: span.range)
            }
            for span in spans where span.role == .marker {
                guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -1
                ], range: span.range)
            }
        }
    }

    static func attributes(span: StyleSpan, settings: EditorSettings, markerRevealed: Bool, mode: EditorMode) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        let body = Theme.bodyFont(settings)
        let bodyColor = Theme.bodyColor(darkPaper: settings.darkPaper)
        if markerRevealed {
            attrs[.font] = body.withSize(max(9, settings.fontSize * 0.85))
            attrs[.foregroundColor] = NSColor.tertiaryLabelColor
        }
        switch span.kind {
        case .heading(let level):
            if span.role == .content {
                attrs[.font] = Theme.headingFont(settings, level: level)
                attrs[.foregroundColor] = bodyColor
                attrs[.paragraphStyle] = Theme.headingParagraph(level: level)
            }
        case .strong:
            if span.role == .content {
                attrs[.font] = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
                attrs[.foregroundColor] = bodyColor
            }
        case .emphasis:
            if span.role == .content {
                attrs[.font] = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
                attrs[.foregroundColor] = bodyColor
            }
        case .strikethrough:
            if span.role == .content {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = bodyColor
            }
        case .inlineCode:
            if span.role == .content {
                attrs[.font] = Theme.codeFont(settings)
                attrs[.backgroundColor] = Theme.inlineCodeFill(darkPaper: settings.darkPaper)
                attrs[.foregroundColor] = bodyColor
                attrs[.baselineOffset] = 1
                attrs[.kern] = 0.4
            }
        case .codeBlock:
            attrs[.font] = Theme.codeFont(settings)
            attrs[.foregroundColor] = bodyColor
            attrs[.backgroundColor] = NSColor.clear
            attrs[.paragraphStyle] = Theme.bodyParagraph(
                indent: 16,
                tailIndent: 16,
                spacingBefore: 2,
                spacingAfter: 2,
                lineHeight: 1.45
            )
        case .blockquote:
            if span.role == .content {
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                attrs[.paragraphStyle] = Theme.bodyParagraph(indent: 18, spacingAfter: 4)
            }
        case .list:
            if span.role == .content {
                attrs[.paragraphStyle] = Theme.bodyParagraph(indent: 18, spacingAfter: 2)
            }
        case .link:
            if span.role == .content {
                attrs[.foregroundColor] = NSColor.systemBlue
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if mode == .wysiwyg {
                    attrs[.cursor] = NSCursor.pointingHand
                }
            }
        case .image:
            if span.role == .content {
                attrs[.foregroundColor] = NSColor.systemBlue
            }
        case .table:
            attrs[.font] = Theme.codeFont(settings)
        case .thematicBreak:
            attrs[.foregroundColor] = NSColor.separatorColor
            attrs[.paragraphStyle] = Theme.bodyParagraph(spacingBefore: 12, spacingAfter: 12, alignment: .center)
        case .pageBreak:
            attrs[.foregroundColor] = NSColor.systemOrange
            attrs[.paragraphStyle] = Theme.bodyParagraph(spacingBefore: 12, spacingAfter: 12, alignment: .center)
        case .paragraph, .syntax:
            break
        }
        if mode == .source, markerRevealed || span.role == .marker {
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
            attrs[.font] = body
        }
        return attrs
    }
}

extension NSFont {
    func withSize(_ size: CGFloat) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: size) ?? self
    }
}
