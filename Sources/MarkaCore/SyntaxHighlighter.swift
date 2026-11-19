import Foundation

/// Lightweight, dependency-free syntax highlighting for fenced code blocks.
///
/// Produces non-overlapping UTF-16 ranges (relative to the code string) so the editor can colour
/// the Markdown source 1:1 without changing a single character. Colouring only (no font changes),
/// so highlighting never changes layout.
public enum SyntaxHighlighter {
    public enum Kind: String, Sendable, CaseIterable {
        case keyword, string, number, comment, type, function, constant, tag, attribute, property, variable, meta
    }

    public struct Token: Equatable, Sendable {
        public var range: NSRange
        public var kind: Kind
        public init(range: NSRange, kind: Kind) {
            self.range = range
            self.kind = kind
        }
    }

    public enum Language: String, Sendable, CaseIterable {
        case bash, json, python, javascript, typescript, c, cpp, swift, html, xml, css, yaml
        case go, rust, java, kotlin, ruby, sql, php
    }

    /// Maps a fence info string (```` ```py ````, ```` ```C++ {.numberLines} ````) to a language.
    public static func language(for info: String?) -> Language? {
        guard let info else { return nil }
        let word = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? info
        switch word.lowercased() {
        case "bash", "sh", "zsh", "shell", "fish", "ksh", "console", "shellscript": return .bash
        case "json", "jsonc", "json5", "geojson": return .json
        case "python", "py", "python3", "py3": return .python
        case "javascript", "js", "jsx", "mjs", "cjs", "node": return .javascript
        case "typescript", "ts", "tsx": return .typescript
        case "c", "h", "objc", "objective-c": return .c
        case "cpp", "c++", "cc", "cxx", "hpp", "hh", "hxx": return .cpp
        case "swift": return .swift
        case "html", "htm", "xhtml", "vue", "svelte": return .html
        case "xml", "plist", "svg", "xaml", "xsd", "xsl", "rss", "atom": return .xml
        case "css", "scss", "less": return .css
        case "yaml", "yml": return .yaml
        case "go", "golang": return .go
        case "rust", "rs": return .rust
        case "java": return .java
        case "kotlin", "kt", "kts": return .kotlin
        case "ruby", "rb": return .ruby
        case "sql", "mysql", "postgresql", "postgres", "sqlite", "psql": return .sql
        case "php": return .php
        default: return nil
        }
    }

    public static func tokens(in code: String, language: Language) -> [Token] {
        let text = Array(code.utf16)
        switch language {
        case .json: var s = JSONScanner(text); return s.run()
        case .yaml: var s = YAMLScanner(text); return s.run()
        case .html, .xml: var s = MarkupScanner(text, html: language == .html); return s.run()
        case .css: var s = CSSScanner(text); return s.run()
        default: var s = CodeScanner(text, grammar: Grammar.for(language)); return s.run()
        }
    }

    public static func tokens(in code: String, info: String?) -> [Token] {
        guard let language = language(for: info) else { return [] }
        return tokens(in: code, language: language)
    }
}

// MARK: - UTF-16 helpers

private extension UInt16 {
    var isASCIIDigit: Bool { self >= 48 && self <= 57 }
    var isASCIILetter: Bool { (self >= 65 && self <= 90) || (self >= 97 && self <= 122) }
    var isIdentStart: Bool { isASCIILetter || self == 95 /* _ */ || self > 127 }
    var isIdentPart: Bool { isIdentStart || isASCIIDigit }
    var isSpace: Bool { self == 32 || self == 9 }
    var isNewline: Bool { self == 10 || self == 13 }
    var isUpper: Bool { self >= 65 && self <= 90 }
}

private func u(_ s: String) -> [UInt16] { Array(s.utf16) }

private struct Cursor {
    let text: [UInt16]
    var i = 0
    var tokens: [SyntaxHighlighter.Token] = []

    init(_ text: [UInt16]) { self.text = text }

