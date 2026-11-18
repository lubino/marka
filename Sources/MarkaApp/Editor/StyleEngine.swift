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
        NSFont.monospacedSystemFont(ofSize: max(10, settings.fontSize - 1), weight: .regular)
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
        darkPaper ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1)
    }

    static func paperColor(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.12, alpha: 1) : .white
    }

    static func canvasColor(darkPaper: Bool) -> NSColor {
        if darkPaper { return NSColor(white: 0.08, alpha: 1) }
        return NSColor(calibratedWhite: 0.78, alpha: 1)
    }

    static func bodyParagraph(indent: CGFloat = 0, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 8, alignment: NSTextAlignment = .left) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore
        style.lineHeightMultiple = 1.18
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.alignment = alignment
        return style
    }
}

enum StyleEngine {
    static func apply(
        to storage: NSTextStorage,
        mode: EditorMode,
        settings: EditorSettings,
        selection: NSRange
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
        for span in spans {
            guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
            let caretInGroup = NSLocationInRange(selection.location, span.group)
                || selection.location == NSMaxRange(span.group)
                || NSIntersectionRange(selection, span.group).length > 0
            if span.role == .marker && mode == .wysiwyg && !caretInGroup {
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -1
                ], range: span.range)
                continue
            }
            storage.addAttributes(
                attributes(span: span, settings: settings, markerRevealed: span.role == .marker, mode: mode),
                range: span.range
            )
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
                attrs[.paragraphStyle] = Theme.bodyParagraph(spacingBefore: level == 1 ? 18 : 14, spacingAfter: 8)
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
                attrs[.backgroundColor] = NSColor(white: settings.darkPaper ? 0.2 : 0.94, alpha: 1)
                attrs[.foregroundColor] = bodyColor
            }
        case .codeBlock:
            attrs[.font] = Theme.codeFont(settings)
            attrs[.backgroundColor] = NSColor(white: settings.darkPaper ? 0.18 : 0.95, alpha: 1)
            attrs[.paragraphStyle] = Theme.bodyParagraph(spacingBefore: 8, spacingAfter: 8)
        case .blockquote:
            if span.role == .content {
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                attrs[.paragraphStyle] = Theme.bodyParagraph(indent: 18, spacingAfter: 8)
            }
        case .list:
            if span.role == .content {
                attrs[.paragraphStyle] = Theme.bodyParagraph(indent: 18, spacingAfter: 4)
            }
        case .link:
            if span.role == .content {
                attrs[.foregroundColor] = NSColor.systemBlue
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        case .image:
            if span.role == .content {
                attrs[.foregroundColor] = NSColor.systemBlue
            }
        case .table:
            attrs[.font] = Theme.codeFont(settings)
            attrs[.backgroundColor] = NSColor(white: settings.darkPaper ? 0.16 : 0.97, alpha: 1)
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
