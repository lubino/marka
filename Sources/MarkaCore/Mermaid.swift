import CoreGraphics
import Foundation

/// A native subset of Mermaid (https://mermaid.js.org): flowcharts, sequence diagrams and pie
/// charts. Parsing and layout are pure geometry here; drawing lives in the app (`MermaidRenderer`).
public enum Mermaid {
    public enum Diagram: Equatable, Sendable {
        case flowchart(Flowchart)
        case sequence(SequenceDiagram)
        case pie(PieChart)
        /// A diagram type Marka does not draw (yet), e.g. "gantt".
        case unsupported(String)
        case empty
    }

    public static func parse(_ source: String) -> Diagram {
        let lines = source.components(separatedBy: .newlines)
            .map { line -> String in
                // `%%` comments
                if let r = line.range(of: "%%") { return String(line[..<r.lowerBound]) }
                return line
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { return .empty }
        let keyword = header.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        let body = Array(lines.dropFirst())
        switch keyword {
        case "graph", "flowchart":
            return .flowchart(Flowchart.parse(header: header, lines: body))
        case "sequencediagram":
            return .sequence(SequenceDiagram.parse(lines: body))
        case "pie":
            return .pie(PieChart.parse(header: header, lines: body))
        default:
            return .unsupported(keyword)
        }
    }
}

// MARK: - Flowchart

public struct Flowchart: Equatable, Sendable {
    public enum Direction: String, Sendable { case topDown, bottomUp, leftRight, rightLeft }
    public enum Shape: String, Sendable { case rectangle, rounded, stadium, circle, rhombus, hexagon, subroutine, database, asymmetric }
    public enum EdgeStyle: String, Sendable { case arrow, open, dotted, thick }

    public struct Node: Equatable, Sendable {
        public var id: String
        public var label: String
        public var shape: Shape
    }

    public struct Edge: Equatable, Sendable {
        public var from: String
        public var to: String
        public var label: String?
        public var style: EdgeStyle
        public var arrowAtEnd: Bool
        public var arrowAtStart: Bool
    }

    public var direction: Direction = .topDown
    public var nodes: [Node] = []
    public var edges: [Edge] = []

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    static func parse(header: String, lines: [String]) -> Flowchart {
        var chart = Flowchart()
        let parts = header.split(separator: " ")
        if parts.count > 1 {
            switch parts[1].uppercased() {
            case "BT": chart.direction = .bottomUp
            case "LR": chart.direction = .leftRight
            case "RL": chart.direction = .rightLeft
            default: chart.direction = .topDown
            }
        }
        for raw in lines {
            let lower = raw.lowercased()
            if lower.hasPrefix("subgraph") || lower == "end" || lower.hasPrefix("classdef") || lower.hasPrefix("class ")
                || lower.hasPrefix("style ") || lower.hasPrefix("linkstyle") || lower.hasPrefix("click ") || lower.hasPrefix("direction ") {
                continue   // styling / grouping directives are not drawn
            }
            for statement in raw.split(separator: ";").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !statement.isEmpty {
                chart.parseStatement(statement)
            }
        }
        return chart
    }

    /// `A[Start] -->|yes| B{Ok?} --> C` — a chain of nodes joined by links.
    mutating func parseStatement(_ statement: String) {
        var scanner = Scanner(Array(statement))
        guard var previous = scanner.parseNodeGroup(into: &self) else { return }
        while true {
            scanner.skipSpaces()
            guard let link = scanner.parseLink() else { return }
            scanner.skipSpaces()
            guard let next = scanner.parseNodeGroup(into: &self) else { return }
            for from in previous {
                for to in next {
                    edges.append(Edge(from: from, to: to, label: link.label, style: link.style,
                                      arrowAtEnd: link.arrowEnd, arrowAtStart: link.arrowStart))
                }
            }
            previous = next
        }
    }

