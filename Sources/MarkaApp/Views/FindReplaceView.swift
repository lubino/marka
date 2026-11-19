import AppKit
import MarkaCore

/// What the find popover drives (the document window controller).
@MainActor
protocol FindReplaceTarget: AnyObject {
    var findSource: String { get }
    var findCaret: Int { get }
    /// Highlight every match; `current` is selected, scrolled into view and flashed.
    func showFindMatches(_ matches: [NSRange], current: NSRange?)
    func replaceFindMatch(_ range: NSRange, with replacement: String)
    func replaceAllFindMatches(with text: String, count: Int)
    func endFind()
}

/// Search & replace popover (toolbar search button, ⌘F, ⌥⌘F).
final class FindReplaceViewController: NSViewController, NSSearchFieldDelegate, NSTextFieldDelegate, NSPopoverDelegate {
    weak var target: FindReplaceTarget?

    let findField = NSSearchField()
    /// Same capsule as the find field (search field without the magnifier) so both rows match.
    let replaceField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    /// ⌃ | ⌄ — previous / next match.
    private let stepControl = NSSegmentedControl()
    /// Replace | All — same size and style as the step control, so the right column lines up.
    private let replaceControl = NSSegmentedControl()
    static let fieldWidth: CGFloat = 240
    static let controlWidth: CGFloat = 132
    private let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeWords = NSButton(checkboxWithTitle: "Whole Words", target: nil, action: nil)

    private(set) var matches: [NSRange] = []
    private(set) var currentIndex: Int?

    var options: FindEngine.Options {
        FindEngine.Options(caseSensitive: matchCase.state == .on, wholeWord: wholeWords.state == .on)
    }

    override func loadView() {
        for field in [findField, replaceField] {
            field.delegate = self
            field.controlSize = .regular
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }
        findField.placeholderString = "Find"
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findChanged)
        replaceField.placeholderString = "Replace"
        (replaceField.cell as? NSSearchFieldCell)?.searchButtonCell = nil   // no magnifier on Replace
        replaceField.sendsWholeSearchString = true

        func configure(_ control: NSSegmentedControl, _ segments: [(image: String?, label: String?, tip: String)]) {
            control.segmentCount = segments.count
            control.trackingMode = .momentary
            control.segmentStyle = .rounded
            control.controlSize = .regular
            for (index, segment) in segments.enumerated() {
                if let image = segment.image {
                    control.setImage(NSImage(systemSymbolName: image, accessibilityDescription: segment.tip), forSegment: index)
                }
                if let label = segment.label { control.setLabel(label, forSegment: index) }
                control.setToolTip(segment.tip, forSegment: index)
                control.setWidth((Self.controlWidth - 4) / CGFloat(segments.count), forSegment: index)
            }
            control.target = self
            control.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        }
        configure(stepControl, [
            ("chevron.up", nil, "Previous match (⇧⌘G)"),
            ("chevron.down", nil, "Next match (⌘G)")
        ])
        stepControl.action = #selector(stepTapped(_:))
        configure(replaceControl, [
            (nil, "Replace", "Replace this match and find the next"),
            (nil, "All", "Replace every match (one undo step)")
        ])
        replaceControl.action = #selector(replaceTapped(_:))

        for box in [matchCase, wholeWords] {
            box.target = self
            box.action = #selector(findChanged)
            box.controlSize = .regular
        }
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.alignment = .right
        let options = NSStackView(views: [matchCase, wholeWords])
        options.spacing = 16

