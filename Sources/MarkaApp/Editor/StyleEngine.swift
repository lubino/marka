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
        NSFont.monospacedSystemFont(ofSize: max(9, settings.fontSize), weight: .regular)
    }

    static func font(named name: String, size: CGFloat, weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign) -> NSFont {
        if let named = NSFont(name: name, size: size) { return named }
        let lowered = name.lowercased()
        if lowered.contains("new york") {
            if let ny = NSFont(name: "NewYork-Regular", size: size) { return ny }
            if let ny = NSFont(name: ".NewYork-Regular", size: size) { return ny }
        }
        if lowered == "sf pro" || lowered == "system" {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        let mask: NSFontTraitMask = weight >= .semibold ? .boldFontMask : []
        if let family = NSFontManager.shared.font(withFamily: name, traits: mask, weight: 5, size: size) {
            return family
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
        return NSColor(calibratedWhite: 0.93, alpha: 1)
    }

    /// Preview titlebar: light gray, only slightly frosted — not clear glass.
    static func chromeColor(darkPaper: Bool) -> NSColor {
        if darkPaper { return NSColor(white: 0.16, alpha: 1) }
        return NSColor(calibratedWhite: 0.95, alpha: 1)
    }

    /// Preview-style thumbnail highlight: a light gray-blue rounded box around the page and number.
    static func thumbnailSelectionFill(darkPaper: Bool) -> NSColor {
        if darkPaper {
            return NSColor(srgbRed: 0.32, green: 0.38, blue: 0.46, alpha: 1)
        }
        return NSColor(srgbRed: 0.84, green: 0.89, blue: 0.94, alpha: 1)
    }

    /// GitHub light `pre` / `.highlight` fill `#f6f8fa`.
    static func codeBlockFill(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.16, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
    }

    static func codeBlockBorder(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.28, alpha: 1) : NSColor(srgbRed: 0.816, green: 0.843, blue: 0.871, alpha: 1)
    }

    /// Secondary text *on the paper* (code-block language, image placeholders): a fixed colour for
    /// the paper, never a dynamic system colour. Dynamic colours follow the window's appearance
    /// (wrong on white paper in dark mode) and were resolved to nil when pages were drawn
    /// off-screen for thumbnails — CoreText then aborted copying the text attributes
    /// ("attempt to insert nil object").
    static func paperSecondaryText(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(srgbRed: 0.62, green: 0.65, blue: 0.69, alpha: 1) : NSColor(srgbRed: 0.40, green: 0.44, blue: 0.49, alpha: 1)
    }

    /// The monospaced label font, created once.
    @MainActor static let codeLabelFont: NSFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    static func drawCodeBlockFill(in rect: CGRect, darkPaper: Bool) {
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        codeBlockFill(darkPaper: darkPaper).setFill()
        path.fill()
        codeBlockBorder(darkPaper: darkPaper).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// GitHub (Primer) syntax palette, light and dark.
    static func syntaxColor(_ kind: SyntaxHighlighter.Kind, darkPaper: Bool) -> NSColor {
        func hex(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        switch (kind, darkPaper) {
        case (.keyword, false): return hex(0xCF222E)
        case (.keyword, true): return hex(0xFF7B72)
        case (.string, false): return hex(0x0A3069)
        case (.string, true): return hex(0xA5D6FF)
        case (.number, false), (.constant, false), (.attribute, false), (.property, false), (.variable, false): return hex(0x0550AE)
        case (.number, true), (.constant, true), (.attribute, true), (.property, true), (.variable, true): return hex(0x79C0FF)
        case (.comment, false): return hex(0x6E7781)
        case (.comment, true): return hex(0x8B949E)
        case (.type, false): return hex(0x953800)
        case (.type, true): return hex(0xFFA657)
        case (.function, false), (.meta, false): return hex(0x8250DF)
        case (.function, true), (.meta, true): return hex(0xD2A8FF)
        case (.tag, false): return hex(0x116329)
        case (.tag, true): return hex(0x7EE787)
        }
    }

    /// GitHub inline code box: rgba(175,184,193,0.2) on paper; rgba(110,118,129,0.4) on dark paper.
    static func inlineCodeBox(darkPaper: Bool) -> NSColor {
        darkPaper
            ? NSColor(srgbRed: 110 / 255, green: 118 / 255, blue: 129 / 255, alpha: 0.4)
            : NSColor(srgbRed: 175 / 255, green: 184 / 255, blue: 193 / 255, alpha: 0.2)
    }
    /// Horizontal padding inside an inline code box (the hidden backticks carry it as kern).
    static let inlineCodePadding: CGFloat = 4
    static let inlineCodeRadius: CGFloat = 4

    static func inlineCodeFill(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.22, alpha: 1) : NSColor(srgbRed: 0.175, green: 0.184, blue: 0.193, alpha: 0.12)
    }

    static func tableHeaderFill(darkPaper: Bool) -> NSColor {
        darkPaper ? NSColor(white: 0.18, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
    }

    static func tableBorder(darkPaper: Bool) -> NSColor {
        codeBlockBorder(darkPaper: darkPaper)
    }

    static func collapsedTableParagraph(spacingAfter: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = 0
        style.lineHeightMultiple = 0.01
        style.minimumLineHeight = 0.4
        style.maximumLineHeight = 0.4
        style.lineSpacing = 0
        return style
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

extension NSAttributedString.Key {
    /// Marks a whole inline-code group (backticks + content); `MarkdownTextView` draws its rounded box.
    static let markaInlineCode = NSAttributedString.Key("MarkaInlineCode")
    /// Marks a hidden inline `$…$` group; the value is the LaTeX source to draw.
    static let markaInlineMath = NSAttributedString.Key("MarkaInlineMath")
    /// An emoji drawn over its hidden `:shortcode:` (Settings → emoji shortcodes).
    static let markaEmoji = NSAttributedString.Key("MarkaEmoji")
}

enum StyleEngine {
    static func apply(
        to storage: NSTextStorage,
        mode: EditorMode,
        settings: EditorSettings,
        selection: NSRange,
        extraBlockSpacing: [Int: CGFloat] = [:],
        limit: NSRange? = nil
    ) {
        let full = NSRange(location: 0, length: storage.length)
        let body = Theme.bodyFont(settings)
        let bodyColor = Theme.bodyColor(darkPaper: settings.darkPaper)
        let baseStyle = Theme.bodyParagraph()
        guard storage.length > 0 else {
            storage.setAttributes([.font: body, .foregroundColor: bodyColor, .paragraphStyle: baseStyle], range: full)
            return
        }
        let ns = storage.string as NSString
        let allSpans = MarkdownSyntax.spans(in: storage.string)
        // Incremental restyle: only the edited lines, grown to every span group that touches them
        // (a code fence, a table, a setext heading) until stable — so each span used below lies
        // wholly inside `region`, and the cost no longer grows with the document.
        var region = full
        var spans = allSpans
        if let limit, NSMaxRange(limit) <= storage.length {
            // One line of context each side: a setext underline (=== / ---) styles the line above.
            let start = limit.location > 0 ? ns.lineRange(for: NSRange(location: max(0, ns.lineRange(for: NSRange(location: limit.location, length: 0)).location - 1), length: 0)).location : 0
            let endLine = ns.lineRange(for: NSRange(location: min(ns.length, NSMaxRange(limit)), length: 0))
            let end = NSMaxRange(endLine) < ns.length ? NSMaxRange(ns.lineRange(for: NSRange(location: NSMaxRange(endLine), length: 0))) : ns.length
            region = NSRange(location: start, length: end - start)
            for _ in 0..<8 {
                var grown = region
                for span in allSpans where NSIntersectionRange(span.group, grown).length > 0
                    || NSLocationInRange(span.group.location, grown) || NSLocationInRange(grown.location, span.group) {
                    grown = NSUnionRange(grown, span.group)
                }
                grown = ns.lineRange(for: grown)
                if grown == region { break }
                region = grown
            }
            spans = allSpans.filter { NSIntersectionRange($0.group, region).length > 0 || NSLocationInRange($0.group.location, region) }
        }
        storage.setAttributes([
            .font: body,
            .foregroundColor: bodyColor,
            .paragraphStyle: baseStyle
        ], range: region)
        for span in spans {
            guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
            if case .table = span.kind, mode == .wysiwyg {
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -20,
                    .paragraphStyle: Theme.collapsedTableParagraph()
                ], range: span.range)
                if NSMaxRange(span.range) == NSMaxRange(span.group) {
                    let lastLine = ns.lineRange(for: NSRange(location: max(span.group.location, NSMaxRange(span.group) - 1), length: 0))
                    if lastLine.length > 0, NSMaxRange(lastLine) <= storage.length {
                        let extra = extraBlockSpacing[span.group.location] ?? 0
                        storage.addAttributes([
                            .paragraphStyle: Theme.collapsedTableParagraph(spacingAfter: extra)
                        ], range: lastLine)
                    }
                }
                continue
            }

            if span.kind == .keyboard, span.role == .marker, mode == .wysiwyg {
                storage.addAttribute(.markaInlineCode, value: true, range: span.group)
            }
            if case .inlineCode = span.kind, span.role == .marker {
                storage.addAttribute(.markaInlineCode, value: true, range: span.group)
            }
            // Bold / italic content is styled in its own pass below (after every other font is set).
            if span.role == .content, span.kind == .strong || span.kind == .emphasis { continue }
            if span.role == .marker && mode == .wysiwyg {
                var hide: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -1
                ]
                if case .inlineCode = span.kind {
                    // The hidden backticks become the box's left/right padding.
                    hide[.kern] = Theme.inlineCodePadding / CGFloat(max(1, span.range.length))
                }
                if span.kind == .keyboard {
                    // Padding comes from the content's ends (below); the tags take no room.
                    hide[.kern] = 0
                }
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
        // Bold / italic add a trait to whatever font is already there, so `code`, links and nested
        // emphasis inside **…** / *…* keep their own font (monospaced bold, …).
        for span in spans where span.role == .content && (span.kind == .strong || span.kind == .emphasis) {
            guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
            let trait: NSFontTraitMask = span.kind == .strong ? .boldFontMask : .italicFontMask
            storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                let font = (value as? NSFont) ?? body
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: range)
            }
            storage.addAttribute(.foregroundColor, value: bodyColor, range: span.range)
        }
        // <kbd>: the box's right padding on the key's last character (left: on the opening tag, below).
        if mode == .wysiwyg {
            for span in spans where span.kind == .keyboard && span.role == .content && span.range.length > 0 {
                guard NSMaxRange(span.range) <= storage.length, span.range.location > 0 else { continue }
                storage.addAttribute(.kern, value: Theme.inlineCodePadding, range: NSRange(location: NSMaxRange(span.range) - 1, length: 1))
            }
        }
        // Superscript / subscript shrink whatever font is there and move it off the baseline.
        for span in spans where span.role == .content && (span.kind == .superscript || span.kind == .subscript) {
            guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
            let up = span.kind == .superscript
            storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                let font = (value as? NSFont) ?? body
                storage.addAttributes([
                    .font: font.withSize(font.pointSize * 0.72),
                    .baselineOffset: up ? font.pointSize * 0.38 : -font.pointSize * 0.14
                ], range: range)
            }
        }
        highlightCode(in: storage, spans: spans, darkPaper: settings.darkPaper)
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
                if case .inlineCode = span.kind { continue }   // keeps its padding kern
                if case .inlineMath = span.kind { continue }   // styled (hidden or revealed) below
                if span.kind == .keyboard {
                    // <kbd> tags take no room; the opening one carries the box's left padding.
                    storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .kern: 0], range: span.range)
                    if span.range.location == span.group.location {
                        storage.addAttribute(.kern, value: Theme.inlineCodePadding, range: NSRange(location: NSMaxRange(span.range) - 1, length: 1))
                    }
                    continue
                }
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -1
                ], range: span.range)
            }
            // Inline math `$…$`: hidden source with the formula's width reserved (kern on the closing
            // `$`); `MarkdownTextView` draws the formula. With the caret inside, the source shows.
            for span in spans where span.kind == .inlineMath && span.role == .content {
                let group = span.group
                guard group.length > 1, NSMaxRange(group) <= storage.length else { continue }
                let caretInside = selection.location >= group.location && selection.location <= NSMaxRange(group)
                    || NSIntersectionRange(selection, group).length > 0
                if caretInside {
                    storage.addAttributes([
                        .font: Theme.codeFont(settings).withSize(max(8, settings.fontSize * 0.9)),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .kern: 0
                    ], range: group)
                    continue
                }
                let latex = ns.substring(with: span.range)
                let rendered = MathRenderer.render(latex, fontSize: settings.fontSize, color: bodyColor, display: false)
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: 0,
                    .markaInlineMath: latex
                ], range: group)
                storage.addAttribute(.kern, value: rendered.image.size.width, range: NSRange(location: NSMaxRange(group) - 1, length: 1))
            }
            // :shortcodes: as emoji (GitHub renders them; off by default). With the caret inside, the
            // code shows so it can be edited.
            if settings.emojiShortcodes {
                for match in EmojiCatalog.matches(in: storage.string, includeEmoticons: false)
                    where NSIntersectionRange(match.range, region).length == match.range.length {
                    let caretInside = selection.location > match.range.location && selection.location < NSMaxRange(match.range)
                        || NSIntersectionRange(selection, match.range).length > 0
                    guard !caretInside else { continue }
                    let width = (match.emoji as NSString).size(withAttributes: [.font: body]).width
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 0.01),
                        .foregroundColor: NSColor.clear,
                        .kern: 0,
                        .markaEmoji: match.emoji
                    ], range: match.range)
                    storage.addAttribute(.kern, value: width, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
                }
            }
            // Drawn blocks (```math, $$…$$, ```mermaid): collapse the source like a table's and
            // reserve the drawing's height after its last line.
            for span in spans {
                guard case .codeBlock(let language) = span.kind, MarkdownSyntax.isRendered(language: language),
                      span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: 0,
                    .paragraphStyle: Theme.collapsedTableParagraph()
                ], range: span.range)
                if NSMaxRange(span.range) == NSMaxRange(span.group) {
                    let lastLine = ns.lineRange(for: NSRange(location: max(span.group.location, NSMaxRange(span.group) - 1), length: 0))
                    if lastLine.length > 0, NSMaxRange(lastLine) <= storage.length {
                        storage.addAttribute(.paragraphStyle,
                                             value: Theme.collapsedTableParagraph(spacingAfter: extraBlockSpacing[span.group.location] ?? 0),
                                             range: lastLine)
                    }
                }
            }
            // GitHub alerts: "[!NOTE]" is hidden; its line stays a full-height title row where the
            // quote chrome draws the icon and title. Alert text keeps the body colour (GitHub).
            for alert in MarkdownSyntax.alerts(in: storage.string) where NSMaxRange(alert.group) <= storage.length
                && NSIntersectionRange(alert.group, region).length > 0 {
                storage.addAttribute(.foregroundColor, value: bodyColor, range: alert.group)
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .kern: 0], range: alert.marker)
                let titleLine = ns.lineRange(for: alert.marker)
                let title = Theme.bodyParagraph(indent: 18, spacingAfter: 2).mutableCopy() as! NSMutableParagraphStyle
                title.minimumLineHeight = ceil(settings.fontSize * 1.6)
                title.paragraphSpacingBefore = 4
                storage.addAttribute(.paragraphStyle, value: title, range: titleLine)
            }
            // Images (GitHub look): the `![alt](src)` source is hidden and the picture is drawn in
            // space reserved after its line; a line of only images collapses so they take its place.
            for imageLine in MarkdownSyntax.imageLines(in: storage.string, spans: spans) {
                let lineRange = ns.lineRange(for: imageLine.line)
                guard NSMaxRange(lineRange) <= storage.length else { continue }
                let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .kern: 0]
                let extra = extraBlockSpacing[imageLine.line.location] ?? 0
                if imageLine.imageOnly {
                    storage.addAttributes(hidden, range: lineRange)
                    storage.addAttribute(.paragraphStyle, value: Theme.collapsedTableParagraph(spacingAfter: extra), range: lineRange)
                } else {
                    for image in imageLine.images where NSMaxRange(image.fullRange) <= storage.length {
                        storage.addAttributes(hidden, range: image.fullRange)
                    }
                    let current = (storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle) ?? baseStyle
                    let style = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    style.paragraphSpacing = current.paragraphSpacing + extra
                    storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                }
            }
            // Last: a table's GFM source sits under the opaque table overlay and must stay invisible.
            // Inline passes above (code font, link blue, bold colour) would otherwise leak cell text
            // ("Boldcodelink…") around the table.
            for span in spans {
                guard case .table = span.kind, span.range.length > 0, NSMaxRange(span.range) <= storage.length else { continue }
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear,
                    .kern: -20
                ], range: span.range)
                storage.removeAttribute(.markaInlineCode, range: span.range)
                storage.removeAttribute(.underlineStyle, range: span.range)
                storage.removeAttribute(.strikethroughStyle, range: span.range)
            }
        }
    }

    /// Colours fenced code by its info-string language. Foreground colour only: layout never changes.
    static func highlightCode(in storage: NSTextStorage, spans: [StyleSpan], darkPaper: Bool) {
        let ns = storage.string as NSString
        for span in spans where span.role == .content {
            guard case .codeBlock(let language) = span.kind,
                  span.range.length > 0, NSMaxRange(span.range) <= storage.length,
                  let lang = SyntaxHighlighter.language(for: language) else { continue }
            let code = ns.substring(with: span.range)
            for token in SyntaxHighlighter.tokens(in: code, language: lang) {
                let range = NSRange(location: span.range.location + token.range.location, length: token.range.length)
                guard NSMaxRange(range) <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.syntaxColor(token.kind, darkPaper: darkPaper), range: range)
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
                attrs[.font] = Theme.codeFont(settings).withSize(max(8, settings.fontSize * 0.9))
                attrs[.foregroundColor] = bodyColor
                attrs[.kern] = 0.2
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
        case .inlineMath:
            break   // drawn by MarkdownTextView (WYSIWYG) / shown as source
        case .underline:
            if span.role == .content { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        case .superscript, .subscript:
            break   // sized in their own pass (after every other font is set)
        case .keyboard:
            if span.role == .content {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: settings.fontSize * 0.85, weight: .regular)
            }
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
