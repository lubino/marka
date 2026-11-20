import AppKit
import MarkaCore

/// Everything the document info popover shows (replaces the old bottom status bar).
struct DocumentInfo {
    var page: Int            // 1-based
    var pageCount: Int
    var stats: DocumentStats
    var selectionWords: Int
    var selectionCharacters: Int
    var fileURL: URL?
    var codec: FileCodec
    var isEdited: Bool
    var fileSize: Int64?
    var modified: Date?
    var pageWords: Int = 0       // words on the visible page
    var caretPage: Int = 1       // 1-based page holding the caret
    var wordGoal: Int = 0        // 0 = off
}

/// Toolbar control: shows only the current page number; a click opens `DocumentInfoViewController`.
final class PageNumberButton: NSButton {
    convenience init(target: AnyObject?, action: Selector) {
        self.init(title: "1", target: target, action: action)
        // Bordered like Bold / Italic / Strike, so it groups with the Content button next to it.
        bezelStyle = .texturedRounded
        isBordered = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        refusesFirstResponder = true
        setContentHuggingPriority(.required, for: .horizontal)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    }

    func show(page: Int, of count: Int) {
        title = "\(page)"
        toolTip = "Page \(page) of \(count) — click for document info"
        setAccessibilityLabel("Page \(page) of \(count)")
    }
}

final class DocumentInfoViewController: NSViewController, NSTextFieldDelegate {
    /// Fixed popover width; every row (including the wrapping path) lives inside the side insets.
    static let contentWidth: CGFloat = 320
    static let sideInset: CGFloat = 16
    var onGoToPage: ((Int) -> Void)?
    /// The overview icon: headings and files for quick navigation.
    var onOverview: (() -> Void)?

    private let pageField = NSTextField()
    private let pageStepper = NSStepper()
    private let pageCountLabel = NSTextField(labelWithString: "")
    private let pageDetailLabel = NSTextField(labelWithString: "")
    private let goalBar = NSProgressIndicator()
    private let goalLabel = NSTextField(labelWithString: "")
    private var goalRow: NSView?
    private let grid = NSGridView()
    private var values: [String: NSTextField] = [:]
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private(set) var overviewButton: LinkCardButton?
    private let copyButton = NSButton(title: "Copy Path", target: nil, action: nil)
    private var info: DocumentInfo?
    private var selectionRow: NSGridRow?
    private var tasksRow: NSGridRow?

    static let rowTitles = [
        "Words", "Characters", "Without spaces", "Selection", "Reading time",
        "Paragraphs", "Lines", "Headings", "Links", "Images", "Tables", "Code blocks", "Tasks",
        "Encoding", "Line endings", "File size", "Modified", "Status"
    ]

