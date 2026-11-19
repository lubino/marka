import Foundation

/// Plain-text find & replace over the Markdown source (UTF-16 ranges, no regex surprises).
public enum FindEngine {
    public struct Options: Equatable, Sendable {
        public var caseSensitive: Bool
        public var wholeWord: Bool
        public init(caseSensitive: Bool = false, wholeWord: Bool = false) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
        }
    }

    public static func matches(of query: String, in source: String, options: Options = Options()) -> [NSRange] {
        let ns = source as NSString
        let needle = query as NSString
        guard needle.length > 0, ns.length >= needle.length else { return [] }
        var compare: NSString.CompareOptions = [.literal]
        if !options.caseSensitive { compare.insert(.caseInsensitive) }
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: query, options: compare, range: search)
            guard found.location != NSNotFound, found.length > 0 else { break }
            if !options.wholeWord || isWholeWord(found, in: ns) {
                result.append(found)
            }
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: ns.length - next)
        }
        return result
    }

    /// Index of the first match at or after `location` (wrapping), or nil when there are none.
    public static func nextIndex(in matches: [NSRange], after location: Int, backwards: Bool = false) -> Int? {
        guard !matches.isEmpty else { return nil }
        if backwards {
            return matches.lastIndex { $0.location < location } ?? matches.count - 1
        }
        return matches.firstIndex { $0.location >= location } ?? 0
    }

    /// Replaces every match; returns the new text and how many replacements were made.
    public static func replaceAll(_ query: String, with replacement: String, in source: String, options: Options = Options()) -> (text: String, count: Int) {
        let found = matches(of: query, in: source, options: options)
        guard !found.isEmpty else { return (source, 0) }
        let result = NSMutableString(string: source)
        for range in found.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return (result as String, found.count)
    }

    private static func isWholeWord(_ range: NSRange, in ns: NSString) -> Bool {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWordChar(at index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
            return word.contains(scalar)
        }
        return !isWordChar(at: range.location - 1) && !isWordChar(at: NSMaxRange(range))
    }
}
