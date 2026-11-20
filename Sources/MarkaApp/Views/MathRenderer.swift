import AppKit
import CoreText
import MarkaCore

/// Native math typesetting for a LaTeX subset (`MathParser`), TeX-style box layout on the
/// system's STIX Two Math font. No WebKit / JavaScript.
enum MathRenderer {
    struct Rendered {
        let image: NSImage
        /// Distance from the image's bottom edge to the math baseline (for inline placement).
        let baseline: CGFloat
        let hasErrors: Bool
    }

    private nonisolated(unsafe) static let cache = NSCache<NSString, CacheBox>()   // NSCache is thread-safe
    private final class CacheBox { let value: Rendered; init(_ v: Rendered) { value = v } }

    static func render(_ latex: String, fontSize: CGFloat, color: NSColor, display: Bool) -> Rendered {
        let key = "\(display)|\(fontSize)|\(color.description)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let node = MathParser.parse(latex)
        var context = Context(size: fontSize, color: color, style: display ? .display : .text)
        let box = context.layout(node)
        let pad: CGFloat = 2
        let size = NSSize(width: ceil(box.width + pad * 2), height: ceil(box.ascent + box.descent + pad * 2))
        let image = NSImage(size: NSSize(width: max(1, size.width), height: max(1, size.height)), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            box.draw(in: ctx, at: CGPoint(x: pad, y: pad + box.descent))
            return true
        }
        let rendered = Rendered(image: image, baseline: pad + box.descent, hasErrors: context.hadError)
        cache.setObject(CacheBox(rendered), forKey: key)
        return rendered
    }

    // MARK: Boxes (origin at the baseline's left end, y up)

    struct Box {
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var items: [Item] = []
        /// Atom class of the box's first / last element, for inter-atom spacing.
        var leftClass: MathAtom = .ordinary
        var rightClass: MathAtom = .ordinary

        indirect enum Item {
            case glyph(String, NSFont, CGPoint, NSColor)
            case rect(CGRect, NSColor)
            case stroke(CGPath, CGFloat, NSColor)
            case box(Box, CGPoint)
            case scaledGlyph(String, NSFont, CGPoint, CGSize, NSColor)   // glyph stretched to a size
        }

        mutating func append(_ other: Box, at x: CGFloat, dy: CGFloat = 0) {
            items.append(.box(other, CGPoint(x: x, y: dy)))
            ascent = max(ascent, other.ascent + dy)
            descent = max(descent, other.descent - dy)
            width = max(width, x + other.width)
        }

        func draw(in ctx: CGContext, at origin: CGPoint) {
            for item in items {
                switch item {
                case .glyph(let text, let font, let p, let color):
                    drawText(text, font: font, color: color, at: CGPoint(x: origin.x + p.x, y: origin.y + p.y), in: ctx)
                case .rect(let r, let color):
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(r.offsetBy(dx: origin.x, dy: origin.y))
                case .stroke(let path, let width, let color):
                    ctx.saveGState()
                    ctx.translateBy(x: origin.x, y: origin.y)
                    ctx.addPath(path)
                    ctx.setStrokeColor(color.cgColor)
                    ctx.setLineWidth(width)
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.strokePath()
                    ctx.restoreGState()
                case .box(let box, let p):
                    box.draw(in: ctx, at: CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                case .scaledGlyph(let text, let font, let p, let size, let color):
                    let ink = inkBounds(text, font: font)
                    guard ink.width > 0, ink.height > 0 else { continue }
                    ctx.saveGState()
                    ctx.translateBy(x: origin.x + p.x, y: origin.y + p.y)
                    ctx.scaleBy(x: max(1, size.width / ink.width), y: size.height / ink.height)
                    drawText(text, font: font, color: color, at: CGPoint(x: -ink.minX, y: -ink.minY), in: ctx)
                    ctx.restoreGState()
                }
            }
        }
    }