    var atEnd: Bool { i >= text.count }
    func peek(_ offset: Int = 0) -> UInt16? {
        let j = i + offset
        return j >= 0 && j < text.count ? text[j] : nil
    }
    func matches(_ s: [UInt16], at j: Int? = nil) -> Bool {
        let start = j ?? i
        guard !s.isEmpty, start + s.count <= text.count else { return false }
        for k in 0..<s.count where text[start + k] != s[k] { return false }
        return true
    }
    func word(_ start: Int, _ end: Int) -> String {
        String(utf16CodeUnits: Array(text[start..<end]), count: end - start)
    }
    mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxHighlighter.Kind) {
        guard end > start else { return }
        tokens.append(.init(range: NSRange(location: start, length: end - start), kind: kind))
    }
    /// Index just past the end of the current line (before the newline).
    func lineEnd(from j: Int) -> Int {
        var k = j
        while k < text.count, !text[k].isNewline { k += 1 }
        return k
    }
    /// Scan a quoted string starting at `i` (the opening quote); handles backslash escapes.
    mutating func scanString(quote: [UInt16], escapes: Bool = true, multiline: Bool = false) -> Int {
        var k = i + quote.count
        while k < text.count {
            if escapes, text[k] == 92 /* \ */ { k += 2; continue }
            if matches(quote, at: k) { return k + quote.count }
            if !multiline, text[k].isNewline { return k }
            k += 1
        }
        return text.count
    }
    /// Number literal at `i` (decimal, hex, binary, floats, exponents, `_` separators, unit suffix).
    func numberEnd() -> Int {
        var k = i
        if text[k] == 48, k + 1 < text.count, [120, 88, 98, 66, 111, 79].contains(text[k + 1]) { // 0x 0b 0o
            k += 2
            while k < text.count, text[k].isIdentPart { k += 1 }
            return k
        }
        while k < text.count, text[k].isASCIIDigit || text[k] == 95 || text[k] == 46 { // digits _ .
            if text[k] == 46, !(k + 1 < text.count && text[k + 1].isASCIIDigit) { break }
            k += 1
        }
        if k < text.count, text[k] == 101 || text[k] == 69 { // e E
            var m = k + 1
            if m < text.count, text[m] == 43 || text[m] == 45 { m += 1 }
            if m < text.count, text[m].isASCIIDigit {
                k = m
                while k < text.count, text[k].isASCIIDigit { k += 1 }
            }
        }
        while k < text.count, text[k].isASCIILetter { k += 1 } // suffixes: f, L, u, px, ms…
        return k
    }
    /// A digit that starts a number (not part of an identifier).
    func startsNumber() -> Bool {
        guard let c = peek() else { return false }
        if c.isASCIIDigit { return !(peek(-1)?.isIdentPart ?? false) }
        if c == 46, let n = peek(1), n.isASCIIDigit { return !(peek(-1)?.isIdentPart ?? false) }
        return false
    }
}

// MARK: - Generic C-like / scripting languages

private struct Grammar {
    var lineComments: [[UInt16]] = []
    var blockComments: [([UInt16], [UInt16])] = []
    var quotes: [[UInt16]] = [u("\""), u("'")]
    var multilineQuotes: [[UInt16]] = []      // """ ''' `
    var keywords: Set<String> = []
    var types: Set<String> = []
    var constants: Set<String> = []
    var builtins: Set<String> = []            // shell commands, common functions
    var caseInsensitive = false
    var capitalizedAreTypes = false
    var attributePrefix: UInt16?              // @decorator / @Annotation / @attr
    var preprocessorHash = false              // #include at line start
    var variablePrefix: UInt16?               // $var
    var callsAreFunctions = true

