import AppKit
import MarkaCore

/// Draws `Mermaid` diagrams (flowchart, sequence, pie) natively with Core Graphics.
enum MermaidRenderer {
    struct Palette {
        var nodeFill: NSColor
        var nodeStroke: NSColor
        var text: NSColor
        var line: NSColor
        var labelFill: NSColor
        var noteFill: NSColor
        var noteStroke: NSColor
        var slices: [NSColor]

        static func standard(dark: Bool) -> Palette {
            func hex(_ v: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
            }
            let slices = [0x4C78A8, 0xF58518, 0x54A24B, 0xE45756, 0x72B7B2, 0xB279A2, 0xFF9DA6, 0x9D755D, 0xBAB0AC, 0xEECA3B].map(hex)
            return dark
                ? Palette(nodeFill: hex(0x2F3446), nodeStroke: hex(0x8C8CFF), text: hex(0xE6E6E6), line: hex(0xC8C8C8),
                          labelFill: hex(0x3A3A3A), noteFill: hex(0x5A5530), noteStroke: hex(0xA8A060), slices: slices)
                : Palette(nodeFill: hex(0xECECFF), nodeStroke: hex(0x9370DB), text: hex(0x333333), line: hex(0x333333),
                          labelFill: hex(0xE8E8E8), noteFill: hex(0xFFF5AD), noteStroke: hex(0xAAAA33), slices: slices)
        }
    }

    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()   // NSCache is thread-safe