    static func drawText(_ text: String, font: NSFont, color: NSColor, at p: CGPoint, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        // AppKit leaves a flipped text matrix in flipped destinations (the PDF exporter, print);
        // Core Text would then draw every glyph upside down.
        let saved = ctx.textMatrix
        ctx.textMatrix = .identity
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.textMatrix = saved
    }

    static func inkBounds(_ text: String, font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetImageBounds(line, nil)
    }

    static func advance(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: Layout

    enum Style {
        case display, text, script, scriptScript
        var scale: CGFloat {
            switch self {
            case .display, .text: return 1
            case .script: return 0.72
            case .scriptScript: return 0.55
            }
        }
        var script: Style { self == .display || self == .text ? .script : .scriptScript }
        var fractionPart: Style { self == .display ? .text : script }
        var isScript: Bool { self == .script || self == .scriptScript }
    }

    struct Context {
        let size: CGFloat
        let color: NSColor
        var style: Style
        var font: MathFont? = nil
        var hadError = false

        init(size: CGFloat, color: NSColor, style: Style) {
            self.size = size
            self.color = color
            self.style = style
        }

        var em: CGFloat { size * style.scale }
        var axis: CGFloat { em * 0.25 }
        var rule: CGFloat { max(0.6, em * 0.05) }
        func mathFont(_ points: CGFloat? = nil) -> NSFont {
            NSFont(name: "STIXTwoMath-Regular", size: points ?? em) ?? .systemFont(ofSize: points ?? em)
        }
        func textFont() -> NSFont {
            NSFont(name: "STIXTwoText", size: em) ?? NSFont(name: "TimesNewRomanPSMT", size: em) ?? .systemFont(ofSize: em)
        }

        func glyphBox(_ text: String, font: NSFont, cls: MathAtom) -> Box {
            let ink = MathRenderer.inkBounds(text, font: font)
            var box = Box()
            box.width = MathRenderer.advance(text, font: font)
            box.ascent = max(ink.maxY, em * 0.0)
            box.descent = max(-ink.minY, 0)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { box.ascent = em * 0.5 }
            box.items = [.glyph(text, font, .zero, color)]
            box.leftClass = cls
            box.rightClass = cls
            return box
        }

        mutating func with(_ style: Style, _ body: (inout Context) -> Box) -> Box {
            let saved = self.style
            self.style = style
            let result = body(&self)
            self.style = saved
            return result
        }

        mutating func layout(_ node: MathNode) -> Box {
            switch node {
            case .row(let items):
                return layoutRow(items)
            case .atom(let text, let cls):
                if cls == .operatorName {
                    return glyphBox(text, font: mathFont(), cls: .operatorName)
                }
                let styled = MathAlphabets.map(text, font: font, isVariable: cls == .variable)
                return glyphBox(styled, font: mathFont(), cls: cls)
            case .text(let text):
                return glyphBox(text, font: textFont(), cls: .ordinary)
            case .space(let ems):
                var box = Box()
                box.width = CGFloat(ems) * em
                return box
            case .error(let text):
                hadError = true
                var box = glyphBox(text, font: .monospacedSystemFont(ofSize: em * 0.85, weight: .regular), cls: .ordinary)
                box.items = box.items.map { item in
                    if case .glyph(let t, let f, let p, _) = item { return .glyph(t, f, p, .systemRed) }
                    return item
                }
                return box
            case .styled(let inner, let font):
                let saved = self.font
                self.font = font
                let box = layout(inner)
                self.font = saved
                return box
            case .fraction(let num, let den, let bar):
                return layoutFraction(num, den, bar: bar)
            case .scripts(let base, let sup, let sub):
                return layoutScripts(base, sup: sup, sub: sub)
            case .largeOp(let symbol, let limits):
                return layoutLargeOp(symbol, limits: limits, sup: nil, sub: nil)
            case .root(let radicand, let index):
                return layoutRoot(radicand, index: index)
            case .delimited(let left, let body, let right):
                let inner = layout(body)
                return layoutDelimited(left, inner, right)
            case .matrix(let rows, let left, let right, let alignment):
                let grid = layoutMatrix(rows, alignment: alignment)
                return left.isEmpty && right.isEmpty ? grid : layoutDelimited(left, grid, right)
            case .accent(let inner, let mark, let wide):
                return layoutAccent(inner, mark, wide: wide)
            case .underline(let inner):
                let body = layout(inner)
                var box = Box()
                box.append(body, at: 0)
                box.items.append(.rect(CGRect(x: 0, y: -body.descent - rule * 3, width: body.width, height: rule), color))
                box.descent = body.descent + rule * 4
                return box
            }
        }

        /// TeX inter-atom spacing (text / display styles only).
        func space(between left: MathAtom, _ right: MathAtom) -> CGFloat {
            guard !style.isScript else { return 0 }
            let thin = em * 3 / 18, medium = em * 4 / 18, thick = em * 5 / 18
            if left == .binary || right == .binary { return medium }
            if left == .relation || right == .relation { return (left == .open || right == .close) ? 0 : thick }
            if left == .punctuation { return thin }
            if left == .operatorName && (right == .variable || right == .ordinary || right == .number || right == .open) { return thin }
            return 0
        }

        mutating func layoutRow(_ items: [MathNode]) -> Box {
            var box = Box()
            var previous: MathAtom?
            var x: CGFloat = 0
            for (index, item) in items.enumerated() {
                // Large operators take scripts that follow them as limits.
                var child = layout(item)
                // Unary minus / plus: a binary at the start or after an operator is ordinary.
                if child.leftClass == .binary, previous == nil || [.binary, .relation, .open, .punctuation].contains(previous!) {
                    child.leftClass = .ordinary
                    child.rightClass = .ordinary
                }
                if let previous { x += space(between: previous, child.leftClass) }
                box.append(child, at: x)
                x += child.width
                previous = child.rightClass
                if index == 0 { box.leftClass = child.leftClass }
            }
            box.width = x
            box.rightClass = previous ?? .ordinary
            return box
        }

        mutating func layoutFraction(_ num: MathNode, _ den: MathNode, bar: Bool) -> Box {
            let part = style.fractionPart
            let n = with(part) { $0.layout(num) }
            let d = with(part) { $0.layout(den) }
            let gap = em * (style == .display ? 0.2 : 0.12)
            let width = max(n.width, d.width) + em * 0.2
            var box = Box()
            let numShift = axis + rule / 2 + gap + n.descent
            let denShift = axis - rule / 2 - gap - d.ascent
            box.append(n, at: (width - n.width) / 2, dy: numShift)
            box.append(d, at: (width - d.width) / 2, dy: denShift)
            if bar { box.items.append(.rect(CGRect(x: em * 0.05, y: axis - rule / 2, width: width - em * 0.1, height: rule), color)) }
            box.width = width
            box.leftClass = .ordinary
            box.rightClass = .ordinary
            return box
        }

        mutating func layoutScripts(_ base: MathNode, sup: MathNode?, sub: MathNode?) -> Box {
            if case .largeOp(let symbol, let limits) = base {
                return layoutLargeOp(symbol, limits: limits, sup: sup, sub: sub)
            }
            let b = layout(base)
            let scriptStyle = style.script
            let supBox = sup.map { s in with(scriptStyle) { $0.layout(s) } }
            let subBox = sub.map { s in with(scriptStyle) { $0.layout(s) } }
            var box = Box()
            box.append(b, at: 0)
            let x = b.width + em * 0.04
            var supShift = max(b.ascent - em * 0.3, em * 0.42)
            var subShift = max(b.descent + em * 0.1, em * 0.18)
            if let s = supBox, let t = subBox {
                // Keep a gap between the two scripts.
                let gap = (supShift - s.descent) - (t.ascent - subShift)
                if gap < em * 0.18 { supShift += (em * 0.18 - gap) / 2; subShift += (em * 0.18 - gap) / 2 }
            }
            if let s = supBox { box.append(s, at: x, dy: supShift) }
            if let t = subBox { box.append(t, at: x, dy: -subShift) }
            box.width = x + max(supBox?.width ?? 0, subBox?.width ?? 0) + em * 0.04
            box.leftClass = b.leftClass
            box.rightClass = b.rightClass
            return box
        }

        mutating func layoutLargeOp(_ symbol: String, limits: Bool, sup: MathNode?, sub: MathNode?) -> Box {
            let isName = symbol.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            let opSize = isName ? em : em * (style == .display ? 1.65 : 1.2)
            var op = glyphBox(symbol, font: mathFont(opSize), cls: .operatorName)
            if !isName {
                // Centre the operator on the math axis.
                let shift = axis - (op.ascent - op.descent) / 2
                var shifted = Box()
                shifted.append(op, at: 0, dy: shift)
                shifted.leftClass = .operatorName
                shifted.rightClass = .operatorName
                op = shifted
            }
            guard sup != nil || sub != nil else { return op }
            let scriptStyle = style.script
            let supBox = sup.map { s in with(scriptStyle) { $0.layout(s) } }
            let subBox = sub.map { s in with(scriptStyle) { $0.layout(s) } }
            var box = Box()
            if limits && style == .display {
                let width = max(op.width, supBox?.width ?? 0, subBox?.width ?? 0)
                box.append(op, at: (width - op.width) / 2)
                let gap = em * 0.12
                if let s = supBox { box.append(s, at: (width - s.width) / 2, dy: op.ascent + gap + s.descent) }
                if let t = subBox { box.append(t, at: (width - t.width) / 2, dy: -(op.descent + gap + t.ascent)) }
                box.width = width
            } else {
                box.append(op, at: 0)
                let x = op.width + (symbol == "∫" || symbol == "∮" ? -em * 0.05 : em * 0.04)
                if let s = supBox { box.append(s, at: x + (isName ? 0 : em * 0.1), dy: max(op.ascent - s.ascent * 0.6, em * 0.4)) }
                if let t = subBox { box.append(t, at: x, dy: -max(op.descent + t.ascent * 0.3, em * 0.25)) }
                box.width = x + max((supBox?.width ?? 0) + (isName ? 0 : em * 0.1), subBox?.width ?? 0)
            }
            box.leftClass = .operatorName
            box.rightClass = .operatorName
            return box
        }

        mutating func layoutRoot(_ radicand: MathNode, index: MathNode?) -> Box {
            let body = layout(radicand)
            let gap = em * 0.12
            let height = max(body.ascent, em * 0.7) + gap + rule
            let depth = max(body.descent, em * 0.15)
            let indexBox = index.map { node in with(.scriptScript) { $0.layout(node) } }
            let lead = max(0, (indexBox?.width ?? 0) - em * 0.25)
            let tick = em * 0.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: lead, y: axis * 0.6))
            path.addLine(to: CGPoint(x: lead + tick * 0.3, y: axis * 0.9))
            path.addLine(to: CGPoint(x: lead + tick * 0.62, y: -depth))
            path.addLine(to: CGPoint(x: lead + tick, y: height))
            path.addLine(to: CGPoint(x: lead + tick + body.width + em * 0.12, y: height))
            var box = Box()
            box.items.append(.stroke(path, rule * 1.1, color))
            box.append(body, at: lead + tick + em * 0.06)
            if let indexBox { box.append(indexBox, at: 0, dy: axis + em * 0.25) }
            box.ascent = max(box.ascent, height + rule)
            box.descent = max(box.descent, depth)
            box.width = lead + tick + body.width + em * 0.18
            return box
        }

