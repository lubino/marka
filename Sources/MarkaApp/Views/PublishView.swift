import AppKit
import MarkaCore

/// Publish popover (styled after a native "Push Changes" sheet): header with a green tile, then
/// tabs — Message, Files, Diff, History — so it stays small; Cancel and a green Publish button.
/// Publish commits the files and pushes when the repository has an `origin` remote.
final class PublishViewController: NSViewController, NSTextViewDelegate {
    var onPublish: ((String) -> Void)?
    var onCancel: (() -> Void)?
    let snapshot: PublishSnapshot
    private let tabs = NSSegmentedControl()
    private let messageView = NSTextView()
    private let diffView = NSTextView()
    private let diffFilePopup = NSPopUpButton()
    private let publishButton = NSButton(title: "Publish", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var pages: [NSView] = []
    private var isBusy = false
    static let width: CGFloat = 460
    static let pageHeight: CGFloat = 216
    static let inset: CGFloat = 20
    static let green = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.25, green: 0.73, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.53, blue: 0.20, alpha: 1)
    }

    init(snapshot: PublishSnapshot) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tabs.segmentCount = 4
        tabs.setLabel("Message", forSegment: 0)
        tabs.setLabel("Files (\(snapshot.changes.count))", forSegment: 1)
        tabs.setLabel("Diff", forSegment: 2)
        tabs.setLabel("History", forSegment: 3)
        tabs.trackingMode = .selectOne
        tabs.selectedSegment = 0
        tabs.segmentDistribution = .fillEqually
        tabs.target = self
        tabs.action = #selector(tabChanged)

        pages = [makeMessagePage(), makeFilesPage(), makeDiffPage(), makeHistoryPage()]
        let pageHost = NSView()
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            pageHost.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: pageHost.topAnchor),
                page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor)
            ])
        }

        statusLabel.stringValue = statusDescription
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.controlSize = .large
        publishButton.target = self
        publishButton.action = #selector(publish)
        publishButton.keyEquivalent = "\r"
        publishButton.keyEquivalentModifierMask = [.command]
        publishButton.controlSize = .large
        publishButton.bezelColor = Self.green
        publishButton.image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: nil)
        publishButton.imagePosition = .imageLeading
        publishButton.toolTip = "Publish (⌘↩)"
        let footer = NSStackView(views: [statusLabel, NSView(), spinner, cancelButton, publishButton])
        footer.alignment = .centerY
        footer.spacing = 10
        NSLayoutConstraint.activate([
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            publishButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])

        let stack = NSStackView(views: [makeHeader(), tabs, pageHost, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        // A popover sizes a root NSStackView without its edgeInsets; explicit insets on a plain
        // container keep the controls off the popover's edge.
        let container = NSView()
        container.addSubview(stack)
        let inset = Self.inset
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            tabs.widthAnchor.constraint(equalToConstant: Self.width),
            pageHost.widthAnchor.constraint(equalToConstant: Self.width),
            pageHost.heightAnchor.constraint(equalToConstant: Self.pageHeight),
            footer.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        view = container
        preferredContentSize = container.fittingSize
        showPage(0)
        updatePublishEnabled()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(messageView)
        messageView.selectAll(nil)
    }

    // MARK: Header

    private func makeHeader() -> NSView {
        let tile = TintedView(color: Self.green.withAlphaComponent(0.14), cornerRadius: 12)
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: "Publish") ?? NSImage())
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        arrow.contentTintColor = Self.green
        arrow.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(arrow)
        let title = NSTextField(labelWithString: "Publish Changes")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        let header = NSStackView(views: [tile, texts])
        header.alignment = .centerY
        header.spacing = 14
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 48),
            tile.heightAnchor.constraint(equalToConstant: 48),
            arrow.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            header.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        return header
    }

    /// "Commit to main and push to origin/main." / "Commit to main (no remote “origin”)."
    private var subtitleText: String {
        let branch = snapshot.branch ?? "HEAD"
        if snapshot.hasOrigin { return "Commit to \(branch) and push to origin/\(branch)." }
        return "Commit to \(branch) in \(snapshot.repositoryName) — no remote “origin”, nothing is pushed."
    }

    // MARK: Pages

    private func makeMessagePage() -> NSView {
        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.allowsUndo = true
        messageView.string = GitPublisher.suggestedMessage(for: snapshot.changes)
        messageView.delegate = self
        messageView.textContainerInset = NSSize(width: 6, height: 8)
        let scroll = Self.scroll(messageView)
        let hint = NSTextField(labelWithString: "Commit message — the first line is the summary shown in the history.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// "Files to publish  2" and one row per file: icon, name, "Added  folder", +N −M.
    private func makeFilesPage() -> NSView {
        guard !snapshot.changes.isEmpty else {
            return Self.placeholder("No changes — the open documents match the last commit.")
        }
        let caption = NSTextField(labelWithString: "Files to publish")
        caption.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let count = NSTextField(labelWithString: "\(snapshot.changes.count)")
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        count.textColor = .secondaryLabelColor
        let badge = TintedView(color: .quaternaryLabelColor, cornerRadius: 9)
        count.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(count)
        NSLayoutConstraint.activate([
            count.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            count.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualTo: count.widthAnchor, constant: 12),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let captionRow = NSStackView(views: [caption, badge, NSView()])
        captionRow.alignment = .centerY
        captionRow.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        for (index, change) in snapshot.changes.enumerated() {
            if index > 0 { rows.addArrangedSubview(Self.separator()) }
            let row = fileRow(change, index: index)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let list = NSScrollView()
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        let flipped = FlippedView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(rows)
        flipped.translatesAutoresizingMaskIntoConstraints = false
        list.documentView = flipped
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: flipped.topAnchor),
            rows.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            flipped.widthAnchor.constraint(equalTo: list.contentView.widthAnchor)
        ])
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
        box.contentViewMargins = .zero
        box.contentView = list
        let stack = NSStackView(views: [captionRow, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func fileRow(_ change: GitChange, index: Int) -> NSView {
        let added = change.label == "Added" || change.label == "Untracked"
        let symbol = added ? "plus.circle" : change.label == "Deleted" ? "minus.circle" : "pencil.circle"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: change.label) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.contentTintColor = Self.color(for: change)
        let path = change.path as NSString
        let name = NSTextField(labelWithString: path.lastPathComponent)
        name.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        name.lineBreakMode = .byTruncatingMiddle
        let folder = path.deletingLastPathComponent
        let detail = NSTextField(labelWithString: folder.isEmpty ? change.label : "\(change.label)  \(folder)")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let counts = GitPublisher.lineCounts(snapshot.diffs[change.path] ?? "")
        let numbers = NSMutableAttributedString()
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        if counts.added > 0 {
            numbers.append(NSAttributedString(string: "+\(counts.added)", attributes: [.font: numberFont, .foregroundColor: Self.green]))
        }
        if counts.removed > 0 {
            if numbers.length > 0 { numbers.append(NSAttributedString(string: " ")) }
            numbers.append(NSAttributedString(string: "−\(counts.removed)", attributes: [.font: numberFont, .foregroundColor: NSColor.systemRed]))
        }
        let countLabel = NSTextField(labelWithAttributedString: numbers)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = ClickableRow(views: [icon, texts, NSView(), countLabel])
        // Icon and counts centred on the two-line name / folder block.
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 14)
        row.toolTip = "\(change.path) — click to see the diff"
        row.onClick = { [weak self] in self?.showDiff(index: index) }
        return row
    }

    private func makeDiffPage() -> NSView {
        diffFilePopup.addItems(withTitles: snapshot.changes.map(\.path))
        diffFilePopup.target = self
        diffFilePopup.action = #selector(diffFileChanged)
        diffFilePopup.isEnabled = snapshot.changes.count > 1
        diffView.isEditable = false
        diffView.isRichText = true
        diffView.textContainerInset = NSSize(width: 4, height: 4)
        let diff = Self.scroll(diffView)
        diff.hasHorizontalScroller = true
        diffView.isHorizontallyResizable = true
        diffView.textContainer?.widthTracksTextView = false
        diffView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let stack = NSStackView(views: snapshot.changes.isEmpty ? [diff] : [diffFilePopup, diff])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        diff.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        renderDiff(index: 0)
        return stack
    }

    private func makeHistoryPage() -> NSView {
        guard !snapshot.commits.isEmpty else { return Self.placeholder("No commits yet.") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named   // "now", "yesterday"
        let caption = NSTextField(labelWithString: "Last commits")
        caption.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        var views: [NSView] = [caption]
        for commit in snapshot.commits {
            let subject = NSTextField(labelWithString: commit.subject)
            subject.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
            subject.lineBreakMode = .byTruncatingTail
            subject.toolTip = commit.subject
            let now = Date()
            let when = formatter.localizedString(for: min(commit.date, now), relativeTo: now)
            let detail = NSTextField(labelWithString: "\(commit.author) · \(when) · \(commit.hash.prefix(7))")
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.toolTip = DateFormatter.localizedString(from: commit.date, dateStyle: .medium, timeStyle: .short)
            let row = NSStackView(views: [subject, detail])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            subject.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width).isActive = true
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let page = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor)
        ])
        return page
    }

    private static func scroll(_ text: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private static func placeholder(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let page = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor)
        ])
        return page
    }

    @objc private func tabChanged() { showPage(tabs.selectedSegment) }

    private func showPage(_ index: Int) {
        tabs.selectedSegment = index
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
        if index == 0 { view.window?.makeFirstResponder(messageView) }
    }

    private var statusDescription: String {
        if snapshot.changes.isEmpty { return "Nothing to publish." }
        return snapshot.changes.count == 1 ? "1 file" : "\(snapshot.changes.count) files"
    }

    // MARK: Diff

    /// Files row click: show that file on the Diff tab.
    private func showDiff(index: Int) {
        diffFilePopup.selectItem(at: index)
        renderDiff(index: index)
        showPage(2)
    }

    @objc private func diffFileChanged() { renderDiff(index: diffFilePopup.indexOfSelectedItem) }

    private func renderDiff(index: Int) {
        let diff = snapshot.changes.indices.contains(index) ? snapshot.diffs[snapshot.changes[index].path] ?? "" : ""
        diffView.textStorage?.setAttributedString(Self.styledDiff(snapshot.changes.isEmpty ? "(no changes)" : diff))
        diffView.scrollToBeginningOfDocument(nil)
    }

    private static func color(for change: GitChange) -> NSColor {
        switch change.label {
        case "Added", "Untracked": return green
        case "Deleted": return .systemRed
        default: return .systemOrange
        }
    }

    /// GitHub-like diff colours: additions green, removals red, hunk headers blue, file headers grey.
    static func styledDiff(_ diff: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        let text = diff.isEmpty ? "(no textual changes)" : diff
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            } else if line.hasPrefix("+") {
                attributes[.foregroundColor] = green
                attributes[.backgroundColor] = green.withAlphaComponent(0.10)
            } else if line.hasPrefix("-") {
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.10)
            } else if line.hasPrefix("@@") {
                attributes[.foregroundColor] = NSColor.systemBlue
            }
            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        return result
    }

    // MARK: Actions

    func textDidChange(_ notification: Notification) { updatePublishEnabled() }

    private var message: String {
        messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updatePublishEnabled() {
        publishButton.isEnabled = !isBusy && !snapshot.changes.isEmpty && !message.isEmpty
    }

    /// While git runs: controls disabled, spinner on.
    func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        messageView.isEditable = !busy
        tabs.isEnabled = !busy
        cancelButton.isEnabled = !busy
        updatePublishEnabled()
        statusLabel.stringValue = busy ? (snapshot.hasOrigin ? "Committing and pushing…" : "Committing…") : statusDescription
    }

    @objc private func publish() {
        guard publishButton.isEnabled else { return }
        onPublish?(message)
    }

    @objc private func cancel() { onCancel?() }

    // Testing
    var testPublishEnabled: Bool { publishButton.isEnabled }
    var testMessage: String { messageView.string }
    func testSetMessage(_ text: String) { messageView.string = text; updatePublishEnabled() }
    func testSelectTab(_ index: Int) { showPage(index) }
    func testClickFile(_ index: Int) { showDiff(index: index) }
    var testVisibleTab: Int { pages.firstIndex { !$0.isHidden } ?? -1 }
    var testDiffText: String { diffView.string }
    /// Visible (alignment) rects of the footer buttons in the popover's root view, and its bounds.
    var testButtonFrames: (publish: NSRect, cancel: NSRect, bounds: NSRect) {
        view.layoutSubtreeIfNeeded()
        func visible(_ button: NSButton) -> NSRect {
            button.superview!.convert(button.alignmentRect(forFrame: button.frame), to: view)
        }
        return (visible(publishButton), visible(cancelButton), view.bounds)
    }
}