    static func `for`(_ language: SyntaxHighlighter.Language) -> Grammar {
        var g = Grammar()
        switch language {
        case .bash:
            g.lineComments = [u("#")]
            g.keywords = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                          "function", "select", "return", "break", "continue", "local", "export", "readonly", "declare",
                          "unset", "shift", "trap", "exit", "source", "time"]
            g.builtins = ["echo", "printf", "cd", "ls", "cat", "grep", "sed", "awk", "curl", "wget", "git", "sudo", "rm",
                          "cp", "mv", "mkdir", "chmod", "chown", "find", "xargs", "test", "read", "eval", "exec", "set",
                          "brew", "npm", "swift", "make", "docker", "ssh", "tar", "open", "xattr", "kill", "pwd", "touch",
                          "head", "tail", "sort", "uniq", "wc", "tee", "env", "which", "python", "python3", "pip", "node"]
            g.constants = ["true", "false"]
            g.variablePrefix = 36 // $
            g.callsAreFunctions = false
        case .python:
            g.lineComments = [u("#")]
            g.multilineQuotes = [u("\"\"\""), u("'''")]
            g.keywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                          "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                          "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case"]
            g.constants = ["True", "False", "None", "self", "cls"]
            g.types = ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type"]
            g.builtins = ["print", "len", "range", "open", "enumerate", "zip", "map", "filter", "sorted", "isinstance"]
            g.attributePrefix = 64 // @
            g.capitalizedAreTypes = true
        case .javascript, .typescript:
            g.lineComments = [u("//")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.multilineQuotes = [u("`")]
            g.keywords = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
                          "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof",
                          "let", "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
                          "while", "with", "yield", "async", "await", "of", "static", "get", "set", "from", "as"]
            g.constants = ["true", "false", "null", "undefined", "NaN", "Infinity"]
            if language == .typescript {
                g.keywords.formUnion(["interface", "type", "enum", "implements", "namespace", "declare", "readonly",
                                      "private", "public", "protected", "abstract", "keyof", "infer", "is"])
                g.types = ["string", "number", "boolean", "any", "unknown", "never", "void", "object", "bigint", "symbol"]
            }
            g.attributePrefix = 64
            g.capitalizedAreTypes = true
        case .c, .cpp:
            g.lineComments = [u("//")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.keywords = ["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for",
                          "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch",
                          "typedef", "union", "volatile", "while"]
            g.types = ["int", "char", "float", "double", "long", "short", "signed", "unsigned", "void", "bool", "size_t",
                       "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t"]
            g.constants = ["NULL", "true", "false"]
            if language == .cpp {
                g.keywords.formUnion(["class", "namespace", "template", "typename", "public", "private", "protected",
                                      "virtual", "override", "final", "new", "delete", "this", "throw", "try", "catch",
                                      "using", "operator", "friend", "explicit", "constexpr", "consteval", "noexcept",
                                      "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast", "co_await",
                                      "co_return", "decltype", "mutable"])
                g.types.formUnion(["std", "string", "vector", "map", "unique_ptr", "shared_ptr", "wchar_t", "auto"])
                g.constants.formUnion(["nullptr"])
            }
            g.preprocessorHash = true
            g.capitalizedAreTypes = true
        case .swift:
            g.lineComments = [u("//")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.multilineQuotes = [u("\"\"\"")]
            g.quotes = [u("\"")]
            g.keywords = ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
                          "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
                          "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue",
                          "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
                          "return", "switch", "where", "while", "as", "catch", "is", "throw", "throws", "try", "async",
                          "await", "some", "any", "final", "lazy", "mutating", "override", "weak", "unowned",
                          "convenience", "required", "nonisolated", "isolated", "actor", "consuming", "borrowing"]
            g.constants = ["true", "false", "nil", "self", "Self", "super"]
            g.attributePrefix = 64
            g.preprocessorHash = true
            g.capitalizedAreTypes = true
        case .go:
            g.lineComments = [u("//")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.multilineQuotes = [u("`")]
            g.keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                          "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return",
                          "select", "struct", "switch", "type", "var"]
            g.types = ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16",
                       "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any"]
            g.constants = ["true", "false", "nil", "iota"]
            g.capitalizedAreTypes = false
        case .rust:
            g.lineComments = [u("//")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.quotes = [u("\"")]
            g.keywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                          "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
                          "return", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while"]
            g.types = ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32",
                       "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"]
            g.constants = ["true", "false", "self", "Self", "None", "Some", "Ok", "Err"]
            g.preprocessorHash = true
            g.capitalizedAreTypes = true
        case .java, .kotlin:
            g.lineComments = [u("//")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.multilineQuotes = [u("\"\"\"")]
            g.keywords = ["abstract", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum",
                          "extends", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface",
                          "new", "package", "private", "protected", "public", "return", "static", "super", "switch",
                          "synchronized", "this", "throw", "throws", "try", "while", "var", "record", "sealed"]
            g.types = ["int", "long", "short", "byte", "char", "float", "double", "boolean", "void", "String"]
            g.constants = ["true", "false", "null"]
            if language == .kotlin {
                g.keywords.formUnion(["fun", "val", "object", "companion", "data", "when", "is", "in", "out", "by",
                                      "init", "internal", "open", "override", "lateinit", "suspend", "typealias", "as"])
                g.types.formUnion(["Int", "Long", "Double", "Float", "Boolean", "Unit", "Any", "List", "Map"])
            }
            g.attributePrefix = 64
            g.capitalizedAreTypes = true
        case .ruby:
            g.lineComments = [u("#")]
            g.keywords = ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
                          "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry",
                          "return", "super", "then", "undef", "unless", "until", "when", "while", "yield", "require",
                          "attr_accessor", "attr_reader", "include"]
            g.constants = ["true", "false", "nil", "self"]
            g.attributePrefix = 64
            g.capitalizedAreTypes = true
        case .sql:
            g.lineComments = [u("--")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.caseInsensitive = true
            g.keywords = ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                          "delete", "create", "table", "drop", "alter", "add", "index", "primary", "key", "foreign",
                          "references", "join", "left", "right", "inner", "outer", "on", "group", "by", "order",
                          "having", "limit", "offset", "as", "distinct", "union", "all", "case", "when", "then", "else",
                          "end", "is", "in", "like", "between", "exists", "view", "default", "unique", "constraint",
                          "with", "returning", "asc", "desc", "begin", "commit", "rollback"]
            g.types = ["int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean", "date", "timestamp",
                       "numeric", "decimal", "real", "float", "serial", "uuid", "json", "jsonb", "blob"]
            g.constants = ["null", "true", "false"]
            g.builtins = ["count", "sum", "avg", "min", "max", "coalesce", "now", "lower", "upper"]
        case .php:
            g.lineComments = [u("//"), u("#")]
            g.blockComments = [(u("/*"), u("*/"))]
            g.keywords = ["abstract", "and", "as", "break", "case", "catch", "class", "const", "continue", "default", "do",
                          "echo", "else", "elseif", "extends", "final", "for", "foreach", "function", "if", "implements",
                          "interface", "namespace", "new", "or", "private", "protected", "public", "return", "static",
                          "switch", "throw", "trait", "try", "use", "while", "fn", "match", "readonly"]
            g.constants = ["true", "false", "null", "TRUE", "FALSE", "NULL"]
            g.variablePrefix = 36
            g.capitalizedAreTypes = true
        default:
            break
        }
        return g
    }
}

