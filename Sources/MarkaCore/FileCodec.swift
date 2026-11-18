import Foundation

public struct FileCodec: Equatable, Sendable {
    public enum LineEnding: String, Equatable, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    public var hasUTF8BOM: Bool
    public var lineEnding: LineEnding

    public init(hasUTF8BOM: Bool = false, lineEnding: LineEnding = .lf) {
        self.hasUTF8BOM = hasUTF8BOM
        self.lineEnding = lineEnding
    }

    public static func decode(_ data: Data) -> (codec: FileCodec, normalized: String) {
        var payload = data
        var bom = false
        if payload.count >= 3 && payload[0] == 0xEF && payload[1] == 0xBB && payload[2] == 0xBF {
            bom = true
            payload = payload.dropFirst(3)
        }
        let raw = String(data: payload, encoding: .utf8) ?? String(decoding: payload, as: UTF8.self)
        let ending: LineEnding
        if raw.contains("\r\n") {
            ending = .crlf
        } else if raw.contains("\r") {
            ending = .cr
        } else {
            ending = .lf
        }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (FileCodec(hasUTF8BOM: bom, lineEnding: ending), normalized)
    }

    /// If `normalized` still equals the string loaded from `originalData`, return those bytes unchanged.
    public func encode(normalized: String, originalNormalized: String?, originalData: Data?) -> Data {
        if let originalData, let originalNormalized, normalized == originalNormalized {
            return originalData
        }
        var serialized = normalized
        if lineEnding != .lf {
            serialized = serialized.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        }
        var data = Data(serialized.utf8)
        if hasUTF8BOM {
            data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
        }
        return data
    }
}

public enum TextMetrics {
    public static func characterCount(_ string: String) -> Int {
        (string as NSString).length
    }

    public static func wordCount(_ string: String) -> Int {
        let ns = string as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard ns.length > 0 else { return 0 }
        var count = 0
        ns.enumerateSubstrings(in: range, options: [.byWords, .localized]) { substring, _, _, _ in
            if let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        return count
    }
}

public enum PageBreakMarker {
    public static let comment = "<!-- pagebreak -->"

    public static func isPageBreakLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == comment
    }

    public static func ranges(in source: String) -> [NSRange] {
        let ns = source as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.location < ns.length {
            let found = ns.range(of: comment, options: [], range: search)
            if found.location == NSNotFound { break }
            ranges.append(found)
            let next = found.location + found.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return ranges
    }
}
