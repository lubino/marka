import Foundation

/// Insert menu galleries: ready-made blocks for each kind (code, math, Mermaid).
public enum InsertKind: String, CaseIterable, Sendable {
    case codeBlock, equation, matrix, flowchart, leftToRight, sequence, pie

    public var title: String {
        switch self {
        case .codeBlock: return "Code Block"
        case .equation: return "Equation"
        case .matrix: return "Matrix"
        case .flowchart: return "Flowchart"
        case .leftToRight: return "Left-to-right flow"
        case .sequence: return "Sequence Diagram"
        case .pie: return "Pie chart"
        }
    }

    /// How a gallery tile previews its template.
    public enum Preview: Sendable { case code, math, mermaid }

    public var preview: Preview {
        switch self {
        case .codeBlock: return .code
        case .equation, .matrix: return .math
        case .flowchart, .leftToRight, .sequence, .pie: return .mermaid
        }
    }

    public var templates: [InsertTemplate] {
        switch self {
        case .codeBlock:
            return [
                InsertTemplate(title: "Text", language: "", body: "", sample: "Plain text,\nno highlighting"),
                InsertTemplate(title: "Bash", language: "bash", body: "", sample: "#!/bin/bash\necho \"Hello\"\nls -la ~/Notes"),
                InsertTemplate(title: "Python", language: "python", body: "", sample: "def hi(name):\n    print(name)\n\nhi(\"Ada\")"),
                InsertTemplate(title: "Swift", language: "swift", body: "", sample: "struct Note {\n  let title: String\n}\nlet n = Note(\n  title: \"Hi\")"),
                InsertTemplate(title: "JSON", language: "json", body: "", sample: "{\n  \"name\": \"Marka\",\n  \"native\": true\n}"),
                InsertTemplate(title: "JavaScript", language: "javascript", body: "", sample: "const add =\n  (a, b) => a + b;\nadd(2, 3); // 5")
            ]
        case .equation:
            return [
                .math("Quadratic formula", "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"),
                .math("Sum", "\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}"),
                .math("Integral", "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}"),
                .math("Limit", "\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1"),
                .math("Euler's identity", "e^{i\\pi} + 1 = 0"),
                .math("Pythagoras", "a^2 + b^2 = c^2")
            ]
        case .matrix:
            return [
                .math("2 × 2", "A = \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
                .math("3 × 3 brackets", "\\begin{bmatrix} 1 & 0 & 0 \\\\ 0 & 1 & 0 \\\\ 0 & 0 & 1 \\end{bmatrix}"),
                .math("Determinant", "\\det \\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix} = ad - bc"),
                .math("Vector", "\\vec{v} = \\begin{pmatrix} x \\\\ y \\\\ z \\end{pmatrix}"),
                .math("Cases", "|x| = \\begin{cases} x & \\text{if } x \\ge 0 \\\\ -x & \\text{otherwise} \\end{cases}"),
                .math("Product", "\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix} \\begin{pmatrix} x \\\\ y \\end{pmatrix}")
            ]
        case .flowchart:
            return [
                .mermaid("Decision", "flowchart TD\n    A[Start] --> B{Ready?}\n    B -->|Yes| C[Publish]\n    B -->|No| D[Edit]\n    D --> B"),
                .mermaid("Steps", "flowchart TD\n    A[Idea] --> B[Draft]\n    B --> C[Review]\n    C --> D[Done]"),
                .mermaid("Branches", "flowchart TD\n    A((Start)) --> B[Load]\n    B --> C[Parse]\n    B --> D[Render]\n    C --> E([Finish])\n    D --> E")
            ]
        case .leftToRight:
            return [
                .mermaid("Pipeline", "flowchart LR\n    A[Write] --> B[Commit] --> C[Push] --> D[Deploy]"),
                .mermaid("Shapes", "flowchart LR\n    A[Box] --> B(Rounded)\n    B --> C{Choice}\n    C --> D[(Database)]"),
                .mermaid("Feedback", "flowchart LR\n    A[Plan] --> B[Build]\n    B --> C[Measure]\n    C -.->|learn| A")
            ]
        case .sequence:
            return [
                .mermaid("Request", "sequenceDiagram\n    participant App\n    participant Server\n    App->>Server: GET /notes\n    Server-->>App: 200 OK"),
                .mermaid("Login", "sequenceDiagram\n    actor User\n    User->>App: Sign in\n    App->>Auth: Check password\n    Auth-->>App: Token\n    App-->>User: Welcome"),
                .mermaid("Numbered", "sequenceDiagram\n    autonumber\n    Alice->>Bob: Hello Bob\n    Bob-->>Alice: Hi Alice\n    Note over Alice,Bob: A short chat")
            ]
        case .pie:
            return [
                .mermaid("Time", "pie title Time spent\n    \"Writing\" : 50\n    \"Editing\" : 30\n    \"Formatting\" : 20"),
                .mermaid("Budget", "pie title Budget\n    \"Rent\" : 45\n    \"Food\" : 25\n    \"Travel\" : 15\n    \"Other\" : 15"),
                .mermaid("Two parts", "pie\n    \"Done\" : 70\n    \"To do\" : 30")
            ]
        }
    }
}

/// One gallery tile: what it inserts (`language` fence + `body`) and, for code, a preview sample.
public struct InsertTemplate: Equatable, Sendable {
    public var title: String
    /// Fence info string: "", "bash", …, "math", "mermaid".
    public var language: String
    public var body: String
    /// Preview text for code tiles (code blocks are inserted empty).
    public var sample: String

    public init(title: String, language: String, body: String, sample: String = "") {
        self.title = title
        self.language = language
        self.body = body
        self.sample = sample
    }

    static func math(_ title: String, _ latex: String) -> InsertTemplate {
        InsertTemplate(title: title, language: "math", body: latex)
    }

    static func mermaid(_ title: String, _ source: String) -> InsertTemplate {
        InsertTemplate(title: title, language: "mermaid", body: source)
    }
}

extension MarkdownEditing {
    /// Inserts `template` as a block on its own lines at the caret (or replacing the selection).
    /// Empty bodies (code) leave the caret inside the fence; filled ones put it after the block.
    public static func insertTemplate(source: String, selected: NSRange, template: InsertTemplate) -> EditResult {
        if template.body.isEmpty {
            return insertCodeBlock(source: source, selected: NSRange(location: selected.location, length: 0), language: template.language)
        }
        let ns = source as NSString
        let replace = NSRange(location: min(max(0, selected.location), ns.length), length: min(selected.length, ns.length - min(max(0, selected.location), ns.length)))
        let at = replace.location
        let end = NSMaxRange(replace)
        let needLeading = at > 0 && ns.character(at: at - 1) != 10
        let needTrailing = end < ns.length && ns.character(at: end) != 10
        let block = (needLeading ? "\n" : "") + "```\(template.language)\n" + template.body + "\n```" + "\n"
        _ = needTrailing   // the block always ends with a newline, so following text starts a new line
        let new = ns.replacingCharacters(in: replace, with: block)
        let caret = at + (block as NSString).length
        return EditResult(text: new, selected: NSRange(location: min(caret, (new as NSString).length), length: 0))
    }
}