private struct CodeScanner {
    var c: Cursor
    let g: Grammar

    init(_ text: [UInt16], grammar: Grammar) {
        c = Cursor(text)
        g = grammar
    }

    mutating func run() -> [SyntaxHighlighter.Token] {
        var lineStart = true
        while !c.atEnd {
            let ch = c.text[c.i]
            if ch.isNewline { c.i += 1; lineStart = true; continue }
            if ch.isSpace { c.i += 1; continue }
            defer { lineStart = false }

            // Comments
            if let open = g.lineComments.first(where: { c.matches($0) }), lineCommentAllowed(open) {
                let end = c.lineEnd(from: c.i)
                c.emit(c.i, end, .comment); c.i = end; continue
            }
            if let (open, close) = g.blockComments.first(where: { c.matches($0.0) }) {
                var k = c.i + open.count
                while k < c.text.count, !c.matches(close, at: k) { k += 1 }
                let end = min(c.text.count, k + close.count)
                c.emit(c.i, end, .comment); c.i = end; continue
            }
            // Preprocessor / attributes
            if g.preprocessorHash, ch == 35 /* # */, lineStart {
                var k = c.i + 1
                if k < c.text.count, c.text[k] == 33 || c.text[k] == 91 { k += 1 } // #! #[
                while k < c.text.count, c.text[k].isIdentPart { k += 1 }
                if k > c.i + 1 { c.emit(c.i, k, .meta); c.i = k; continue }
            }
            if let prefix = g.attributePrefix, ch == prefix, let n = c.peek(1), n.isIdentStart {
                var k = c.i + 1
                while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 46 { k += 1 }
                c.emit(c.i, k, .meta); c.i = k; continue
            }
            // Strings
            if let q = g.multilineQuotes.first(where: { c.matches($0) }) {
                let end = c.scanString(quote: q, escapes: true, multiline: true)
                c.emit(c.i, end, .string); c.i = end; continue
            }
            if let q = g.quotes.first(where: { c.matches($0) }) {
                // Rust/Swift lifetimes and char literals share `'`; only quote when it closes on the line.
                let end = c.scanString(quote: q, escapes: !(g.variablePrefix == 36 && q == u("'")))
                c.emit(c.i, end, .string)
                if g.variablePrefix != nil, q == u("\"") { emitVariables(in: c.i, end) }
                c.i = end; continue
            }
            // Variables ($HOME, ${x}, $1, $var)
            if let prefix = g.variablePrefix, ch == prefix {
                let end = variableEnd(at: c.i)
                if end > c.i + 1 { c.emit(c.i, end, .variable); c.i = end; continue }
            }
            // Numbers
            if c.startsNumber() {
                let end = c.numberEnd()
                c.emit(c.i, end, .number); c.i = end; continue
            }
            // Identifiers
            if ch.isIdentStart {
                var k = c.i
                while k < c.text.count, c.text[k].isIdentPart || (g.variablePrefix == 36 && c.text[k] == 45 && k > c.i) { k += 1 }
                if k < c.text.count, c.text[k] == 63 /* ? */, g.lineComments.first == u("#"), g.variablePrefix == nil { // ruby defined?
                    if g.keywords.contains(c.word(c.i, k + 1)) { k += 1 }
                }
                classify(c.i, k)
                c.i = k; continue
            }
            c.i += 1
        }
        return c.tokens
    }