    static func render(_ source: String, fontSize: CGFloat, dark: Bool) -> NSImage {
        let key = "\(dark)|\(fontSize)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let palette = Palette.standard(dark: dark)
        let font = NSFont.systemFont(ofSize: fontSize)
        let image: NSImage
        switch Mermaid.parse(source) {
        case .flowchart(let chart): image = flowchart(chart, font: font, palette: palette)
        case .sequence(let diagram): image = sequence(diagram, font: font, palette: palette)
        case .pie(let pie): image = pieChart(pie, font: font, palette: palette)
        case .unsupported(let kind): image = message("Mermaid “\(kind)” diagrams are not supported yet — flowchart, sequenceDiagram and pie are.", font: font, palette: palette)
        case .empty: image = message("Empty Mermaid diagram", font: font, palette: palette)
        }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: Text

    static func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    static func textSize(_ text: String, font: NSFont) -> CGSize {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: 260, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font, .black)
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    static func drawText(_ text: String, centeredIn rect: CGRect, font: NSFont, color: NSColor) {
        let size = textSize(text, font: font)
        let r = CGRect(x: rect.midX - size.width / 2 - 1, y: rect.midY - size.height / 2, width: size.width + 2, height: size.height)
        (text as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(font, color))
    }

    static func image(size: CGSize, draw: @escaping () -> Void) -> NSImage {
        NSImage(size: NSSize(width: max(1, ceil(size.width)), height: max(1, ceil(size.height))), flipped: true) { _ in
            draw()
            return true
        }
    }

    // MARK: Flowchart

    static func nodeSize(_ node: Flowchart.Node, font: NSFont) -> CGSize {
        let t = textSize(node.label, font: font)
        var w = t.width + 28, h = t.height + 18
        switch node.shape {
        case .circle: let d = max(w, h) + 4; w = d; h = d
        case .rhombus: w = t.width * 1.4 + 40; h = max(t.height * 1.6 + 26, w * 0.45)
        case .hexagon: w += 24
        case .stadium: w += 16
        case .database: h += 14
        case .subroutine: w += 16
        case .asymmetric: w += 14
        case .rectangle, .rounded: break
        }
        return CGSize(width: max(w, 44), height: max(h, 34))
    }

    static func shapePath(_ shape: Flowchart.Shape, in r: CGRect) -> NSBezierPath {
        switch shape {
        case .rectangle, .subroutine: return NSBezierPath(rect: r)
        case .rounded: return NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        case .stadium: return NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        case .circle: return NSBezierPath(ovalIn: r)
        case .rhombus:
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.midY))
            p.line(to: CGPoint(x: r.midX, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.midY)); p.close()
            return p
        case .hexagon:
            let inset = min(16, r.width / 4)
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX + inset, y: r.minY)); p.line(to: CGPoint(x: r.maxX - inset, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.midY)); p.line(to: CGPoint(x: r.maxX - inset, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + inset, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.midY)); p.close()
            return p
        case .database:
            let e: CGFloat = 7
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY + e))
            p.line(to: CGPoint(x: r.minX, y: r.maxY - e))
            p.curve(to: CGPoint(x: r.maxX, y: r.maxY - e), controlPoint1: CGPoint(x: r.minX, y: r.maxY + e * 0.35), controlPoint2: CGPoint(x: r.maxX, y: r.maxY + e * 0.35))
            p.line(to: CGPoint(x: r.maxX, y: r.minY + e))
            p.appendOval(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: e * 2))
            return p
        case .asymmetric:
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + 12, y: r.midY)); p.close()
            return p
        }
    }

    static func arrowHead(at tip: CGPoint, from: CGPoint, color: NSColor, size: CGFloat = 9) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let p = NSBezierPath()
        p.move(to: tip)
        p.line(to: CGPoint(x: tip.x - size * cos(angle - .pi / 7), y: tip.y - size * sin(angle - .pi / 7)))
        p.line(to: CGPoint(x: tip.x - size * cos(angle + .pi / 7), y: tip.y - size * sin(angle + .pi / 7)))
        p.close()
        color.setFill()
        p.fill()
    }

    static func flowchart(_ chart: Flowchart, font: NSFont, palette: Palette) -> NSImage {
        let layout = chart.layout { nodeSize($0, font: font) }
        let labelFont = NSFont.systemFont(ofSize: font.pointSize * 0.9)
        // Grow the canvas so edge-label chips never clip at the edge.
        var canvas = layout.size
        for (index, edge) in chart.edges.enumerated() where index < layout.edgeLabels.count {
            guard let label = edge.label, !label.isEmpty, let at = layout.edgeLabels[index] else { continue }
            let size = textSize(label, font: labelFont)
            canvas.width = max(canvas.width, at.x + size.width / 2 + 5 + 8)
            canvas.height = max(canvas.height, at.y + size.height / 2 + 2 + 8)
        }
        return image(size: canvas) {
            for (index, edge) in chart.edges.enumerated() where index < layout.edges.count {
                let points = layout.edges[index]
                guard points.count >= 2 else { continue }
                let path = NSBezierPath()
                path.move(to: points[0])
                if points.count == 4, edge.from != edge.to {
                    path.curve(to: points[3], controlPoint1: points[1], controlPoint2: points[2])
                } else if points.count == 4 {
                    path.curve(to: points[3], controlPoint1: points[1], controlPoint2: points[2])
                } else {
                    points.dropFirst().forEach { path.line(to: $0) }
                }
                path.lineWidth = edge.style == .thick ? 2.6 : 1.4
                if edge.style == .dotted { path.setLineDash([3, 3], count: 2, phase: 0) }
                palette.line.setStroke()
                path.stroke()
                let n = points.count
                if edge.arrowAtEnd { arrowHead(at: points[n - 1], from: points[n - 2], color: palette.line) }
                if edge.arrowAtStart { arrowHead(at: points[0], from: points[1], color: palette.line) }
                if let label = edge.label, !label.isEmpty, let at = layout.edgeLabels[index] {
                    let size = textSize(label, font: labelFont)
                    let chip = CGRect(x: at.x - size.width / 2 - 5, y: at.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
                    palette.labelFill.setFill()
                    NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
                    drawText(label, centeredIn: chip, font: labelFont, color: palette.text)
                }
            }
            for node in chart.nodes {
                guard let r = layout.nodes[node.id] else { continue }
                let shape = shapePath(node.shape, in: r.insetBy(dx: 0.75, dy: 0.75))
                palette.nodeFill.setFill()
                shape.fill()
                palette.nodeStroke.setStroke()
                shape.lineWidth = 1.2
                shape.stroke()
                if node.shape == .subroutine {
                    let inner = NSBezierPath()
                    inner.move(to: CGPoint(x: r.minX + 8, y: r.minY)); inner.line(to: CGPoint(x: r.minX + 8, y: r.maxY))
                    inner.move(to: CGPoint(x: r.maxX - 8, y: r.minY)); inner.line(to: CGPoint(x: r.maxX - 8, y: r.maxY))
                    inner.lineWidth = 1.2
                    inner.stroke()
                }
                let textRect = node.shape == .database ? r.offsetBy(dx: 0, dy: 5) : r
                drawText(node.label, centeredIn: textRect, font: font, color: palette.text)
            }
        }
    }

    // MARK: Sequence diagram

    static func sequence(_ d: SequenceDiagram, font: NSFont, palette: Palette) -> NSImage {
        let margin: CGFloat = 12
        let boxHeight: CGFloat = 36
        let gap: CGFloat = 46
        let widths = d.participants.map { max(textSize($0.label, font: font).width + 28, 70) }
        // Widen gaps so message texts fit between lifelines.
        var gaps = Array(repeating: gap, count: max(0, d.participants.count - 1))
        let index = Dictionary(uniqueKeysWithValues: d.participants.enumerated().map { ($1.id, $0) })
        for event in d.events {
            if case .message(let from, let to, let text, _, _) = event, let a = index[from], let b = index[to], a != b {
                let need = textSize(text, font: font).width + 20
                let lo = min(a, b), hi = max(a, b)
                var have: CGFloat = 0
                for i in lo..<hi {
                    let centres: CGFloat = (widths[i] + widths[i + 1]) / 2
                    have += gaps[i] + centres
                }
                if have < need { gaps[lo] += need - have }
            }
        }
        var centers: [CGFloat] = []
        var x = margin
        for (i, w) in widths.enumerated() {
            centers.append(x + w / 2)
            x += w + (i < gaps.count ? gaps[i] : 0)
        }
        let width = x + margin + 60
        let actorExtra: CGFloat = d.participants.contains(where: \.isActor) ? 30 : 0
        var y = margin + boxHeight + actorExtra + 18
        var rows: [(SequenceDiagram.Event, CGFloat, Int)] = []
        var number = 0   // autonumber counts messages only (notes are not numbered)
        for event in d.events {
            switch event {
            case .message(let from, let to, let text, _, _):
                let h = textSize(text, font: font).height
                number += 1
                rows.append((event, y + h, number))
                y += h + (from == to ? 46 : 30)
            case .note(_, _, let text):
                let h = textSize(text, font: font).height + 14
                rows.append((event, y, 0))
                y += h + 16
            }
        }
        let bottom = y + 4
        let height = bottom + boxHeight + margin
        return image(size: CGSize(width: width, height: height)) {
            func participantBox(_ i: Int, top: CGFloat) {
                let p = d.participants[i]
                let r = CGRect(x: centers[i] - widths[i] / 2, y: top, width: widths[i], height: boxHeight)
                if p.isActor {
                    let cx = centers[i], headY = top - actorExtra + 4
                    let stick = NSBezierPath(ovalIn: CGRect(x: cx - 6, y: headY, width: 12, height: 12))
                    stick.move(to: CGPoint(x: cx, y: headY + 12)); stick.line(to: CGPoint(x: cx, y: headY + 24))
                    stick.move(to: CGPoint(x: cx - 9, y: headY + 16)); stick.line(to: CGPoint(x: cx + 9, y: headY + 16))
                    stick.move(to: CGPoint(x: cx, y: headY + 24)); stick.line(to: CGPoint(x: cx - 7, y: headY + 32))
                    stick.move(to: CGPoint(x: cx, y: headY + 24)); stick.line(to: CGPoint(x: cx + 7, y: headY + 32))
                    palette.nodeStroke.setStroke(); stick.lineWidth = 1.3; stick.stroke()
                }
                let box = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                palette.nodeFill.setFill(); box.fill()
                palette.nodeStroke.setStroke(); box.lineWidth = 1.2; box.stroke()
                drawText(p.label, centeredIn: r, font: font, color: palette.text)
            }
            let top = margin + actorExtra
            for i in d.participants.indices {
                let life = NSBezierPath()
                life.move(to: CGPoint(x: centers[i], y: top + boxHeight))
                life.line(to: CGPoint(x: centers[i], y: bottom))
                life.setLineDash([4, 3], count: 2, phase: 0)
                life.lineWidth = 1
                palette.line.withAlphaComponent(0.5).setStroke()
                life.stroke()
                participantBox(i, top: top)
                participantBox(i, top: bottom)
            }
            for (event, rowY, number) in rows {
                switch event {
                case .message(let from, let to, var text, let dashed, let arrow):
                    guard let a = index[from], let b = index[to] else { continue }
                    if d.autonumber { text = "\(number). " + text }
                    let path = NSBezierPath()
                    let x1 = centers[a], x2 = centers[b]
                    if a == b {
                        path.move(to: CGPoint(x: x1, y: rowY))
                        path.line(to: CGPoint(x: x1 + 34, y: rowY))
                        path.line(to: CGPoint(x: x1 + 34, y: rowY + 22))
                        path.line(to: CGPoint(x: x1 + 2, y: rowY + 22))
                        let t = textSize(text, font: font)
                        drawText(text, centeredIn: CGRect(x: x1 + 40, y: rowY - t.height / 2 + 11, width: t.width + 4, height: t.height), font: font, color: palette.text)
                    } else {
                        let dir: CGFloat = x2 > x1 ? 1 : -1
                        path.move(to: CGPoint(x: x1, y: rowY))
                        path.line(to: CGPoint(x: x2 - dir * 1, y: rowY))
                        let t = textSize(text, font: font)
                        drawText(text, centeredIn: CGRect(x: min(x1, x2), y: rowY - t.height - 4, width: abs(x2 - x1), height: t.height), font: font, color: palette.text)
                    }
                    if dashed { path.setLineDash([5, 3], count: 2, phase: 0) }
                    path.lineWidth = 1.3
                    palette.line.setStroke()
                    path.stroke()
                    let end = a == b ? CGPoint(x: x1 + 2, y: rowY + 22) : CGPoint(x: x2, y: rowY)
                    let before = a == b ? CGPoint(x: x1 + 34, y: rowY + 22) : CGPoint(x: x1, y: rowY)
                    switch arrow {
                    case .filled: arrowHead(at: end, from: before, color: palette.line)
                    case .open:
                        let angle = atan2(end.y - before.y, end.x - before.x)
                        let p = NSBezierPath()
                        p.move(to: CGPoint(x: end.x - 9 * cos(angle - .pi / 7), y: end.y - 9 * sin(angle - .pi / 7)))
                        p.line(to: end)
                        p.line(to: CGPoint(x: end.x - 9 * cos(angle + .pi / 7), y: end.y - 9 * sin(angle + .pi / 7)))
                        p.lineWidth = 1.3; p.stroke()
                    case .cross:
                        let p = NSBezierPath()
                        p.move(to: CGPoint(x: end.x - 5, y: end.y - 5)); p.line(to: CGPoint(x: end.x + 5, y: end.y + 5))
                        p.move(to: CGPoint(x: end.x - 5, y: end.y + 5)); p.line(to: CGPoint(x: end.x + 5, y: end.y - 5))
                        p.lineWidth = 1.5; p.stroke()
                    case .none: break
                    }
                case .note(let over, let position, let text):
                    let ids = over.compactMap { index[$0] }
                    guard let first = ids.min(), let last = ids.max() else { continue }
                    let t = textSize(text, font: font)
                    let w = max(t.width + 20, position == .over ? centers[last] - centers[first] + 40 : 0)
                    let x0: CGFloat
                    switch position {
                    case .leftOf: x0 = centers[first] - w - 8
                    case .rightOf: x0 = centers[last] + 8
                    case .over: x0 = (centers[first] + centers[last]) / 2 - w / 2
                    }
                    let r = CGRect(x: max(2, x0), y: rowY, width: w, height: t.height + 14)
                    let note = NSBezierPath(rect: r)
                    palette.noteFill.setFill(); note.fill()
                    palette.noteStroke.setStroke(); note.lineWidth = 1; note.stroke()
                    drawText(text, centeredIn: r, font: font, color: palette.text)
                }
            }
        }
    }

    // MARK: Pie chart

    static func pieChart(_ pie: PieChart, font: NSFont, palette: Palette) -> NSImage {
        let radius: CGFloat = 95
        let titleHeight: CGFloat = pie.title == nil ? 0 : textSize(pie.title!, font: .boldSystemFont(ofSize: font.pointSize * 1.15)).height + 12
        let legendWidth = (pie.slices.map { textSize("\($0.label) (\(format($0.value)))", font: font).width }.max() ?? 0) + 34
        let width = radius * 2 + 40 + legendWidth + 20
        let height = max(radius * 2 + 30, CGFloat(pie.slices.count) * 22 + 20) + titleHeight
        let total = max(pie.slices.reduce(0) { $0 + $1.value }, 0.000_001)
        return image(size: CGSize(width: width, height: height)) {
            if let title = pie.title {
                drawText(title, centeredIn: CGRect(x: 0, y: 6, width: width, height: titleHeight - 6), font: .boldSystemFont(ofSize: font.pointSize * 1.15), color: palette.text)
            }
            let center = CGPoint(x: 20 + radius, y: titleHeight + 15 + radius)
            var angle: CGFloat = -90
            for (i, slice) in pie.slices.enumerated() {
                let sweep = CGFloat(slice.value / total) * 360
                let path = NSBezierPath()
                path.move(to: center)
                path.appendArc(withCenter: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
                path.close()
                palette.slices[i % palette.slices.count].setFill()
                path.fill()
                NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
                if sweep > 14 {
                    let mid = (angle + sweep / 2) * .pi / 180
                    let at = CGPoint(x: center.x + cos(mid) * radius * 0.62, y: center.y + sin(mid) * radius * 0.62)
                    let percent = "\(Int((slice.value / total * 100).rounded()))%"
                    drawText(percent, centeredIn: CGRect(x: at.x - 24, y: at.y - 9, width: 48, height: 18), font: .boldSystemFont(ofSize: font.pointSize * 0.9), color: .white)
                }
                angle += sweep
            }
            var y = titleHeight + 15 + radius - CGFloat(pie.slices.count) * 11
            for (i, slice) in pie.slices.enumerated() {
                let swatch = CGRect(x: center.x + radius + 24, y: y + 3, width: 12, height: 12)
                palette.slices[i % palette.slices.count].setFill()
                NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
                let text = "\(slice.label) (\(format(slice.value)))" as NSString
                text.draw(at: CGPoint(x: swatch.maxX + 8, y: y), withAttributes: [.font: font, .foregroundColor: palette.text])
                y += 22
            }
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func message(_ text: String, font: NSFont, palette: Palette) -> NSImage {
        let size = textSize(text, font: font)
        let box = CGSize(width: size.width + 32, height: size.height + 24)
        return image(size: box) {
            let r = CGRect(origin: .zero, size: box).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            palette.labelFill.setFill(); path.fill()
            path.setLineDash([4, 3], count: 2, phase: 0)
            palette.nodeStroke.setStroke(); path.stroke()
            drawText(text, centeredIn: r, font: font, color: palette.text)
        }
    }
}
