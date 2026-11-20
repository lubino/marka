import Foundation

/// Images as GitHub shows them: the `![alt](src)` source is hidden and the picture takes its own
/// space. A line made only of images (optionally linked, like README badges) is replaced by them;
/// images inside a line of text are drawn below that line.
public struct MarkdownImage: Equatable, Sendable {
    /// The whole `![alt](src "title")` or `<img …>`.
    public var group: NSRange
    /// Source as written (title removed): `assets/a.png`, `https://…`.
    public var source: String
    public var alt: String
    /// Range of the source inside the Markdown (for replacing it).
    public var sourceRange: NSRange
    public var title = ""
    /// `<img width="300">` / `"50%"`; empty = natural size.
    public var width = ""
    public var height = ""
    /// "left", "center" (a `<p align="center">` wrapper) or "right"; empty = default.
    public var align = ""
    public var isHTML = false
    /// `<p align="center"><img …></p>` around a centred image.
    public var wrapper: NSRange?

    /// What replacing or removing the image replaces.
    public var fullRange: NSRange { wrapper ?? group }

    public init(group: NSRange, source: String, alt: String, sourceRange: NSRange) {
        self.group = group
        self.source = source
        self.alt = alt
        self.sourceRange = sourceRange
    }
}

/// Image display options GitHub understands (`<img width height align alt title>`).
public struct ImageOptions: Equatable, Sendable {
    public var alt = ""
    public var title = ""
    public var width = ""
    public var height = ""
    /// "", "left", "center", "right"
    public var align = ""

    public init(alt: String = "", title: String = "", width: String = "", height: String = "", align: String = "") {
        self.alt = alt
        self.title = title
        self.width = width
        self.height = height
        self.align = align
    }

    public init(_ image: MarkdownImage) {
        self.init(alt: image.alt, title: image.title, width: image.width, height: image.height, align: image.align)
    }

    /// Plain Markdown is enough (no size, no alignment).
    public var isPlain: Bool { width.isEmpty && height.isEmpty && align.isEmpty }
}

public struct ImageLine: Equatable, Sendable {
    /// The line (without its newline).
    public var line: NSRange
    public var images: [MarkdownImage]
    /// Nothing but images (and links around them / whitespace) on the line.
    public var imageOnly: Bool
}

extension MarkdownSyntax {
    /// Every line holding images, outside code blocks and tables.
    public static func imageLines(in source: String) -> [ImageLine] {
        imageLines(in: source, spans: spans(in: source))
    }

    public static func imageLines(in source: String, spans: [StyleSpan]) -> [ImageLine] {
        let ns = source as NSString
        let excluded = spans.compactMap { span -> NSRange? in
            switch span.kind {
            case .table, .codeBlock, .inlineCode: return span.group
            default: return nil
            }
        }
        var images: [Int: MarkdownImage] = [:]
        var linkMarkers: [NSRange] = []
        for span in spans {
            switch span.kind {
            case .image(let url):
                guard !excluded.contains(where: { NSLocationInRange(span.group.location, $0) }) else { continue }
                var image = images[span.group.location] ?? MarkdownImage(group: span.group, source: "", alt: "", sourceRange: NSRange(location: 0, length: 0))
                if span.role == .content { image.alt = ns.substring(with: span.range) }
                if image.source.isEmpty {
                    let parsed = parseImageSource(ns, group: span.group)
                    image.source = parsed?.source ?? url
                    image.sourceRange = parsed?.range ?? NSRange(location: NSMaxRange(span.group) - 1, length: 0)
                    image.title = parsed?.title ?? ""
                }
                images[span.group.location] = image
            case .link:
                if span.role == .marker { linkMarkers.append(span.range) }
            default:
                continue
            }
        }
        // HTML images: <img src="…" width="…" align="…">, optionally in <p align="center">…</p>.
        var htmlTags: [NSRange] = []
        for image in htmlImages(ns) where !excluded.contains(where: { NSLocationInRange(image.group.location, $0) }) {
            images[image.group.location] = image
            if let wrapper = image.wrapper { htmlTags.append(wrapper) }
        }
        var lines: [Int: ImageLine] = [:]
        for image in images.values.sorted(by: { $0.group.location < $1.group.location }) {
            var line = ns.lineRange(for: NSRange(location: image.group.location, length: 0))
            if NSMaxRange(line) > line.location, NSMaxRange(line) <= ns.length, ns.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
            lines[line.location, default: ImageLine(line: line, images: [], imageOnly: false)].images.append(image)
        }
        return lines.values.sorted { $0.line.location < $1.line.location }.map { entry in
            var line = entry
            // Image-only: blank out the images and the link markers around them; whitespace remains.
            var characters = Array(ns.substring(with: line.line).utf16)
            for range in line.images.map(\.group) + linkMarkers + htmlTags {
                let local = NSIntersectionRange(range, line.line)
                guard local.length > 0 else { continue }
                for i in (local.location - line.line.location)..<(NSMaxRange(local) - line.line.location) { characters[i] = 32 }
            }
            line.imageOnly = String(decoding: characters, as: UTF16.self).trimmingCharacters(in: .whitespaces).isEmpty
            return line
        }
    }

