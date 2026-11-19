import Foundation

/// Atom classes, as in TeX: they decide the spacing between neighbours.
public enum MathAtom: String, Equatable, Sendable {
    case ordinary, variable, number, binary, relation, open, close, punctuation, operatorName
}

public enum MathFont: String, Equatable, Sendable {
    case roman, bold, italic, blackboard, calligraphic, fraktur, sansSerif, monospace
}

/// LaTeX math as a tree. Layout and drawing live in the app (`MathRenderer`).
public indirect enum MathNode: Equatable, Sendable {
    case row([MathNode])
    case atom(String, MathAtom)
    /// Upright text (`\text{…}`), spaces kept.
    case text(String)
    case fraction(MathNode, MathNode, bar: Bool)
    case root(MathNode, index: MathNode?)
    case scripts(MathNode, sup: MathNode?, sub: MathNode?)
    /// ∑ ∏ ∫ …; `limits` puts scripts under / over the operator in display style.
    case largeOp(String, limits: Bool)
    case delimited(String, MathNode, String)
    case matrix([[MathNode]], left: String, right: String, alignment: MatrixAlignment)
    case accent(MathNode, String, wide: Bool)
    case underline(MathNode)
    case styled(MathNode, MathFont)
    /// Horizontal space in em.
    case space(Double)
    /// Something the parser did not understand (shown in red).
    case error(String)
}

public extension MathNode {
    /// The items of a row (a single node is a row of one).
    var rowItems: [MathNode] {
        if case .row(let items) = self { return items }
        return [self]
    }
}

public enum MatrixAlignment: String, Equatable, Sendable {
    /// Every column centred (matrix, pmatrix, …).
    case centered
    /// cases: values left-aligned, conditions left-aligned.
    case cases
    /// aligned / align: columns alternate right / left (around `&=`).
    case aligned
}

public enum MathParser {
    public static func parse(_ latex: String) -> MathNode {
        var parser = Parser(tokens: tokenize(latex))
        return parser.parseRow(until: [])
    }

    // MARK: Tokens

    enum Token: Equatable {
        case command(String)      // \frac, \alpha, \, …
        case char(Character)
        case open, close          // { }
        case sup, sub             // ^ _
        case ampersand
        case newline              // \\
        case number(String)
    }