    mutating func addNode(_ id: String, label: String?, shape: Shape?) {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            if let label { nodes[index].label = label }
            if let shape { nodes[index].shape = shape }
        } else {
            nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rectangle))
        }
    }

    struct Scanner {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }

        mutating func skipSpaces() { while i < c.count, c[i] == " " { i += 1 } }

        /// `A & B` — one or more nodes.
        mutating func parseNodeGroup(into chart: inout Flowchart) -> [String]? {
            var ids: [String] = []
            while true {
                skipSpaces()
                guard let id = parseNode(into: &chart) else { break }
                ids.append(id)
                skipSpaces()
                if i < c.count, c[i] == "&" { i += 1; continue }
                break
            }
            return ids.isEmpty ? nil : ids
        }

        mutating func parseNode(into chart: inout Flowchart) -> String? {
            let start = i
            while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "." || (c[i] == "-" && i + 1 < c.count && c[i + 1] != "-" && c[i + 1] != ">" && c[i + 1] != ".") {
                i += 1
            }
            guard i > start else { return nil }
            let id = String(c[start..<i])
            // Shape and label
            let shapes: [(String, String, Shape)] = [
                ("([", "])", .stadium), ("[[", "]]", .subroutine), ("[(", ")]", .database), ("((", "))", .circle),
                ("{{", "}}", .hexagon), ("[", "]", .rectangle), ("(", ")", .rounded), ("{", "}", .rhombus), (">", "]", .asymmetric)
            ]
            for (open, close, shape) in shapes where matches(open) {
                i += open.count
                let labelStart = i
                while i < c.count, !matches(close) { i += 1 }
                var label = String(c[labelStart..<min(i, c.count)]).trimmingCharacters(in: .whitespaces)
                if label.hasPrefix("\""), label.hasSuffix("\""), label.count >= 2 { label = String(label.dropFirst().dropLast()) }
                if i < c.count { i += close.count }
                chart.addNode(id, label: label.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n"), shape: shape)
                return id
            }
            chart.addNode(id, label: nil, shape: nil)
            return id
        }

        func matches(_ s: String) -> Bool {
            let chars = Array(s)
            guard i + chars.count <= c.count else { return false }
            return Array(c[i..<(i + chars.count)]) == chars
        }

        struct Link { var style: EdgeStyle; var arrowEnd: Bool; var arrowStart: Bool; var label: String? }

        /// `-->`, `---`, `-.->`, `==>`, `<-->`, `-- text -->`, `-->|text|`.
        mutating func parseLink() -> Link? {
            let start = i
            var arrowStart = false
            if i < c.count, c[i] == "<" { arrowStart = true; i += 1 }
            var body = ""
            while i < c.count, "-=.>xo".contains(c[i]) {
                // stop before a node id that starts with x/o
                if (c[i] == "x" || c[i] == "o"), i + 1 < c.count, c[i + 1].isLetter || c[i + 1].isNumber { break }
                body.append(c[i]); i += 1
            }
            guard body.count >= 2 else { i = start; return nil }
            var label: String?
            // `-- text -->` form
            if body == "--" || body == "==" || body == "-." {
                skipSpaces()
                let textStart = i
                while i < c.count, !matches("-->"), !matches("---"), !matches("==>"), !matches(".->"), !matches("-.-") { i += 1 }
                let text = String(c[textStart..<i]).trimmingCharacters(in: .whitespaces)
                if i < c.count {
                    label = text.isEmpty ? nil : text
                    while i < c.count, "-=.>".contains(c[i]) { body.append(c[i]); i += 1 }
                } else {
                    i = textStart
                }
            }
            skipSpaces()
            if i < c.count, c[i] == "|" {
                i += 1
                let textStart = i
                while i < c.count, c[i] != "|" { i += 1 }
                label = String(c[textStart..<i]).trimmingCharacters(in: .whitespaces)
                if i < c.count { i += 1 }
            }
            let style: EdgeStyle = body.contains("=") ? .thick : (body.contains(".") ? .dotted : (body.hasSuffix(">") ? .arrow : .open))
            return Link(style: style, arrowEnd: body.hasSuffix(">"), arrowStart: arrowStart, label: label)
        }
    }

    // MARK: Layout

    public struct Layout: Equatable, Sendable {
        public var size: CGSize
        public var nodes: [String: CGRect]
        /// Polyline per edge (same order as `edges`), from the source border to the target border.
        public var edges: [[CGPoint]]
        public var edgeLabels: [CGPoint?]
    }

    /// Layered layout (Sugiyama-style): ranks by longest path (cycles broken), ordering by
    /// barycentres, then coordinates. `measure` returns each node's box size.
    public func layout(measure: (Node) -> CGSize, rankGap: CGFloat = 46, nodeGap: CGFloat = 28, margin: CGFloat = 12) -> Layout {
        guard !nodes.isEmpty else { return Layout(size: .zero, nodes: [:], edges: [], edgeLabels: []) }
        let ids = nodes.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        // Break cycles: DFS, ignore back edges for ranking.
        var state = Array(repeating: 0, count: ids.count)   // 0 new, 1 on stack, 2 done
        var forward: [(Int, Int)] = []
        var adjacency = Array(repeating: [Int](), count: ids.count)
        for edge in edges { if let a = index[edge.from], let b = index[edge.to], a != b { adjacency[a].append(b) } }
        func visit(_ v: Int) {
            state[v] = 1
            for w in adjacency[v] {
                if state[w] == 1 { continue }   // back edge
                forward.append((v, w))
                if state[w] == 0 { visit(w) }
            }
            state[v] = 2
        }
        for v in ids.indices where state[v] == 0 { visit(v) }
        // Longest-path ranks.
        var rank = Array(repeating: 0, count: ids.count)
        for _ in 0..<ids.count {
            var changed = false
            for (a, b) in forward where rank[b] < rank[a] + 1 { rank[b] = rank[a] + 1; changed = true }
            if !changed { break }
        }
        let rankCount = (rank.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: rankCount)
        for v in ids.indices { layers[rank[v]].append(v) }
        // Barycentre ordering sweeps.
        var position = Array(repeating: 0.0, count: ids.count)
        func renumber() { for layer in layers { for (p, v) in layer.enumerated() { position[v] = Double(p) } } }
        renumber()
        let preds = (0..<ids.count).map { v in forward.filter { $0.1 == v }.map(\.0) }
        let succs = (0..<ids.count).map { v in forward.filter { $0.0 == v }.map(\.1) }
        for sweep in 0..<6 {
            let down = sweep % 2 == 0
            let order = down ? Array(1..<max(1, rankCount)) : Array((0..<max(0, rankCount - 1)).reversed())
            for r in order where r < rankCount {
                layers[r].sort { a, b in
                    let na = down ? preds[a] : succs[a], nb = down ? preds[b] : succs[b]
                    let ba = na.isEmpty ? position[a] : na.map { position[$0] }.reduce(0, +) / Double(na.count)
                    let bb = nb.isEmpty ? position[b] : nb.map { position[$0] }.reduce(0, +) / Double(nb.count)
                    return ba == bb ? position[a] < position[b] : ba < bb
                }
                renumber()
            }
        }
        // Coordinates: "main" axis along ranks, "cross" axis within a rank.
        let horizontal = direction == .leftRight || direction == .rightLeft
        let sizes = nodes.map(measure)
        func main(_ s: CGSize) -> CGFloat { horizontal ? s.width : s.height }
        func cross(_ s: CGSize) -> CGFloat { horizontal ? s.height : s.width }
        let rankExtent = layers.map { layer in layer.map { main(sizes[$0]) }.max() ?? 0 }
        let layerCross = layers.map { layer in layer.map { cross(sizes[$0]) }.reduce(0, +) + CGFloat(max(0, layer.count - 1)) * nodeGap }
        let widest = layerCross.max() ?? 0
        var centers = Array(repeating: CGPoint.zero, count: ids.count)
        var mainOffset: CGFloat = margin
        for (r, layer) in layers.enumerated() {
            var crossOffset = margin + (widest - layerCross[r]) / 2
            for v in layer {
                let c = cross(sizes[v])
                let m = mainOffset + rankExtent[r] / 2
                let x = crossOffset + c / 2
                centers[v] = horizontal ? CGPoint(x: m, y: x) : CGPoint(x: x, y: m)
                crossOffset += c + nodeGap
            }
            mainOffset += rankExtent[r] + rankGap
        }
        let totalMain = mainOffset - rankGap + margin
        let totalCross = widest + margin * 2
        var size = horizontal ? CGSize(width: totalMain, height: totalCross) : CGSize(width: totalCross, height: totalMain)
        // Flip for bottom-up / right-left.
        if direction == .bottomUp { centers = centers.map { CGPoint(x: $0.x, y: size.height - $0.y) } }
        if direction == .rightLeft { centers = centers.map { CGPoint(x: size.width - $0.x, y: $0.y) } }
        var rects: [String: CGRect] = [:]
        for (v, id) in ids.enumerated() {
            rects[id] = CGRect(x: centers[v].x - sizes[v].width / 2, y: centers[v].y - sizes[v].height / 2,
                               width: sizes[v].width, height: sizes[v].height)
        }
        // Edges: border to border; back / same-rank edges bow out to the side.
        var paths: [[CGPoint]] = []
        var labels: [CGPoint?] = []
        for edge in edges {
            guard let a = rects[edge.from], let b = rects[edge.to] else { paths.append([]); labels.append(nil); continue }
            if edge.from == edge.to {
                let p0 = CGPoint(x: a.maxX, y: a.midY - 6), p1 = CGPoint(x: a.maxX + 22, y: a.midY - 14)
                let p2 = CGPoint(x: a.maxX + 22, y: a.midY + 14), p3 = CGPoint(x: a.maxX, y: a.midY + 6)
                paths.append([p0, p1, p2, p3]); labels.append(CGPoint(x: a.maxX + 26, y: a.midY)); continue
            }
            let start = Self.borderPoint(of: a, toward: CGPoint(x: b.midX, y: b.midY))
            let end = Self.borderPoint(of: b, toward: CGPoint(x: a.midX, y: a.midY))
            let isBack = (index[edge.from].map { rank[$0] } ?? 0) >= (index[edge.to].map { rank[$0] } ?? 0)
            if isBack {
                // Bow around: out to the side and back in, so it does not run through other nodes.
                // Route outside every node (not just the two ends), so the edge never crosses the chart.
                let side: CGFloat = 26
                let outer = horizontal ? (rects.values.map(\.maxY).max() ?? max(a.maxY, b.maxY)) : (rects.values.map(\.maxX).max() ?? max(a.maxX, b.maxX))
                // Leave along the flow direction (below the node in TD, right of it in LR) — never
                // sideways through a neighbour in the same rank — swing outside, enter from the side.
                let from = horizontal ? CGPoint(x: a.maxX, y: a.midY) : CGPoint(x: a.midX, y: a.maxY)
                let to = horizontal ? CGPoint(x: b.midX, y: b.maxY) : CGPoint(x: b.maxX, y: b.midY)
                let p1 = horizontal ? CGPoint(x: from.x + side * 1.5, y: outer + side) : CGPoint(x: outer + side, y: from.y + side * 1.5)
                let p2 = horizontal ? CGPoint(x: to.x, y: outer + side) : CGPoint(x: outer + side, y: to.y)
                paths.append([from, p1, p2, to])
                // On the curve itself (cubic Bézier at t = ½), not between the control points.
                labels.append(CGPoint(x: (from.x + 3 * p1.x + 3 * p2.x + to.x) / 8,
                                      y: (from.y + 3 * p1.y + 3 * p2.y + to.y) / 8))
                size.width = max(size.width, p1.x + margin, p2.x + margin)
                size.height = max(size.height, p1.y + margin, p2.y + margin)
            } else {
                paths.append([start, end])
                labels.append(CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
            }
        }
        return Layout(size: size, nodes: rects, edges: paths, edgeLabels: labels)
    }

    /// Where the line from the box centre toward `target` leaves the box.
    static func borderPoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - c.x, dy = target.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let sx = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let sy = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: c.x + dx * s, y: c.y + dy * s)
    }
}