        mutating func layoutDelimited(_ left: String, _ inner: Box, _ right: String) -> Box {
            // Stretch the delimiters symmetrically around the axis to cover the content.
            let half = max(inner.ascent - axis, inner.descent + axis, em * 0.45) + em * 0.08
            let height = half * 2
            func delimiter(_ symbol: String) -> Box {
                guard !symbol.isEmpty else { return Box() }
                let font = mathFont()
                let natural = MathRenderer.inkBounds(symbol, font: font)
                var box = Box()
                if height <= natural.height * 1.15 {
                    box = glyphBox(symbol, font: font, cls: .ordinary)
                } else if symbol == "|" || symbol == "‖" {
                    // Bars stay thin rules: scaling the glyph to a delimiter's width made a block.
                    let bars = symbol == "‖" ? 2 : 1
                    let gap = em * 0.12
                    let pad = em * 0.08
                    for i in 0..<bars {
                        box.items.append(.rect(CGRect(x: pad + CGFloat(i) * gap, y: axis - half, width: rule, height: height), color))
                    }
                    box.width = pad * 2 + CGFloat(bars - 1) * gap + rule
                    box.ascent = axis + half
                    box.descent = half - axis
                } else {
                    let width = max(natural.width, em * 0.32) * min(1.6, 1 + (height / natural.height - 1) * 0.12)
                    box.items = [.scaledGlyph(symbol, font, CGPoint(x: em * 0.04, y: axis - half), CGSize(width: width, height: height), color)]
                    box.width = width + em * 0.08
                    box.ascent = axis + half
                    box.descent = half - axis
                }
                return box
            }
            var box = Box()
            let l = delimiter(left)
            let r = delimiter(right)
            box.append(l, at: 0)
            box.append(inner, at: l.width + em * 0.04)
            box.append(r, at: l.width + inner.width + em * 0.08)
            box.width = l.width + inner.width + r.width + em * 0.08
            box.leftClass = .open
            box.rightClass = .close
            return box
        }