    /// `#` starts a comment only at a word boundary (bash `$#`, `a#b`; Swift/C use `//`).
    func lineCommentAllowed(_ open: [UInt16]) -> Bool {
        guard open == u("#") else { return true }
        guard let prev = c.peek(-1) else { return true }
        return prev.isSpace || prev.isNewline || prev == 59 /* ; */
    }

    func variableEnd(at start: Int) -> Int {
        var k = start + 1
        guard k < c.text.count else { return k }
        if c.text[k] == 123 { // ${...}
            while k < c.text.count, c.text[k] != 125, !c.text[k].isNewline { k += 1 }
            return min(c.text.count, k + 1)
        }
        if c.text[k].isASCIIDigit || [63, 35, 64, 42, 33, 36].contains(c.text[k]) { return k + 1 } // $1 $? $# $@ $* $! $$
        while k < c.text.count, c.text[k].isIdentPart { k += 1 }
        return k
    }

    mutating func emitVariables(in start: Int, _ end: Int) {
        guard let prefix = g.variablePrefix else { return }
        var k = start
        var inner: [SyntaxHighlighter.Token] = []
        while k < end {
            if c.text[k] == prefix {
                let e = min(end, variableEnd(at: k))
                if e > k + 1 { inner.append(.init(range: NSRange(location: k, length: e - k), kind: .variable)); k = e; continue }
            }
            k += 1
        }
        guard !inner.isEmpty, let string = c.tokens.popLast() else { return }
        // Split the string token around the variables so tokens never overlap.
        var cursor = string.range.location
        for v in inner {
            c.emit(cursor, v.range.location, .string)
            c.tokens.append(v)
            cursor = NSMaxRange(v.range)
        }
        c.emit(cursor, NSMaxRange(string.range), .string)
    }