/// A file row that reports clicks (and shows the pointing hand).
final class ClickableRow: NSStackView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A rounded fill whose (dynamic) colour follows light / dark mode — a layer's CGColor would not.
final class TintedView: NSView {
    private let color: NSColor

    init(color: NSColor, cornerRadius: CGFloat) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// "Publish could not be done" sheet with a "Show more" link that reveals git's log.
@MainActor
enum PublishFailureAlert {
    static func message(for outcome: PublishOutcome) -> (title: String, text: String) {
        let fix = "Fix the problem with an external Git tool (for example Terminal, GitHub Desktop or Tower)."
        switch outcome {
        case .pushFailed:
            return ("Publish could not be completed",
                    "Your changes were committed on this Mac, but pushing them to “origin” failed. \(fix) Then push from that tool.")
        default:
            return ("Publish could not be done", "Git could not commit the changes. \(fix)")
        }
    }

    @discardableResult
    static func present(_ outcome: PublishOutcome, on window: NSWindow?) -> NSAlert {
        let texts = message(for: outcome)
        return present(title: texts.title, text: texts.text, log: outcome.log, on: window)
    }

    @discardableResult
    static func present(title: String, text: String, log: String, on window: NSWindow?) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.accessoryView = LogDisclosureView(log: log, alert: alert)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        return alert
    }
}