        mutating func layoutMatrix(_ rows: [[MathNode]], alignment: MatrixAlignment) -> Box {
            guard !rows.isEmpty else { return Box() }
            let cells = rows.map { row in row.map { layout($0) } }
            let columns = cells.map(\.count).max() ?? 0
            var widths = Array(repeating: CGFloat(0), count: columns)
            for row in cells { for (c, cell) in row.enumerated() { widths[c] = max(widths[c], cell.width) } }
            let rowGap = em * 0.35
            let colGap = alignment == .aligned ? 0 : em * (alignment == .cases ? 1.0 : 0.8)
            let heights = cells.map { row in (row.map(\.ascent).max() ?? em * 0.7, row.map(\.descent).max() ?? em * 0.2) }
            let total = heights.reduce(0) { $0 + $1.0 + $1.1 } + rowGap * CGFloat(rows.count - 1)
            var box = Box()
            var y = total / 2 + axis   // top of the grid, centred on the axis
            for (r, row) in cells.enumerated() {
                y -= heights[r].0
                var x: CGFloat = 0
                for (c, cell) in row.enumerated() {
                    let w = widths[c]
                    let dx: CGFloat
                    switch alignment {
                    case .centered: dx = (w - cell.width) / 2
                    case .cases: dx = 0
                    case .aligned: dx = c % 2 == 0 ? w - cell.width : 0
                    }
                    box.append(cell, at: x + dx, dy: y)
                    x += w + (c < columns - 1 ? (alignment == .aligned && c % 2 == 0 ? em * 0.15 : colGap) : 0)
                }
                y -= heights[r].1 + rowGap
            }
            box.width = widths.reduce(0, +) + (alignment == .aligned ? em * 0.15 * CGFloat(max(0, columns - 1)) : colGap * CGFloat(max(0, columns - 1)))
            box.ascent = max(box.ascent, total / 2 + axis)
            box.descent = max(box.descent, total / 2 - axis)
            return box
        }