        // Two columns: fields (same width, same left edge) and controls (same width, same right
        // edge); the bottom row holds the options and the match count.
        let grid = NSGridView(views: [
            [findField, stepControl],
            [replaceField, replaceControl],
            [options, countLabel]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .none
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .center }
        grid.column(at: 1).xPlacement = .trailing
        grid.row(at: 2).topPadding = 2
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
        ])
        view = root
        refreshButtons()
    }

    @objc private func stepTapped(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? findPrevious() : findNext()
    }

    @objc private func replaceTapped(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? replaceCurrent() : replaceAll()
    }

    func focusFind() {
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    func focusReplace() {
        view.window?.makeFirstResponder(replaceField)
    }

    /// Re-run the search (query, options or document changed).
    @objc func findChanged() {
        search(keepCurrent: false)
    }

    func search(keepCurrent: Bool) {
        guard let target else { return }
        let query = findField.stringValue
        matches = FindEngine.matches(of: query, in: target.findSource, options: options)
        if matches.isEmpty {
            currentIndex = nil
        } else if keepCurrent, let index = currentIndex, index < matches.count {
            currentIndex = index
        } else {
            currentIndex = FindEngine.nextIndex(in: matches, after: target.findCaret)
        }
        show()
    }

    @objc func findNext() { step(backwards: false) }
    @objc func findPrevious() { step(backwards: true) }

    private func step(backwards: Bool) {
        guard let target else { return }
        if matches.isEmpty { search(keepCurrent: false) }
        guard !matches.isEmpty else { return }
        if let index = currentIndex {
            currentIndex = backwards ? (index - 1 + matches.count) % matches.count : (index + 1) % matches.count
        } else {
            currentIndex = FindEngine.nextIndex(in: matches, after: target.findCaret, backwards: backwards)
        }
        show()
    }

    @objc func replaceCurrent() {
        guard let target, let index = currentIndex, index < matches.count else {
            findNext()
            return
        }
        let range = matches[index]
        target.replaceFindMatch(range, with: replaceField.stringValue)
        // Continue after the replaced text.
        let resume = range.location + (replaceField.stringValue as NSString).length
        matches = FindEngine.matches(of: findField.stringValue, in: target.findSource, options: options)
        currentIndex = FindEngine.nextIndex(in: matches, after: resume)
        show()
    }

    @objc func replaceAll() {
        guard let target, !findField.stringValue.isEmpty else { return }
        let result = FindEngine.replaceAll(findField.stringValue, with: replaceField.stringValue, in: target.findSource, options: options)
        guard result.count > 0 else { return }
        target.replaceAllFindMatches(with: result.text, count: result.count)
        matches = FindEngine.matches(of: findField.stringValue, in: target.findSource, options: options)
        currentIndex = nil
        show()
        countLabel.stringValue = "\(result.count) replaced"
    }

    private func show() {
        let current = currentIndex.flatMap { $0 < matches.count ? matches[$0] : nil }
        target?.showFindMatches(matches, current: current)
        if findField.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else if matches.isEmpty {
            countLabel.stringValue = "Not found"
        } else {
            countLabel.stringValue = "\((currentIndex ?? 0) + 1) of \(matches.count)"
        }
        refreshButtons()
    }

    private func refreshButtons() {
        let any = !matches.isEmpty
        stepControl.isEnabled = any
        replaceControl.isEnabled = any
    }

    // Return = next, ⇧Return = previous in the find field; Return in replace = Replace.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === replaceField {
                replaceCurrent()
            } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                findPrevious()
            } else {
                findNext()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            view.window?.performClose(nil)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === findField { findChanged() }
    }

    func popoverDidClose(_ notification: Notification) {
        target?.endFind()
    }

    // MARK: - Testing

    var testCountText: String { countLabel.stringValue }

    /// Fields share their left edge and size; the two segmented controls share their right edge
    /// and size; each control is vertically centred on its field.
    var testLayoutIsAligned: Bool {
        _ = view
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        func f(_ v: NSView) -> CGRect { v.convert(v.bounds, to: view) }
        let find = f(findField), replace = f(replaceField), step = f(stepControl), rep = f(replaceControl)
        return abs(find.minX - replace.minX) < 0.5 && abs(find.width - replace.width) < 0.5
            && abs(find.height - replace.height) < 0.5
            && abs(step.maxX - rep.maxX) < 0.5 && abs(step.width - rep.width) < 0.5
            && abs(step.midY - find.midY) < 1 && abs(rep.midY - replace.midY) < 1
    }
    func testSetOptions(caseSensitive: Bool, wholeWord: Bool) {
        _ = view
        matchCase.state = caseSensitive ? .on : .off
        wholeWords.state = wholeWord ? .on : .off
    }
}
