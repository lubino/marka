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