/// A "Show more" link; clicking it shows the git log below and grows the alert.
final class LogDisclosureView: NSView {
    private let toggle = NSButton(title: "Show more", target: nil, action: nil)
    private let scroll = NSScrollView()
    private weak var alert: NSAlert?
    private static let width: CGFloat = 420
    private static let logHeight: CGFloat = 200
    var isExpanded: Bool { !scroll.isHidden }

    init(log: String, alert: NSAlert) {
        self.alert = alert
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 20))
        toggle.isBordered = false
        toggle.attributedTitle = NSAttributedString(string: "Show more", attributes: [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        toggle.target = self
        toggle.action = #selector(toggleLog)
        toggle.sizeToFit()
        addSubview(toggle)
        let text = NSTextView()
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = log
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.isHidden = true
        addSubview(scroll)
        layoutParts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func layoutParts() {
        let height = isExpanded ? 24 + Self.logHeight : 20
        setFrameSize(NSSize(width: Self.width, height: height))
        toggle.setFrameOrigin(NSPoint(x: 0, y: 0))
        scroll.frame = NSRect(x: 0, y: 24, width: Self.width, height: Self.logHeight)
    }

    @objc func toggleLog() {
        scroll.isHidden.toggle()
        toggle.attributedTitle = NSAttributedString(string: isExpanded ? "Show less" : "Show more", attributes: [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        toggle.sizeToFit()
        layoutParts()
        alert?.layout()
    }
}