    /// `(src "title")` → the src and its range (angle brackets kept out).
    static func parseImageSource(_ ns: NSString, group: NSRange) -> (source: String, range: NSRange, title: String)? {
        let text = ns.substring(with: group) as NSString
        let open = text.range(of: "](", options: .backwards)
        guard open.location != NSNotFound, text.length >= 1, text.character(at: text.length - 1) == 41 else { return nil }
        var start = NSMaxRange(open)
        var end = text.length - 1   // the closing ")"
        while start < end, text.character(at: start) == 32 { start += 1 }
        if start < end, text.character(at: start) == 60 {   // `<path with spaces.png>`
            let close = text.range(of: ">", range: NSRange(location: start, length: end - start))
            if close.location != NSNotFound {
                return (text.substring(with: NSRange(location: start + 1, length: close.location - start - 1)),
                        NSRange(location: group.location + start, length: close.location - start + 1), "")
            }
        }
        // A title starts at the first space: `src "Title"`.
        var title = ""
        let space = text.range(of: " ", range: NSRange(location: start, length: end - start))
        if space.location != NSNotFound {
            title = text.substring(with: NSRange(location: space.location, length: end - space.location))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            end = space.location
        }
        return (text.substring(with: NSRange(location: start, length: end - start)), NSRange(location: group.location + start, length: end - start), title)
    }
}