        mutating func layoutAccent(_ inner: MathNode, _ mark: String, wide: Bool) -> Box {
            let body = layout(inner)
            var box = Box()
            box.append(body, at: 0)
            let top = max(body.ascent, em * 0.5) + em * 0.06
            if mark == "‾" {
                box.items.append(.rect(CGRect(x: 0, y: top, width: body.width, height: rule), color))
                box.ascent = top + rule
            } else if mark == "→" {
                let path = CGMutablePath()
                let w = wide ? body.width : max(body.width, em * 0.45)
                let y = top + em * 0.08
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: w, y: y))
                path.move(to: CGPoint(x: w - em * 0.12, y: y + em * 0.07))
                path.addLine(to: CGPoint(x: w, y: y))
                path.addLine(to: CGPoint(x: w - em * 0.12, y: y - em * 0.07))
                box.items.append(.stroke(path, rule, color))
                box.ascent = y + em * 0.1
                box.width = max(body.width, w)
            } else {
                let accent = glyphBox(mark, font: mathFont(), cls: .ordinary)
                let ink = MathRenderer.inkBounds(mark, font: mathFont())
                if wide && body.width > accent.width * 1.4 {
                    box.items.append(.scaledGlyph(mark, mathFont(), CGPoint(x: 0, y: top), CGSize(width: body.width, height: max(1, ink.height)), color))
                    box.ascent = top + ink.height
                } else {
                    box.append(accent, at: (body.width - accent.width) / 2, dy: top - ink.minY)
                }
            }
            box.leftClass = body.leftClass
            box.rightClass = body.rightClass
            return box
        }
    }
}