    override func loadView() {
        let root = NSView()

        let pageTitle = NSTextField(labelWithString: "Page")
        pageTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        pageField.formatter = formatter
        pageField.alignment = .center
        pageField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        pageField.delegate = self
        pageField.target = self
        pageField.action = #selector(pageFieldCommitted)
        pageField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        pageStepper.minValue = 1
        pageStepper.increment = 1
        pageStepper.valueWraps = false
        pageStepper.target = self
        pageStepper.action = #selector(stepperChanged)
        pageCountLabel.textColor = .secondaryLabelColor
        // Same hover button as the link card's icons (rounded fill, pointing hand), popover-sized.
        let overview = LinkCardButton(
            image: NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Go to a heading or file")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? NSImage(),
            tip: "Go to a heading or file…"
        )
        overview.target = self
        overview.action = #selector(overviewTapped)
        NSLayoutConstraint.activate([
            overview.widthAnchor.constraint(equalToConstant: 28),
            overview.heightAnchor.constraint(equalToConstant: 28)
        ])
        overviewButton = overview
        let pageRow = NSStackView(views: [pageTitle, pageField, pageStepper, pageCountLabel, NSView(), overview])
        pageRow.spacing = 6
        pageRow.alignment = .centerY
        pageRow.widthAnchor.constraint(equalToConstant: Self.contentWidth - Self.sideInset * 2).isActive = true
        pageDetailLabel.textColor = .secondaryLabelColor
        pageDetailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        goalBar.style = .bar
        goalBar.isIndeterminate = false
        goalBar.minValue = 0
        goalBar.maxValue = 1
        goalBar.controlSize = .small
        goalBar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        goalLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        goalLabel.textColor = .secondaryLabelColor
        let goalTitle = NSTextField(labelWithString: "Goal")
        goalTitle.textColor = .secondaryLabelColor
        let goal = NSStackView(views: [goalTitle, goalBar, goalLabel])
        goal.spacing = 8
        goal.alignment = .centerY
        goalRow = goal

        grid.rowSpacing = 4
        grid.columnSpacing = 12
        for title in Self.rowTitles {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            value.isSelectable = true
            values[title] = value
            let row = grid.addRow(with: [label, value])
            if title == "Selection" { selectionRow = row }
            if title == "Tasks" { tasksRow = row }
            if title == "Paragraphs" || title == "Encoding" {
                row.topPadding = 8
            }
        }
        grid.column(at: 0).xPlacement = .trailing

        // Paths have few spaces: wrap at any character so long folders never overflow the popover.
        pathLabel.lineBreakMode = .byCharWrapping
        pathLabel.maximumNumberOfLines = 0
        pathLabel.preferredMaxLayoutWidth = Self.contentWidth - Self.sideInset * 2
        pathLabel.isSelectable = true
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        revealButton.target = self
        revealButton.action = #selector(revealInFinder)
        copyButton.target = self
        copyButton.action = #selector(copyPath)
        [revealButton, copyButton].forEach {
            $0.controlSize = .small
            $0.bezelStyle = .push
        }
        let fileButtons = NSStackView(views: [revealButton, copyButton])
        fileButtons.spacing = 8

        let stack = NSStackView(views: [
            pageRow, pageDetailLabel, goal, separator(), grid, separator(), pathLabel, fileButtons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: Self.sideInset, bottom: 14, right: Self.sideInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            // The path wraps inside the insets instead of pushing the popover wider.
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.sideInset * 2)
        ])
        view = root
        if let info { apply(info) }
    }

    /// Size the popover from the laid-out content (the path may take several lines).
    private func updatePreferredSize() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if abs(size.height - preferredContentSize.height) > 0.5 || abs(size.width - preferredContentSize.width) > 0.5 {
            preferredContentSize = size
        }
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func update(_ info: DocumentInfo) {
        self.info = info
        if isViewLoaded { apply(info) }
    }

    func focusPageField() {
        view.window?.makeFirstResponder(pageField)
        pageField.currentEditor()?.selectAll(nil)
    }

    private var isEditingPage: Bool { pageField.currentEditor() != nil }

    private func apply(_ info: DocumentInfo) {
        let count = max(1, info.pageCount)
        (pageField.formatter as? NumberFormatter)?.maximum = NSNumber(value: count)
        pageStepper.maxValue = Double(count)
        pageStepper.integerValue = info.page
        if !isEditingPage {
            pageField.integerValue = info.page
        }
        pageCountLabel.stringValue = "of \(count)"
        var detail = "This page: \(NumberFormatter.localizedString(from: NSNumber(value: info.pageWords), number: .decimal)) words"
        if info.caretPage != info.page {
            detail += " · Cursor on page \(info.caretPage)"
        }
        pageDetailLabel.stringValue = detail

        goalRow?.isHidden = info.wordGoal <= 0
        if info.wordGoal > 0 {
            let progress = Double(info.stats.words) / Double(info.wordGoal)
            goalBar.doubleValue = min(1, progress)
            goalLabel.stringValue = "\(info.stats.words) / \(info.wordGoal) words (\(Int((progress * 100).rounded())) %)"
        }

        let s = info.stats
        func n(_ value: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) }
        set("Words", n(s.words))
        set("Characters", n(s.characters))
        set("Without spaces", n(s.charactersWithoutSpaces))
        let hasSelection = info.selectionCharacters > 0
        selectionRow?.isHidden = !hasSelection
        set("Selection", "\(n(info.selectionWords)) words · \(n(info.selectionCharacters)) chars")
        set("Reading time", s.readingMinutes == 0 ? "—" : "≈ \(s.readingMinutes) min")
        set("Paragraphs", n(s.paragraphs))
        set("Lines", n(s.lines))
        set("Headings", n(s.headings))
        set("Links", n(s.links))
        set("Images", n(s.images))
        set("Tables", n(s.tables))
        set("Code blocks", n(s.codeBlocks))
        tasksRow?.isHidden = s.tasks == 0
        set("Tasks", "\(s.completedTasks) of \(s.tasks) done")
        set("Encoding", info.codec.hasUTF8BOM ? "UTF-8 with BOM" : "UTF-8")
        set("Line endings", Self.lineEndingName(info.codec.lineEnding))
        set("File size", info.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
        set("Modified", info.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "—")
        set("Status", info.fileURL == nil ? "Not saved yet" : (info.isEdited ? "Edited" : "Saved"))

        pathLabel.stringValue = info.fileURL?.path ?? "Untitled — not saved yet"
        pathLabel.toolTip = info.fileURL?.path
        revealButton.isEnabled = info.fileURL != nil
        copyButton.isEnabled = info.fileURL != nil
        updatePreferredSize()
    }

    private func set(_ key: String, _ value: String) {
        values[key]?.stringValue = value
    }

    static func lineEndingName(_ ending: FileCodec.LineEnding) -> String {
        switch ending {
        case .lf: return "LF (macOS / Unix)"
        case .crlf: return "CRLF (Windows)"
        case .cr: return "CR (classic Mac)"
        }
    }

    // MARK: - Actions

    @objc private func pageFieldCommitted() {
        goTo(pageField.integerValue)
    }

    @objc private func stepperChanged() {
        pageField.integerValue = pageStepper.integerValue
        goTo(pageStepper.integerValue)
    }

    private func goTo(_ page: Int) {
        let count = max(1, info?.pageCount ?? 1)
        let clamped = min(max(1, page), count)
        pageField.integerValue = clamped
        pageStepper.integerValue = clamped
        onGoToPage?(clamped)
    }

    @objc private func overviewTapped() { onOverview?() }

    @objc private func revealInFinder() {
        guard let url = info?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let path = info?.fileURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Testing

    func testValue(_ key: String) -> String? {
        _ = view
        return values[key]?.stringValue
    }

    var testPath: String { _ = view; return pathLabel.stringValue }
    /// Path label sits inside the side insets of the laid-out popover content.
    var testPathHasSideInsets: Bool {
        updatePreferredSize()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        // Compare the text's alignment rect (labels draw 2 pt inside their frame).
        let alignment = pathLabel.alignmentRect(forFrame: pathLabel.frame)
        let frame = pathLabel.superview?.convert(alignment, to: view) ?? alignment
        guard view.bounds.width >= Self.contentWidth - 0.5, !pathLabel.hasAmbiguousLayout else { return false }
        return frame.minX >= Self.sideInset - 0.5 && frame.maxX <= view.bounds.width - Self.sideInset + 0.5
    }
    var testPathWraps: Bool { _ = view; return pathLabel.maximumNumberOfLines == 0 && pathLabel.lineBreakMode == .byCharWrapping }
    var testPageDetail: String { _ = view; return pageDetailLabel.stringValue }
    var testGoalVisible: Bool { _ = view; return goalRow?.isHidden == false }
    var testGoalProgress: Double { goalBar.doubleValue }

    func testEnterPage(_ page: Int) {
        _ = view
        pageField.integerValue = page
        pageFieldCommitted()
    }
}