extension MarkdownSyntax {
    nonisolated(unsafe) private static let imgTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
    nonisolated(unsafe) private static let attribute = try! NSRegularExpression(
        pattern: "([A-Za-z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [])
    nonisolated(unsafe) private static let centerWrapper = try! NSRegularExpression(
        pattern: "<p\\s+align\\s*=\\s*[\"']?(\\w+)[\"']?\\s*>\\s*(<img\\b[^>]*>)\\s*</p>", options: [.caseInsensitive])

    /// `<img …>` tags with their attributes (and a `<p align=…>` wrapper when it holds just the image).
    static func htmlImages(_ ns: NSString) -> [MarkdownImage] {
        let full = NSRange(location: 0, length: ns.length)
        var wrappers: [Int: (NSRange, String)] = [:]
        for match in centerWrapper.matches(in: ns as String, range: full) {
            wrappers[match.range(at: 2).location] = (match.range, ns.substring(with: match.range(at: 1)).lowercased())
        }
        return imgTag.matches(in: ns as String, range: full).compactMap { match in
            let tag = match.range
            var values: [String: (String, NSRange)] = [:]
            for attr in attribute.matches(in: ns as String, range: tag) {
                let name = ns.substring(with: attr.range(at: 1)).lowercased()
                let valueRange = [2, 3, 4].map { attr.range(at: $0) }.first { $0.location != NSNotFound } ?? NSRange(location: NSMaxRange(attr.range), length: 0)
                values[name] = (ns.substring(with: valueRange), valueRange)
            }
            guard let src = values["src"] else { return nil }
            var image = MarkdownImage(group: tag, source: src.0, alt: values["alt"]?.0 ?? "", sourceRange: src.1)
            image.isHTML = true
            image.title = values["title"]?.0 ?? ""
            image.width = values["width"]?.0 ?? ""
            image.height = values["height"]?.0 ?? ""
            image.align = (values["align"]?.0 ?? "").lowercased()
            if let wrapper = wrappers[tag.location] {
                image.wrapper = wrapper.0
                if image.align.isEmpty { image.align = wrapper.1 }
            }
            return image
        }
    }
}

extension MarkdownSyntax {
    /// Images inside table cells (Markdown and `<img>`), with document ranges. `imageLines`
    /// leaves them out: tables draw their own cells.
    public static func tableImages(in source: String) -> [MarkdownImage] {
        let ns = source as NSString
        var found: [MarkdownImage] = []
        let html = htmlImages(ns)
        for block in TableMutator.allBlocks(in: source) {
            for row in block.rows.indices where row != 1 {
                for column in 0..<block.columnCount {
                    guard let cell = TableMutator.cellRange(in: source, block: block, row: row, column: column), cell.length > 0 else { continue }
                    let text = ns.substring(with: cell)
                    for span in inlineSpans(in: text) where span.role == .marker && span.range.location == span.group.location {
                        guard case .image(let url) = span.kind else { continue }
                        let group = NSRange(location: cell.location + span.group.location, length: span.group.length)
                        let parsed = parseImageSource(ns, group: group)
                        var image = MarkdownImage(group: group, source: parsed?.source ?? url, alt: "",
                                                  sourceRange: parsed?.range ?? NSRange(location: NSMaxRange(group) - 1, length: 0))
                        image.title = parsed?.title ?? ""
                        let closeBracket = (text as NSString).range(of: "](", options: .backwards, range: span.group).location
                        if closeBracket != NSNotFound, closeBracket > span.group.location + 2 {
                            image.alt = (text as NSString).substring(with: NSRange(location: span.group.location + 2, length: closeBracket - span.group.location - 2))
                        }
                        found.append(image)
                    }
                    found += html.filter { NSLocationInRange($0.group.location, cell) && NSMaxRange($0.group) <= NSMaxRange(cell) }
                }
            }
        }
        return found.sorted { $0.group.location < $1.group.location }
    }

    /// `<img>` tags in a cell's text (ranges relative to it).
    public static func tableCellHTMLImages(_ text: NSString) -> [MarkdownImage] {
        htmlImages(text)
    }

    /// Any image — in the text or in a table cell — starting at `location`.
    public static func image(at location: Int, in source: String) -> MarkdownImage? {
        imageLines(in: source).flatMap(\.images).first { $0.group.location == location }
            ?? tableImages(in: source).first { $0.group.location == location }
    }
}

extension MarkdownEditing {
    /// Writes `options` for the image at `location`: plain `![alt](src "title")` when nothing
    /// special is set, otherwise GitHub's `<img>` (centred: inside `<p align="center">`).
    public static func setImageOptions(source: String, imageAt location: Int, options: ImageOptions) -> EditResult? {
        guard let image = MarkdownSyntax.image(at: location, in: source) else { return nil }
        // Inside a table cell a <p> wrapper would break the row: centre is plain <img> there.
        var options = options
        let inTable = MarkdownSyntax.tableImages(in: source).contains { $0.group.location == location }
        if inTable, options.align == "center" { options.align = "" }
        let markup = imageMarkup(source: image.source, options: options)
        let ns = source as NSString
        let text = ns.replacingCharacters(in: image.fullRange, with: markup)
        let inner = (markup as NSString).range(of: "<img")
        let start = image.fullRange.location + (inner.location == NSNotFound ? 0 : inner.location)
        return EditResult(text: text, selected: NSRange(location: start, length: 0))
    }

    public static func imageMarkup(source: String, options: ImageOptions) -> String {
        func attr(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        if options.isPlain {
            let title = options.title.isEmpty ? "" : " \"\(options.title.replacingOccurrences(of: "\"", with: "'"))\""
            return "![\(options.alt)](\(source)\(title))"
        }
        var tag = "<img src=\"\(attr(source))\" alt=\"\(attr(options.alt))\""
        if !options.title.isEmpty { tag += " title=\"\(attr(options.title))\"" }
        if !options.width.isEmpty { tag += " width=\"\(attr(options.width))\"" }
        if !options.height.isEmpty { tag += " height=\"\(attr(options.height))\"" }
        if options.align == "left" || options.align == "right" { tag += " align=\"\(options.align)\"" }
        tag += ">"
        return options.align == "center" ? "<p align=\"center\">\(tag)</p>" : tag
    }