/// Unicode mathematical alphanumerics (italic variables, \mathbb, \mathcal, …).
enum MathAlphabets {
    static func map(_ text: String, font: MathFont?, isVariable: Bool) -> String {
        guard let font else { return isVariable ? text.map(italic).joined() : text }
        return text.map { styled($0, font) }.joined()
    }

    private static func scalar(_ value: Int) -> String {
        UnicodeScalar(value).map { String(Character($0)) } ?? ""
    }

    static func italic(_ c: Character) -> String {
        guard let v = c.unicodeScalars.first?.value else { return String(c) }
        switch v {
        case 0x68: return "ℎ"                                  // italic h is in Letterlike Symbols
        case 0x41...0x5A: return scalar(0x1D434 + Int(v - 0x41))
        case 0x61...0x7A: return scalar(0x1D44E + Int(v - 0x61))
        case 0x3B1...0x3C9: return scalar(0x1D6FC + Int(v - 0x3B1)) // α…ω
        case 0x3D5: return "𝜙"
        case 0x3F5: return "𝜖"
        case 0x3D1: return "𝜗"
        default: return String(c)
        }
    }

    static func styled(_ c: Character, _ font: MathFont) -> String {
        guard let v = c.unicodeScalars.first?.value else { return String(c) }
        let upper = (0x41...0x5A).contains(v), lower = (0x61...0x7A).contains(v), digit = (0x30...0x39).contains(v)
        let u = Int(v) - 0x41, l = Int(v) - 0x61, d = Int(v) - 0x30
        switch font {
        case .roman: return String(c)
        case .italic: return italic(c)
        case .bold:
            if upper { return scalar(0x1D400 + u) }
            if lower { return scalar(0x1D41A + l) }
            if digit { return scalar(0x1D7CE + d) }
        case .blackboard:
            let exceptions: [Character: String] = ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
            if let e = exceptions[c] { return e }
            if upper { return scalar(0x1D538 + u) }
            if lower { return scalar(0x1D552 + l) }
            if digit { return scalar(0x1D7D8 + d) }
        case .calligraphic:
            let exceptions: [Character: String] = ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ", "e": "ℯ", "g": "ℊ", "o": "ℴ"]
            if let e = exceptions[c] { return e }
            if upper { return scalar(0x1D49C + u) }
            if lower { return scalar(0x1D4B6 + l) }
        case .fraktur:
            let exceptions: [Character: String] = ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"]
            if let e = exceptions[c] { return e }
            if upper { return scalar(0x1D504 + u) }
            if lower { return scalar(0x1D51E + l) }
        case .sansSerif:
            if upper { return scalar(0x1D5A0 + u) }
            if lower { return scalar(0x1D5BA + l) }
            if digit { return scalar(0x1D7E2 + d) }
        case .monospace:
            if upper { return scalar(0x1D670 + u) }
            if lower { return scalar(0x1D68A + l) }
            if digit { return scalar(0x1D7F6 + d) }
        }
        return String(c)
    }
}