    mutating func classify(_ start: Int, _ end: Int) {
        let raw = c.word(start, end)
        let w = g.caseInsensitive ? raw.lowercased() : raw
        if g.keywords.contains(w) { c.emit(start, end, .keyword); return }
        if g.constants.contains(w) { c.emit(start, end, .constant); return }
        if g.types.contains(w) { c.emit(start, end, .type); return }
        var k = end
        while k < c.text.count, c.text[k].isSpace { k += 1 }
        let isCall = k < c.text.count && c.text[k] == 40 /* ( */
        if g.builtins.contains(w) {
            // Shell: a builtin command word; elsewhere only when called.
            if !g.callsAreFunctions || isCall { c.emit(start, end, .function); return }
        }
        if g.capitalizedAreTypes, c.text[start].isUpper { c.emit(start, end, .type); return }
        if g.callsAreFunctions, isCall { c.emit(start, end, .function); return }
    }
}

// MARK: - JSON

private struct JSONScanner {
    var c: Cursor
    init(_ text: [UInt16]) { c = Cursor(text) }

    mutating func run() -> [SyntaxHighlighter.Token] {
        while !c.atEnd {
            let ch = c.text[c.i]
            if ch == 34 /* " */ {
                let end = c.scanString(quote: u("\""))
                var k = end
                while k < c.text.count, c.text[k].isSpace || c.text[k].isNewline { k += 1 }
                let isKey = k < c.text.count && c.text[k] == 58 /* : */
                c.emit(c.i, end, isKey ? .property : .string)
                c.i = end; continue
            }
            if c.matches(u("//")) { let e = c.lineEnd(from: c.i); c.emit(c.i, e, .comment); c.i = e; continue } // JSONC
            if ch == 45 /* - */, let n = c.peek(1), n.isASCIIDigit { c.i += 1; let s = c.i - 1; let e = c.numberEnd(); c.emit(s, e, .number); c.i = e; continue }
            if c.startsNumber() { let e = c.numberEnd(); c.emit(c.i, e, .number); c.i = e; continue }
            if ch.isASCIILetter {
                var k = c.i
                while k < c.text.count, c.text[k].isASCIILetter { k += 1 }
                if ["true", "false", "null"].contains(c.word(c.i, k)) { c.emit(c.i, k, .constant) }
                c.i = k; continue
            }
            c.i += 1
        }
        return c.tokens
    }
}

// MARK: - YAML

private struct YAMLScanner {
    var c: Cursor
    init(_ text: [UInt16]) { c = Cursor(text) }

    mutating func run() -> [SyntaxHighlighter.Token] {
        while !c.atEnd {
            let lineEnd = c.lineEnd(from: c.i)
            scanLine(from: c.i, to: lineEnd)
            c.i = lineEnd + 1
        }
        return c.tokens
    }

    mutating func scanLine(from start: Int, to end: Int) {
        var k = start
        while k < end, c.text[k].isSpace { k += 1 }
        if c.matches(u("---"), at: k) || c.matches(u("..."), at: k) { c.emit(k, min(end, k + 3), .meta); return }
        if k < end, c.text[k] == 35 { c.emit(k, end, .comment); return }
        if k < end, c.text[k] == 45, k + 1 < end, c.text[k + 1].isSpace { k += 2 } // list item "- "
        while k < end, c.text[k].isSpace { k += 1 }
        // key: value
        var colon = -1
        var q = k
        if q < end, c.text[q] == 34 || c.text[q] == 39 {
            var save = c; save.i = q
            q = save.scanString(quote: [c.text[q]])
        }
        while q < end {
            if c.text[q] == 58, q + 1 >= end || c.text[q + 1].isSpace { colon = q; break }
            if c.text[q] == 35, q > k, c.text[q - 1].isSpace { break }
            q += 1
        }
        var valueStart = k
        if colon > k {
            c.emit(k, colon, .property)
            valueStart = colon + 1
        }
        scanValue(from: valueStart, to: end)
    }