// MARK: - Sequence diagram

public struct SequenceDiagram: Equatable, Sendable {
    public struct Participant: Equatable, Sendable {
        public var id: String
        public var label: String
        public var isActor: Bool
    }
    public enum Event: Equatable, Sendable {
        case message(from: String, to: String, text: String, dashed: Bool, arrow: Arrow)
        case note(over: [String], position: NotePosition, text: String)
    }
    public enum Arrow: String, Sendable { case filled, open, cross, none }
    public enum NotePosition: String, Sendable { case leftOf, rightOf, over }

    public var participants: [Participant] = []
    public var events: [Event] = []
    public var autonumber = false

    mutating func ensure(_ id: String) {
        if !participants.contains(where: { $0.id == id }) {
            participants.append(Participant(id: id, label: id, isActor: false))
        }
    }

    static func parse(lines: [String]) -> SequenceDiagram {
        var d = SequenceDiagram()
        let arrows: [(String, Bool, Arrow)] = [
            ("-->>", true, .filled), ("->>", false, .filled), ("--x", true, .cross), ("-x", false, .cross),
            ("--)", true, .open), ("-)", false, .open), ("-->", true, .none), ("->", false, .none)
        ]
        for line in lines {
            let lower = line.lowercased()
            if lower == "autonumber" { d.autonumber = true; continue }
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let isActor = lower.hasPrefix("actor ")
                let rest = String(line.dropFirst(isActor ? 6 : 12)).trimmingCharacters(in: .whitespaces)
                let parts = rest.components(separatedBy: " as ")
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : id
                if let i = d.participants.firstIndex(where: { $0.id == id }) {
                    d.participants[i].label = label
                    d.participants[i].isActor = isActor
                } else {
                    d.participants.append(Participant(id: id, label: label, isActor: isActor))
                }
                continue
            }
            if lower.hasPrefix("note ") {
                // note right of A: text  /  note over A,B: text
                guard let colon = line.firstIndex(of: ":") else { continue }
                let head = line[..<colon].lowercased()
                let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                let position: NotePosition = head.contains("left of") ? .leftOf : head.contains("right of") ? .rightOf : .over
                let names = String(line[..<colon]).components(separatedBy: position == .over ? "over" : "of").last ?? ""
                let ids = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                ids.forEach { d.ensure($0) }
                d.events.append(.note(over: ids, position: position, text: text))
                continue
            }
            if ["loop", "alt", "else", "opt", "par", "and", "end", "rect", "critical", "break", "activate", "deactivate"].contains(where: { lower.hasPrefix($0) }) {
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon])
            let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            for (token, dashed, arrow) in arrows {
                if let r = head.range(of: token) {
                    let from = head[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                    var to = head[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if to.hasPrefix("+") || to.hasPrefix("-") { to.removeFirst() }
                    guard !from.isEmpty, !to.isEmpty else { break }
                    d.ensure(from); d.ensure(to)
                    d.events.append(.message(from: from, to: to, text: text, dashed: dashed, arrow: arrow))
                    break
                }
            }
        }
        return d
    }
}

// MARK: - Pie chart

public struct PieChart: Equatable, Sendable {
    public struct Slice: Equatable, Sendable {
        public var label: String
        public var value: Double
    }
    public var title: String?
    public var slices: [Slice] = []

    static func parse(header: String, lines: [String]) -> PieChart {
        var chart = PieChart()
        if let r = header.range(of: "title ", options: .caseInsensitive) {
            chart.title = String(header[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        for line in lines {
            if line.lowercased().hasPrefix("title ") { chart.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if line.lowercased().hasPrefix("showdata") { continue }
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2, let value = Double(parts.last!.trimmingCharacters(in: .whitespaces)) else { continue }
            var label = parts.dropLast().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("\""), label.hasSuffix("\""), label.count >= 2 { label = String(label.dropFirst().dropLast()) }
            chart.slices.append(Slice(label: label, value: max(0, value)))
        }
        return chart
    }
}
