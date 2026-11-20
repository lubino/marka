import Foundation

/// A heading as a link target: GitHub's anchor (`#slug`) and where it is.
public struct HeadingAnchor: Equatable, Sendable {
    public var level: Int
    /// Heading text without Markdown markers.
    public var title: String
    /// GitHub anchor without "#": "getting-started", "faq-1".
    public var slug: String
    /// Start of the heading's line.
    public var location: Int
}

extension MarkdownSyntax {
    /// Headings with GitHub-compatible anchors (repeated titles get -1, -2, … like GitHub).
    public static func headingAnchors(in source: String) -> [HeadingAnchor] {
        var used: [String: Int] = [:]
        return outline(in: source).map { heading in
            let title = plainText(heading.title)
            var slug = githubSlug(title)
            if let count = used[slug] {
                used[slug] = count + 1
                slug += "-\(count + 1)"
            } else {
                used[slug] = 0
            }
            return HeadingAnchor(level: heading.level, title: title, slug: slug, location: heading.range.location)
        }
    }

    /// GitHub's heading anchor: lowercase, punctuation removed (letters, digits, "-", "_" and
    /// spaces kept), spaces → "-".
    public static func githubSlug(_ title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "-" || scalar == "_" {
                slug.unicodeScalars.append(scalar)
            } else if scalar == " " {
                slug += "-"
            }
        }
        return slug
    }

    /// Inline Markdown as plain text: markers dropped (`**a** [b](c)` → "a b").
    public static func plainText(_ inline: String) -> String {
        let ns = inline as NSString
        var drop = Array(repeating: false, count: ns.length)
        for span in inlineSpans(in: inline) where span.role == .marker {
            for i in span.range.location..<min(ns.length, NSMaxRange(span.range)) { drop[i] = true }
        }
        var units: [unichar] = []
        for i in 0..<ns.length where !drop[i] { units.append(ns.character(at: i)) }
        return String(utf16CodeUnits: units, count: units.count).trimmingCharacters(in: .whitespaces)
    }

    /// The heading a `#slug` link points to.
    public static func heading(forAnchor anchor: String, in source: String) -> HeadingAnchor? {
        var slug = anchor.hasPrefix("#") ? String(anchor.dropFirst()) : anchor
        slug = (slug.removingPercentEncoding ?? slug).lowercased()
        return headingAnchors(in: source).first { $0.slug == slug }
    }
}

/// One list item as GitHub draws it: a bullet (by nesting level), a number, or a checkbox.
public struct ListItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bullet
        case ordered(Int)
        case task(checked: Bool)
    }
    /// The item's first line (without its newline).
    public var line: NSRange
    /// `- `, `1. `, `- [ ] ` including the indentation before it (hidden in WYSIWYG).
    public var marker: NSRange
    /// 0 = top level; one deeper for every further indentation.
    public var level: Int
    public var kind: Kind
    /// The `[ ]` / `[x]` of a task (what a click toggles).
    public var checkbox: NSRange?
}

extension MarkdownSyntax {
    /// List items of every list in `source` (numbering like GitHub: from the first item's number,
    /// counting up per nesting level).
    public static func listItems(in source: String) -> [ListItem] {
        listItems(in: source, spans: spans(in: source))
    }

    public static func listItems(in source: String, spans: [StyleSpan]) -> [ListItem] {
        let ns = source as NSString
        var items: [ListItem] = []
        var seen = Set<Int>()
        for span in spans where span.role == .content {
            guard case .list = span.kind, !seen.contains(span.group.location), NSMaxRange(span.group) <= ns.length else { continue }
            seen.insert(span.group.location)
            var indents: [Int] = []          // indentation of each open level
            var counters: [Int?] = []        // next number per level (nil: not an ordered level yet)
            var location = span.group.location
            while location < NSMaxRange(span.group) {
                var line = ns.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(line)
                if NSMaxRange(line) > line.location, ns.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
                let text = ns.substring(with: line)
                guard let prefix = parseListPrefix(text) else { continue }
                var indent = 0
                for ch in text { if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break } }
                while let last = indents.last, indent < last { indents.removeLast(); counters.removeLast() }
                if indents.last.map({ indent > $0 }) ?? true {
                    indents.append(indent)
                    counters.append(nil)
                }
                let level = indents.count - 1
                let marker = NSRange(location: line.location, length: prefix.markerLength)
                let kind: ListItem.Kind
                var checkbox: NSRange?
                if prefix.task {
                    let box = (text as NSString).range(of: "[", options: [], range: NSRange(location: indent, length: (text as NSString).length - indent))
                    checkbox = NSRange(location: line.location + box.location, length: 3)
                    let mark = (text as NSString).substring(with: NSRange(location: box.location + 1, length: 1))
                    kind = .task(checked: mark.lowercased() == "x")
                } else if prefix.ordered {
                    let digits = text.dropFirst(indent).prefix { $0.isNumber }
                    let next = counters[level] ?? Int(digits) ?? 1
                    kind = .ordered(next)
                    counters[level] = next + 1
                } else {
                    kind = .bullet
                }
                items.append(ListItem(line: line, marker: marker, level: level, kind: kind, checkbox: checkbox))
            }
        }
        return items.sorted { $0.line.location < $1.line.location }
    }
}

extension MarkdownEditing {
    /// Ticks or unticks the task whose `[ ]` / `[x]` is at `checkbox`.
    public static func toggleTask(source: String, checkbox: NSRange) -> EditResult? {
        let ns = source as NSString
        guard NSMaxRange(checkbox) <= ns.length, checkbox.length == 3 else { return nil }
        let box = ns.substring(with: checkbox)
        guard box.hasPrefix("["), box.hasSuffix("]") else { return nil }
        let mark = NSRange(location: checkbox.location + 1, length: 1)
        let checked = ns.substring(with: mark).lowercased() == "x"
        return EditResult(text: ns.replacingCharacters(in: mark, with: checked ? " " : "x"), selected: NSRange(location: NSMaxRange(checkbox) + 1, length: 0))
    }
}
