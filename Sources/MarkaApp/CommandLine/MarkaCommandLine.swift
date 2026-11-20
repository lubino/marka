import AppKit
import MarkaCore

/// `Marka -pdf input.md [output.pdf]`: exports a Markdown file to PDF with exactly the app's
/// layout (same pages, fonts and Settings) — no window, no Dock icon — and prints the document's
/// statistics like the toolbar's Page popover.
@MainActor
public enum MarkaCommandLine {
    static let usage = """
    Usage: Marka -pdf <input.md> [output.pdf]

      -pdf, --pdf     Export <input.md> to PDF (default output: the input's name with .pdf)
                      and print page, word and other counts.
      -h, --help      Show this help.

    Example:
      /Applications/Marka.app/Contents/MacOS/Marka -pdf README.md README.pdf
    """

    /// Runs a command when the arguments ask for one; returns its exit code. nil = start the app.
    public static func run(_ arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
            print(usage)
            return 0
        }
        guard let flag = args.firstIndex(where: { $0 == "-pdf" || $0 == "--pdf" }) else { return nil }
        let rest = Array(args[(flag + 1)...]).filter { !$0.hasPrefix("-") }
        guard let inputPath = rest.first else {
            FileHandle.standardError.write(Data("marka: missing input file\n\n\(usage)\n".utf8))
            return 2
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let input = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
        let output = rest.count > 1
            ? URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
            : input.deletingPathExtension().appendingPathExtension("pdf")
        do {
            let result = try exportPDF(input: input, output: output)
            print(report(result, output: output))
            return 0
        } catch {
            FileHandle.standardError.write(Data("marka: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    struct Result {
        var pages: Int
        var stats: DocumentStats
    }

    /// Lays the document out off-screen and writes the PDF.
    static func exportPDF(input: URL, output: URL) throws -> Result {
        let data = try Data(contentsOf: input)
        let text = FileCodec.decode(data).normalized
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // no Dock icon, no menu bar
        let controller = DocumentWindowController()
        controller.loadForExport(text, directory: input.deletingLastPathComponent())
        // Let queued relayouts (and web images) settle, then lay out once more.
        pump(0.4)
        controller.testCanvas.relayout()
        pump(0.1)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PDFExporter.write(from: controller.testCanvas, to: output)
        let pages = controller.testCanvas.pageCount
        controller.window?.close()
        return Result(pages: pages, stats: DocumentStats.compute(text))
    }

    static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: until) }
    }

    /// The Page popover's counts, as text.
    static func report(_ result: Result, output: URL) -> String {
        let s = result.stats
        let number = NumberFormatter()
        number.numberStyle = .decimal
        func n(_ value: Int) -> String { number.string(from: NSNumber(value: value)) ?? "\(value)" }
        var rows: [(String, String)] = [
            ("Pages", n(result.pages)),
            ("Words", n(s.words)),
            ("Characters", n(s.characters)),
            ("Without spaces", n(s.charactersWithoutSpaces)),
            ("Reading time", s.readingMinutes < 1 ? "under 1 min" : "\(s.readingMinutes) min"),
            ("Paragraphs", n(s.paragraphs)),
            ("Lines", n(s.lines)),
            ("Headings", n(s.headings)),
            ("Links", n(s.links)),
            ("Images", n(s.images)),
            ("Tables", n(s.tables)),
            ("Code blocks", n(s.codeBlocks))
        ]
        if s.tasks > 0 { rows.append(("Tasks", "\(s.completedTasks) of \(s.tasks) done")) }
        let width = rows.map(\.0.count).max() ?? 0
        let lines = rows.map { $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
        return (["Exported \(output.path)", ""] + lines).joined(separator: "\n")
    }
}
