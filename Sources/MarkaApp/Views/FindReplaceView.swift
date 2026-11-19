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
    let replaceField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeWords = NSButton(checkboxWithTitle: "Whole Words", target: nil, action: nil)

    private(set) var matches: [NSRange] = []
    private(set) var currentIndex: Int?

    var options: FindEngine.Options {
        FindEngine.Options(caseSensitive: matchCase.state == .on, wholeWord: wholeWords.state == .on)
    }

    override func loadView() {
        findField.placeholderString = "Find"
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findChanged)
        findField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.alignment = .right
        countLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        for (button, symbol, tip, action) in [
            (previousButton, "chevron.up", "Previous (⇧⌘G)", #selector(findPrevious)),
            (nextButton, "chevron.down", "Next (⌘G)", #selector(findNext))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        let arrows = NSStackView(views: [previousButton, nextButton])
        arrows.spacing = 2

        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        replaceField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        replaceButton.target = self
        replaceButton.action = #selector(replaceCurrent)
        replaceButton.toolTip = "Replace this match and find the next"
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)
        replaceAllButton.toolTip = "Replace every match (one undo step)"
        [replaceButton, replaceAllButton].forEach { $0.bezelStyle = .push; $0.controlSize = .small }

        for box in [matchCase, wholeWords] {
            box.target = self
            box.action = #selector(findChanged)
            box.controlSize = .small
        }

        let findRow = NSStackView(views: [findField, countLabel, arrows])
        findRow.spacing = 8
        let replaceRow = NSStackView(views: [replaceField, replaceButton, replaceAllButton])
        replaceRow.spacing = 8
        let optionRow = NSStackView(views: [matchCase, wholeWords])
        optionRow.spacing = 14
        let stack = NSStackView(views: [findRow, replaceRow, optionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        view = stack
        refreshButtons()
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
        previousButton.isEnabled = any
        nextButton.isEnabled = any
        replaceButton.isEnabled = any
        replaceAllButton.isEnabled = any
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
    func testSetOptions(caseSensitive: Bool, wholeWord: Bool) {
        _ = view
        matchCase.state = caseSensitive ? .on : .off
        wholeWords.state = wholeWord ? .on : .off
    }
}