    mutating func scanValue(from start: Int, to end: Int) {
        var k = start
        while k < end, c.text[k].isSpace { k += 1 }
        guard k < end else { return }
        // Trailing comment
        var commentStart = end
        var m = k
        var inQuote: UInt16?
        while m < end {
            let ch = c.text[m]
            if let qch = inQuote { if ch == qch { inQuote = nil } } else if ch == 34 || ch == 39 { inQuote = ch } else if ch == 35, m == k || c.text[m - 1].isSpace { commentStart = m; break }
            m += 1
        }
        var valueEnd = commentStart
        while valueEnd > k, c.text[valueEnd - 1].isSpace { valueEnd -= 1 }
        if valueEnd > k {
            let ch = c.text[k]
            let value = c.word(k, valueEnd)
            if ch == 34 || ch == 39 { c.emit(k, valueEnd, .string) }
            else if ch == 38 || ch == 42 { c.emit(k, valueEnd, .variable) } // &anchor *alias
            else if ch == 33 { c.emit(k, valueEnd, .meta) } // !tag
            else if ch == 124 || ch == 62 { c.emit(k, valueEnd, .meta) } // | >
            else if ["true", "false", "yes", "no", "on", "off", "null", "~", "True", "False", "Null", "NULL"].contains(value) { c.emit(k, valueEnd, .constant) }
            else if Double(value.replacingOccurrences(of: "_", with: "")) != nil || value.hasPrefix("0x") { c.emit(k, valueEnd, .number) }
        }
        if commentStart < end { c.emit(commentStart, end, .comment) }
    }
}

// MARK: - HTML / XML

private struct MarkupScanner {
    var c: Cursor
    let html: Bool
    init(_ text: [UInt16], html: Bool) {
        c = Cursor(text)
        self.html = html
    }

    mutating func run() -> [SyntaxHighlighter.Token] {
        while !c.atEnd {
            if c.matches(u("<!--")) {
                var k = c.i + 4
                while k < c.text.count, !c.matches(u("-->"), at: k) { k += 1 }
                let end = min(c.text.count, k + 3)
                c.emit(c.i, end, .comment); c.i = end; continue
            }
            if c.matches(u("<![CDATA[")) {
                var k = c.i + 9
                while k < c.text.count, !c.matches(u("]]>"), at: k) { k += 1 }
                let end = min(c.text.count, k + 3)
                c.emit(c.i, end, .string); c.i = end; continue
            }
            if c.matches(u("<?")) || c.matches(u("<!")) {
                var k = c.i + 2
                while k < c.text.count, c.text[k] != 62 { k += 1 }
                let end = min(c.text.count, k + 1)
                c.emit(c.i, end, .meta); c.i = end; continue
            }
            if c.text[c.i] == 60 /* < */, let n = c.peek(1), n.isIdentStart || n == 47 /* / */ {
                scanTag(); continue
            }
            if c.text[c.i] == 38 /* & */ {
                var k = c.i + 1
                while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 35 { k += 1 }
                if k < c.text.count, c.text[k] == 59 { c.emit(c.i, k + 1, .constant); c.i = k + 1; continue }
            }
            c.i += 1
        }
        return c.tokens
    }

    mutating func scanTag() {
        var k = c.i + 1
        if k < c.text.count, c.text[k] == 47 { k += 1 }
        let nameStart = k
        while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 || c.text[k] == 58 || c.text[k] == 46 { k += 1 }
        c.emit(nameStart, k, .tag)
        while k < c.text.count, c.text[k] != 62 /* > */ {
            let ch = c.text[k]
            if ch == 34 || ch == 39 {
                var save = c; save.i = k
                let end = save.scanString(quote: [ch], escapes: false, multiline: true)
                c.emit(k, end, .string); k = end; continue
            }
            if ch.isIdentStart {
                let s = k
                while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 || c.text[k] == 58 || c.text[k] == 46 { k += 1 }
                c.emit(s, k, .attribute); continue
            }
            k += 1
        }
        c.i = min(c.text.count, k + 1)
    }
}