    static let textCommands: Set<String> = ["text", "textrm", "textnormal", "mbox", "textit", "textbf"]

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 1
                guard i < chars.count else { break }
                if chars[i] == "\\" { tokens.append(.newline); i += 1; continue }
                if chars[i].isLetter {
                    var name = ""
                    while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                    tokens.append(.command(name))
                    // Text arguments keep their spaces (`\text{if }`); math mode drops them elsewhere.
                    if textCommands.contains(name) {
                        var j = i
                        while j < chars.count, chars[j] == " " { j += 1 }
                        if j < chars.count, chars[j] == "{" {
                            var depth = 0
                            var k = j
                            var inner: [Character] = []
                            while k < chars.count {
                                if chars[k] == "{" { depth += 1; if depth == 1 { k += 1; continue } }
                                if chars[k] == "}" { depth -= 1; if depth == 0 { break } }
                                inner.append(chars[k]); k += 1
                            }
                            tokens.append(.open)
                            inner.forEach { tokens.append(.char($0)) }
                            tokens.append(.close)
                            i = min(k + 1, chars.count)
                        }
                    }
                } else {
                    tokens.append(.command(String(chars[i])))
                    i += 1
                }
                continue
            }
            switch c {
            case "{": tokens.append(.open)
            case "}": tokens.append(.close)
            case "^": tokens.append(.sup)
            case "_": tokens.append(.sub)
            case "&": tokens.append(.ampersand)
            case " ", "\n", "\t", "\r": break   // math mode ignores whitespace
            default:
                if c.isNumber {
                    var number = String(c)
                    i += 1
                    while i < chars.count, chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                        number.append(chars[i]); i += 1
                    }
                    tokens.append(.number(number))
                    continue
                }
                tokens.append(.char(c))
            }
            i += 1
        }
        return tokens
    }

    // MARK: Parser

    struct Parser {
        var tokens: [Token]
        var i = 0

        var atEnd: Bool { i >= tokens.count }
        func peek() -> Token? { i < tokens.count ? tokens[i] : nil }
        mutating func next() -> Token? {
            guard i < tokens.count else { return nil }
            defer { i += 1 }
            return tokens[i]
        }

        /// A row until one of `stop` (not consumed), a closing brace, or the end.
        mutating func parseRow(until stop: Set<String>) -> MathNode {
            var items: [MathNode] = []
            while let token = peek() {
                if token == .close { break }
                if case .command(let name) = token, stop.contains(name) { break }
                if stop.contains("&"), token == .ampersand { break }
                if stop.contains("\\\\"), token == .newline { break }
                guard let atom = parseAtom() else { continue }
                items.append(parseScripts(atom))
            }
            return items.count == 1 ? items[0] : .row(items)
        }

        /// `{…}` or a single atom.
        mutating func parseArgument() -> MathNode {
            if peek() == .open {
                _ = next()
                let row = parseRow(until: [])
                if peek() == .close { _ = next() }
                return row
            }
            return parseAtom() ?? .row([])
        }

        /// Raw text of a `{…}` argument (for \text, \begin{…}, \operatorname).
        mutating func parseRawArgument() -> String {
            guard peek() == .open else {
                if case .char(let c)? = peek() { _ = next(); return String(c) }
                return ""
            }
            _ = next()
            var depth = 1
            var out = ""
            while let token = next() {
                switch token {
                case .open: depth += 1; out += "{"
                case .close:
                    depth -= 1
                    if depth == 0 { return out }
                    out += "}"
                case .char(let c): out.append(c)
                case .number(let n): out += n
                case .command(let name): out += name.count == 1 && !name.first!.isLetter ? name : "\\" + name
                case .sup: out += "^"
                case .sub: out += "_"
                case .ampersand: out += "&"
                case .newline: out += " "
                }
            }
            return out
        }

        mutating func parseScripts(_ base: MathNode) -> MathNode {
            var sup: MathNode?
            var sub: MathNode?
            var base = base
            var limits: Bool?
            loop: while let token = peek() {
                switch token {
                case .sup:
                    _ = next()
                    sup = parseArgument()
                case .sub:
                    _ = next()
                    sub = parseArgument()
                case .char("'"):
                    _ = next()
                    sup = sup.map { .row([.atom("′", .ordinary), $0]) } ?? .atom("′", .ordinary)
                case .command("limits"):
                    _ = next(); limits = true
                case .command("nolimits"):
                    _ = next(); limits = false
                default:
                    break loop
                }
            }
            if let limits, case .largeOp(let symbol, _) = base { base = .largeOp(symbol, limits: limits) }
            guard sup != nil || sub != nil else { return base }
            return .scripts(base, sup: sup, sub: sub)
        }

        mutating func parseAtom() -> MathNode? {
            guard let token = next() else { return nil }
            switch token {
            case .open:
                let row = parseRow(until: [])
                if peek() == .close { _ = next() }
                return row
            case .close:
                return nil
            case .sup, .sub:
                // A script with no base: attach to an empty base.
                i -= 1
                return .row([])
            case .ampersand, .newline:
                return nil
            case .number(let n):
                return .atom(n, .number)
            case .char(let c):
                return Self.charAtom(c)
            case .command(let name):
                return parseCommand(name)
            }
        }

        static func charAtom(_ c: Character) -> MathNode {
            switch c {
            case "+", "*": return .atom(c == "*" ? "∗" : "+", .binary)
            case "-": return .atom("−", .binary)
            case "=", "<", ">", ":": return .atom(String(c), .relation)
            case "(", "[": return .atom(String(c), .open)
            case ")", "]", "!": return .atom(String(c), c == "!" ? .ordinary : .close)
            case ",", ";": return .atom(String(c), .punctuation)
            case "|": return .atom("|", .ordinary)
            case "/": return .atom("/", .ordinary)
            case "~": return .space(0.33)
            default:
                return c.isLetter ? .atom(String(c), .variable) : .atom(String(c), .ordinary)
            }
        }

        mutating func parseCommand(_ name: String) -> MathNode {
            if let symbol = MathSymbols.table[name] { return .atom(symbol.0, symbol.1) }
            if let op = MathSymbols.largeOperators[name] { return .largeOp(op.0, limits: op.1) }
            if MathSymbols.functions.contains(name) {
                return .atom(name, .operatorName)
            }
            if MathSymbols.limitFunctions.contains(name) {
                return .largeOp(name, limits: true)
            }
            if let space = MathSymbols.spaces[name] { return .space(space) }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                return .fraction(parseArgument(), parseArgument(), bar: true)
            case "binom", "dbinom", "tbinom":
                return .delimited("(", .fraction(parseArgument(), parseArgument(), bar: false), ")")
            case "sqrt":
                var index: MathNode?
                if case .char("[")? = peek() {
                    _ = next()
                    var items: [MathNode] = []
                    while let t = peek(), t != .char("]") {
                        if let atom = parseAtom() { items.append(atom) }
                    }
                    _ = next()
                    index = items.count == 1 ? items[0] : .row(items)
                }
                return .root(parseArgument(), index: index)
            case "left":
                let left = parseDelimiter()
                let body = parseRow(until: ["right"])
                var right = ""
                if case .command("right")? = peek() {
                    _ = next()
                    right = parseDelimiter()
                }
                return .delimited(left, body, right)
            case "right":
                _ = parseDelimiter()
                return .row([])
            case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr":
                let delimiter = parseDelimiter()
                return .atom(delimiter, name.hasSuffix("r") ? .close : .open)
            case "text", "textrm", "textnormal", "mbox", "textit", "textbf":
                return .text(parseRawArgument())
            case "operatorname":
                return .atom(parseRawArgument(), .operatorName)
            case "mathrm": return .styled(parseArgument(), .roman)
            case "mathbf", "bm", "boldsymbol": return .styled(parseArgument(), .bold)
            case "mathit": return .styled(parseArgument(), .italic)
            case "mathbb": return .styled(parseArgument(), .blackboard)
            case "mathcal", "mathscr": return .styled(parseArgument(), .calligraphic)
            case "mathfrak": return .styled(parseArgument(), .fraktur)
            case "mathsf": return .styled(parseArgument(), .sansSerif)
            case "mathtt": return .styled(parseArgument(), .monospace)
            case "hat": return .accent(parseArgument(), "ˆ", wide: false)
            case "widehat": return .accent(parseArgument(), "ˆ", wide: true)
            case "check": return .accent(parseArgument(), "ˇ", wide: false)
            case "tilde": return .accent(parseArgument(), "˜", wide: false)
            case "widetilde": return .accent(parseArgument(), "˜", wide: true)
            case "bar", "overline": return .accent(parseArgument(), "‾", wide: true)
            case "vec": return .accent(parseArgument(), "→", wide: false)
            case "overrightarrow": return .accent(parseArgument(), "→", wide: true)
            case "dot": return .accent(parseArgument(), "˙", wide: false)
            case "ddot": return .accent(parseArgument(), "¨", wide: false)
            case "acute": return .accent(parseArgument(), "´", wide: false)
            case "grave": return .accent(parseArgument(), "`", wide: false)
            case "breve": return .accent(parseArgument(), "˘", wide: false)
            case "underline": return .underline(parseArgument())
            case "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits":
                return .row([])
            case "begin":
                return parseEnvironment(parseRawArgument())
            case "end":
                _ = parseRawArgument()
                return .row([])
            default:
                return .error("\\" + name)
            }
        }

        mutating func parseDelimiter() -> String {
            guard let token = next() else { return "" }
            switch token {
            case .char(let c): return c == "." ? "" : String(c)
            case .command(let name):
                if name == "{" { return "{" }
                if name == "}" { return "}" }
                if name == "|" { return "‖" }
                return MathSymbols.table[name]?.0 ?? ""
            default: return ""
            }
        }

        mutating func parseEnvironment(_ name: String) -> MathNode {
            let base = name.replacingOccurrences(of: "*", with: "")
            // array{cc}: skip the column spec.
            if base == "array", peek() == .open { _ = parseRawArgument() }
            var rows: [[MathNode]] = [[]]
            while !atEnd {
                if case .command("end")? = peek() {
                    _ = next()
                    _ = parseRawArgument()
                    break
                }
                let cell = parseRow(until: ["end", "&", "\\\\"])
                rows[rows.count - 1].append(cell)
                if peek() == .ampersand {
                    _ = next()
                } else if peek() == .newline {
                    _ = next()
                    rows.append([])
                } else if peek() == .close {
                    _ = next()   // a stray brace inside the environment
                }
            }
            rows = rows.filter { row in !row.isEmpty && !(row.count == 1 && row[0] == .row([])) }
            switch base {
            case "pmatrix": return .matrix(rows, left: "(", right: ")", alignment: .centered)
            case "bmatrix": return .matrix(rows, left: "[", right: "]", alignment: .centered)
            case "Bmatrix": return .matrix(rows, left: "{", right: "}", alignment: .centered)
            case "vmatrix": return .matrix(rows, left: "|", right: "|", alignment: .centered)
            case "Vmatrix": return .matrix(rows, left: "‖", right: "‖", alignment: .centered)
            case "cases": return .matrix(rows, left: "{", right: "", alignment: .cases)
            case "aligned", "align", "split", "eqnarray", "alignat": return .matrix(rows, left: "", right: "", alignment: .aligned)
            case "gathered", "gather", "matrix", "smallmatrix", "array", "equation":
                return .matrix(rows, left: "", right: "", alignment: .centered)
            default:
                return .error("\\begin{\(name)}")
            }
        }
    }
}

