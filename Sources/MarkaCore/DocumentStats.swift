import Foundation

/// Counts shown in the document info popover. Pure Markdown scan, no AppKit.
public struct DocumentStats: Equatable, Sendable {
    public var words = 0
    public var characters = 0
    public var charactersWithoutSpaces = 0
    public var lines = 0
    public var paragraphs = 0
    public var headings = 0
    public var links = 0
    public var images = 0
    public var tables = 0
    public var codeBlocks = 0
    public var tasks = 0
    public var completedTasks = 0

    /// Silent reading speed used for the estimate.
    public static let wordsPerMinute = 230

    public var readingMinutes: Int {
        words == 0 ? 0 : max(1, Int((Double(words) / Double(Self.wordsPerMinute)).rounded(.up)))
    }

    public init() {}

    public static func compute(_ source: String) -> DocumentStats {
        var stats = DocumentStats()
        stats.words = TextMetrics.wordCount(source)
        stats.characters = TextMetrics.characterCount(source)
        stats.charactersWithoutSpaces = source.unicodeScalars.reduce(0) { count, scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? count : count + scalar.utf16.count
        }
        guard !source.isEmpty else { return stats }

        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        stats.lines = lines.count

        var fence: String?
        var inParagraph = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) && line.drop(while: { String($0) == String(open.first!) }).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                continue
            }
            if let marker = fenceMarker(line) {
                fence = marker
                stats.codeBlocks += 1
                inParagraph = false
                continue
            }
            if line.isEmpty {
                inParagraph = false
                continue
            }
            if isHeading(line) {
                stats.headings += 1
                inParagraph = false
            } else if isTableDelimiter(line) {
                stats.tables += 1
                inParagraph = false
            } else if line.hasPrefix("|") || PageBreakMarker.isPageBreakLine(line) || isThematicBreak(line) {
                inParagraph = false
            } else if let done = taskState(line) {
                stats.tasks += 1
                if done { stats.completedTasks += 1 }
                inParagraph = false
            } else if !inParagraph {
                stats.paragraphs += 1
                inParagraph = true
            }
            stats.images += count(imagePattern, in: raw)
            stats.links += count(linkPattern, in: raw)
        }
        return stats
    }

    /// `![alt](src)` and GitHub's `<img …>` (image options write those).
    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)|<img\b[^>]*>"#, options: [.caseInsensitive])
    private static let linkPattern = try! NSRegularExpression(pattern: #"(?<!!)\[[^\]]*\]\([^)]*\)"#)
    private static let taskPattern = try! NSRegularExpression(pattern: #"^(?:[-*+]|\d+[.)])\s+\[([ xX])\]\s"#)

    private static func count(_ regex: NSRegularExpression, in line: String) -> Int {
        regex.numberOfMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private static func fenceMarker(_ line: String) -> String? {
        for char in ["`", "~"] where line.hasPrefix(String(repeating: char, count: 3)) {
            let run = line.prefix { String($0) == char }
            return String(run)
        }
        return nil
    }

    private static func isHeading(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " "
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard line.contains("|"), line.contains("-") else { return false }
        return line.allSatisfy { "|-: ".contains($0) }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func taskState(_ line: String) -> Bool? {
        let ns = line as NSString
        guard let match = taskPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)) != " "
    }
}