// MARK: - CSS

private struct CSSScanner {
    var c: Cursor
    init(_ text: [UInt16]) { c = Cursor(text) }

    mutating func run() -> [SyntaxHighlighter.Token] {
        var depth = 0
        var inValue = false
        while !c.atEnd {
            let ch = c.text[c.i]
            if c.matches(u("/*")) {
                var k = c.i + 2
                while k < c.text.count, !c.matches(u("*/"), at: k) { k += 1 }
                let end = min(c.text.count, k + 2)
                c.emit(c.i, end, .comment); c.i = end; continue
            }
            if c.matches(u("//")) { let e = c.lineEnd(from: c.i); c.emit(c.i, e, .comment); c.i = e; continue } // scss/less
            if ch == 34 || ch == 39 { let e = c.scanString(quote: [ch]); c.emit(c.i, e, .string); c.i = e; continue }
            if ch == 123 { depth += 1; inValue = false; c.i += 1; continue }
            if ch == 125 { depth = max(0, depth - 1); inValue = false; c.i += 1; continue }
            if ch == 59 { inValue = false; c.i += 1; continue }
            if ch == 64 /* @ */ {
                var k = c.i + 1
                while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 { k += 1 }
                c.emit(c.i, k, .keyword); c.i = k; continue
            }
            if ch == 33, c.matches(u("!important")) { c.emit(c.i, c.i + 10, .keyword); c.i += 10; continue }
            if inValue {
                if ch == 35 /* #fff */ {
                    var k = c.i + 1
                    while k < c.text.count, c.text[k].isIdentPart { k += 1 }
                    c.emit(c.i, k, .constant); c.i = k; continue
                }
                if c.startsNumber() || (ch == 45 && (c.peek(1)?.isASCIIDigit ?? false)) {
                    let s = c.i
                    if ch == 45 { c.i += 1 }
                    var e = c.numberEnd()
                    if e < c.text.count, c.text[e] == 37 { e += 1 } // %
                    c.emit(s, e, .number); c.i = e; continue
                }
                if ch.isIdentStart || ch == 45 {
                    var k = c.i
                    while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 { k += 1 }
                    if k < c.text.count, c.text[k] == 40 { c.emit(c.i, k, .function) } // rgb( var( calc(
                    c.i = k; continue
                }
                c.i += 1; continue
            }
            if depth > 0, ch.isIdentStart || ch == 45 {
                // property name (or nested selector in scss)
                var k = c.i
                while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 { k += 1 }
                var m = k
                while m < c.text.count, c.text[m].isSpace { m += 1 }
                if m < c.text.count, c.text[m] == 58 { c.emit(c.i, k, .property); inValue = true; c.i = m + 1; continue }
                c.emit(c.i, k, .tag); c.i = k; continue
            }
            if depth == 0 {
                // selectors: .class #id tag :pseudo
                if ch == 46 || ch == 35 {
                    var k = c.i + 1
                    while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 { k += 1 }
                    c.emit(c.i, k, .attribute); c.i = k; continue
                }
                if ch == 58 {
                    var k = c.i + 1
                    if k < c.text.count, c.text[k] == 58 { k += 1 }
                    while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 { k += 1 }
                    c.emit(c.i, k, .keyword); c.i = k; continue
                }
                if ch.isIdentStart {
                    var k = c.i
                    while k < c.text.count, c.text[k].isIdentPart || c.text[k] == 45 { k += 1 }
                    c.emit(c.i, k, .tag); c.i = k; continue
                }
            }
            c.i += 1
        }
        return c.tokens
    }
}