/// LaTeX command → Unicode symbol tables.
public enum MathSymbols {
    public static let table: [String: (String, MathAtom)] = {
        var t: [String: (String, MathAtom)] = [:]
        let greek: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
            "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
            "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
            "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
            "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"
        ]
        for (k, v) in greek { t[k] = (v, k.first!.isUppercase ? .ordinary : .variable) }
        let relations: [String: String] = [
            "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡",
            "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "in": "∈", "notin": "∉", "ni": "∋",
            "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "to": "→", "rightarrow": "→",
            "leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
            "Leftrightarrow": "⇔", "iff": "⟺", "implies": "⟹", "impliedby": "⟸", "mapsto": "↦",
            "longrightarrow": "⟶", "longleftarrow": "⟵", "Longrightarrow": "⟹", "uparrow": "↑", "downarrow": "↓",
            "perp": "⊥", "parallel": "∥", "mid": "∣", "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",
            "preceq": "⪯", "succeq": "⪰", "doteq": "≐", "models": "⊨", "vdash": "⊢", "asymp": "≍", "coloneqq": "≔"
        ]
        for (k, v) in relations { t[k] = (v, .relation) }
        let binaries: [String: String] = [
            "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "⋅", "ast": "∗", "star": "⋆", "circ": "∘",
            "bullet": "∙", "cup": "∪", "cap": "∩", "setminus": "∖", "oplus": "⊕", "ominus": "⊖", "otimes": "⊗",
            "odot": "⊙", "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨", "dagger": "†", "amalg": "⨿"
        ]
        for (k, v) in binaries { t[k] = (v, .binary) }
        let ordinaries: [String: String] = [
            "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "nexists": "∄",
            "emptyset": "∅", "varnothing": "∅", "neg": "¬", "lnot": "¬", "angle": "∠", "triangle": "△",
            "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘", "prime": "′",
            "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "degree": "°", "top": "⊤",
            "bot": "⊥", "square": "□", "checkmark": "✓", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_",
            "{": "{", "}": "}", "|": "‖", "backslash": "∖", "S": "§", "P": "¶", "clubsuit": "♣", "diamondsuit": "♢",
            "heartsuit": "♡", "spadesuit": "♠", "imath": "ı", "jmath": "ȷ"
        ]
        for (k, v) in ordinaries { t[k] = (v, .ordinary) }
        for (k, v) in ["langle": "⟨", "lfloor": "⌊", "lceil": "⌈", "lvert": "|", "lVert": "‖"] { t[k] = (v, .open) }
        for (k, v) in ["rangle": "⟩", "rfloor": "⌋", "rceil": "⌉", "rvert": "|", "rVert": "‖"] { t[k] = (v, .close) }
        return t
    }()

    /// Large operators; `true` = limits under / over in display style.
    public static let largeOperators: [String: (String, Bool)] = [
        "sum": ("∑", true), "prod": ("∏", true), "coprod": ("∐", true), "int": ("∫", false), "iint": ("∬", false),
        "iiint": ("∭", false), "oint": ("∮", false), "bigcup": ("⋃", true), "bigcap": ("⋂", true),
        "bigoplus": ("⨁", true), "bigotimes": ("⨂", true), "bigvee": ("⋁", true), "bigwedge": ("⋀", true),
        "bigsqcup": ("⨆", true)
    ]

    /// Upright operator names with side scripts.
    public static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "det", "gcd", "arg", "deg", "dim", "ker", "hom", "Pr", "mod", "bmod"
    ]

    /// Upright operator names whose scripts go under / over in display style.
    public static let limitFunctions: Set<String> = ["lim", "max", "min", "sup", "inf", "liminf", "limsup", "argmax", "argmin"]

    /// Spacing commands, in em.
    public static let spaces: [String: Double] = [
        ",": 3.0 / 18, ":": 4.0 / 18, ">": 4.0 / 18, ";": 5.0 / 18, "!": -3.0 / 18, " ": 0.33,
        "quad": 1, "qquad": 2, "enspace": 0.5, "thinspace": 3.0 / 18
    ]
}