    /// Points the image starting at `location` at `newSource` (alt text and title kept).
    public static func setImageSource(source: String, imageAt location: Int, to newSource: String) -> EditResult? {
        guard let image = MarkdownSyntax.image(at: location, in: source) else { return nil }
        let ns = source as NSString
        let replaced = ns.replacingCharacters(in: image.sourceRange, with: newSource)
        return EditResult(text: replaced, selected: NSRange(location: location, length: 0))
    }

    /// Removes the image starting at `location`; an image-only line goes away entirely.
    public static func removeImage(source: String, imageAt location: Int) -> EditResult? {
        let lines = MarkdownSyntax.imageLines(in: source)
        if let cellImage = MarkdownSyntax.tableImages(in: source).first(where: { $0.group.location == location }) {
            // In a table cell: just the image; the row stays.
            let text = (source as NSString).replacingCharacters(in: cellImage.group, with: "")
            return EditResult(text: text, selected: NSRange(location: cellImage.group.location, length: 0))
        }
        guard let line = lines.first(where: { $0.images.contains { $0.group.location == location } }),
              let image = line.images.first(where: { $0.group.location == location }) else { return nil }
        let ns = source as NSString
        var range = image.fullRange
        if line.imageOnly, line.images.count == 1 {
            range = ns.lineRange(for: line.line)   // with its newline
        }
        let text = ns.replacingCharacters(in: range, with: "")
        return EditResult(text: text, selected: NSRange(location: min(range.location, (text as NSString).length), length: 0))
    }
}

/// GitHub alerts: a quote whose first line is `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`
/// or `[!CAUTION]`.
public struct MarkdownAlert: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case note, tip, important, warning, caution
        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    public var kind: Kind
    /// The whole quote.
    public var group: NSRange
    /// `[!NOTE]` in the first line.
    public var marker: NSRange
}

extension MarkdownSyntax {
    public static func alerts(in source: String) -> [MarkdownAlert] {
        let ns = source as NSString
        return quotes(in: source).compactMap { quote in
            let first = ns.lineRange(for: NSRange(location: quote.group.location, length: 0))
            let text = ns.substring(with: first) as NSString
            let open = text.range(of: "[!")
            guard open.location != NSNotFound else { return nil }
            // Only "> [!KIND]" (optionally spaced) — anything else on the line makes it a plain quote.
            let before = text.substring(to: open.location).trimmingCharacters(in: .whitespaces)
            guard before == ">" else { return nil }
            let close = text.range(of: "]", range: NSRange(location: open.location, length: text.length - open.location))
            guard close.location != NSNotFound,
                  text.substring(from: NSMaxRange(close)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let kind = MarkdownAlert.Kind(rawValue: text.substring(with: NSRange(location: open.location + 2, length: close.location - open.location - 2)).lowercased())
            else { return nil }
            return MarkdownAlert(kind: kind, group: quote.group,
                                 marker: NSRange(location: first.location + open.location, length: NSMaxRange(close) - open.location))
        }
    }
}

extension MarkdownEditing {
    /// Inserts an empty GitHub alert block on its own lines; the caret goes to its text line.
    public static func insertAlert(source: String, selected: NSRange, kind: MarkdownAlert.Kind) -> EditResult {
        let ns = source as NSString
        let at = min(max(0, selected.location), ns.length)
        let inner = selected.length > 0 ? ns.substring(with: selected) : ""
        let needLeading = at > 0 && ns.character(at: at - 1) != 10
        let end = min(ns.length, at + selected.length)
        let needTrailing = end < ns.length && ns.character(at: end) != 10
        let body = inner.isEmpty ? "> " : inner.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        let block = (needLeading ? "\n" : "") + "> [!\(kind.rawValue.uppercased())]\n" + body + (needTrailing ? "\n" : "")
        let new = ns.replacingCharacters(in: NSRange(location: at, length: end - at), with: block)
        let caret = at + (block as NSString).length - (needTrailing ? 1 : 0)
        return EditResult(text: new, selected: NSRange(location: caret, length: 0))
    }
}
