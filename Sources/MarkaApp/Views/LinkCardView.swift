import AppKit
import MarkaCore

@MainActor
protocol LinkCardDelegate: AnyObject {
    func linkCard(_ view: LinkCardView, commitURL url: String)
    func linkCardOpen(_ view: LinkCardView)
    func linkCardCopy(_ view: LinkCardView)
    func linkCardRemove(_ view: LinkCardView)
    func linkCardChooseFile(_ view: LinkCardView)
    /// Link card: the overview of headings and files. Image card: image options.
    func linkCardOverview(_ view: LinkCardView, from button: NSView)
}

public enum Hyperlink {
    public enum Destination: Equatable {
        case markdown(URL)
        case file(URL)
        case remote(URL)
    }

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]

    public static func destination(_ raw: String, relativeTo directory: URL?) -> Destination? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            if scheme == "file" {
                return localDestination(url)
            }
            if ["http", "https", "mailto", "tel", "sms", "ftp"].contains(scheme) {
                return .remote(url)
            }
        }

        // No scheme (https://, mailto:, …) means a path relative to the document, as if it began
        // with "./" — the way GitHub resolves links and images in a repository.

        // Local paths: `<new idea.md>` and `new%20idea.md` both mean the file "new idea.md".
        var path = trimmed
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        // `notes.md#setup` → the file (the anchor is a place inside it); a bare `#setup` is an
        // anchor in this document, not a file.
        if let hash = path.firstIndex(of: "#") {
            guard hash != path.startIndex else { return nil }
            path = String(path[..<hash])
        }
        path = path.removingPercentEncoding ?? path
        let fileURL: URL
        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path).standardizedFileURL
        } else if let directory {
            // Without a trailing slash the base would resolve against its *parent* folder.
            let base = directory.hasDirectoryPath ? directory : URL(fileURLWithPath: directory.path, isDirectory: true)
            fileURL = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        } else if let url = URL(string: trimmed), url.scheme != nil {
            return .remote(url)
        } else {
            return nil
        }
        return localDestination(fileURL)
    }

    /// Existing local files that `source` links to or shows as images (`[a](notes/x.md)`,
    /// `![b](assets/y.png)`), resolved against `directory`. A `#section` / `?query` suffix is
    /// dropped when the full path does not exist; folders and web links are skipped.
    public static func linkedFiles(in source: String, relativeTo directory: URL?) -> [URL] {
        var seen = Set<String>()
        var files: [URL] = []
        for span in MarkdownSyntax.spans(in: source) {
            let raw: String
            switch span.kind {
            case .link(let url), .image(let url): raw = url
            default: continue
            }
            var candidates = [raw]
            if let cut = raw.firstIndex(where: { $0 == "#" || $0 == "?" }), cut != raw.startIndex {
                candidates.append(String(raw[..<cut]))
            }
            for candidate in candidates {
                guard let destination = destination(candidate, relativeTo: directory) else { continue }
                let url: URL
                switch destination {
                case .markdown(let file), .file(let file): url = file
                case .remote: continue
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                if seen.insert(url.path).inserted { files.append(url) }
                break
            }
        }
        return files
    }

    public static func localDestination(_ url: URL) -> Destination {
        markdownExtensions.contains(url.pathExtension.lowercased()) ? .markdown(url) : .file(url)
    }

    public static func looksLikeWebTarget(_ raw: String) -> Bool {
        if raw.hasPrefix("/") || raw.hasPrefix(".") || raw.hasPrefix("~") { return false }
        if raw.contains("://") { return true }
        if raw.lowercased().hasPrefix("www.") { return true }
        let host = raw.split(separator: "/").first.map(String.init) ?? raw
        if markdownExtensions.contains(URL(fileURLWithPath: host).pathExtension.lowercased()) { return false }
        return host.contains(".") && !host.contains(" ")
    }

    @MainActor
    public static func open(_ raw: String, relativeTo directory: URL? = nil) {
        guard let destination = destination(raw, relativeTo: directory) else { return }
        switch destination {
        case .markdown(let url):
            // A link to a Markdown file that does not exist yet creates it (empty) and opens it —
            // as a tab of the current window (see `DocumentWindowController.showWindow`).
            do {
                if try createMarkdownFileIfMissing(url) {
                    GitService.addNewFile(url)
                }
            } catch {
                NSApp.presentError(error)
                return
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        case .file(let url), .remote(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Creates an empty file (and missing parent folders) at `url`. Returns true when it created one.
    /// Never touches an existing file.
    @discardableResult
    public static func createMarkdownFileIfMissing(_ url: URL) throws -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            return false
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `.withoutOverwriting` guards against a file appearing between the check and the write.
        try Data().write(to: url, options: .withoutOverwriting)
        return true
    }

    public static func copy(_ raw: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(raw, forType: .string)
    }
}

/// Word-style hyperlink card: visible text stays in the document; the address is edited here.
/// One row — address field, then icon buttons: Choose File…, Open, Copy, Remove Link.
final class LinkCardView: NSView, NSTextFieldDelegate {
    weak var cardDelegate: LinkCardDelegate?
    private let urlField = NSTextField()
    let overviewButton = LinkCardButton(symbol: "list.bullet.rectangle", tip: "Link to a heading or file in this document’s folder…")
    let chooseButton = LinkCardButton(symbol: "folder", tip: "Choose a file to link to…")
    let openButton = LinkCardButton(symbol: "arrow.up.right.square", tip: "Open link (⌘-click)")
    let copyButton = LinkCardButton(symbol: "doc.on.doc", tip: "Copy address")
    let removeButton = LinkCardButton(image: LinkCardView.unlinkImage(), tip: "Remove link (keeps the text)")
    private var buttons: [LinkCardButton] { [overviewButton, chooseButton, openButton, copyButton, removeButton] }
    private let divider = NSBox()

    /// Sized like the code block's icons (22 pt buttons, 10 pt symbols); the card lives in the
    /// zoomed page, so it scales with the document like the text does.
    static let cardHeight: CGFloat = 30
    static let padding: CGFloat = 5
    static let buttonSize: CGFloat = 22
    static let symbolPointSize: CGFloat = 10
    static let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)

    /// The address uses the document's body size (Settings font size).
    var fieldFontSize: CGFloat = 10 {
        didSet {
            guard fieldFontSize != oldValue else { return }
            urlField.font = .systemFont(ofSize: fieldFontSize)
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    /// Image card: the same card for a clicked picture — its path, Choose Image…, Open, Copy
    /// path, Remove image.
    convenience init(imageMode: Bool) {
        self.init(frame: .zero)
        guard imageMode else { return }
        urlField.placeholderString = "Image path or web address"
        overviewButton.setSymbol(NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Image options")?.withSymbolConfiguration(Self.symbolConfig) ?? NSImage(),
                                 tip: "Image options: size, alignment, alt text…")
        chooseButton.setTip("Choose a different image…")
        openButton.setTip("Open the image")
        copyButton.setTip("Copy the image’s path")
        removeButton.setSymbol(NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove image")?.withSymbolConfiguration(Self.symbolConfig) ?? NSImage(),
                               tip: "Remove the image")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 8
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.16)

        urlField.font = .systemFont(ofSize: fieldFontSize)
        urlField.bezelStyle = .roundedBezel
        urlField.controlSize = .small
        urlField.delegate = self
        urlField.placeholderString = "Address or file"
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.cell?.usesSingleLineMode = true
        addSubview(urlField)
        divider.boxType = .separator
        addSubview(divider)

        overviewButton.target = self
        overviewButton.action = #selector(overviewTapped)
        chooseButton.target = self
        chooseButton.action = #selector(chooseTapped)
        openButton.target = self
        openButton.action = #selector(openTapped)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        buttons.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    /// True when a window point is over one of the icon buttons (the text view below would
    /// otherwise put its I-beam back on every mouse move — see `MarkdownTextView.pointerHotspot`).
    func buttonContains(windowPoint point: NSPoint) -> Bool {
        guard superview != nil, !isHidden else { return false }
        return buttons.contains { button in
            button.isEnabled && button.bounds.contains(button.convert(point, from: nil))
        }
    }

    var url: String { urlField.stringValue }

    func configure(url: String) {
        if urlField.currentEditor() == nil {
            urlField.stringValue = url
        }
        urlField.toolTip = url
        openButton.isEnabled = !url.trimmingCharacters(in: .whitespaces).isEmpty
        copyButton.isEnabled = openButton.isEnabled
    }

    func focusURLField() {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    /// [ address field ] │ [folder] [open] [copy] [unlink] — all vertically centred.
    override func layout() {
        super.layout()
        let p = Self.padding, size = Self.buttonSize
        let buttonsWidth = CGFloat(buttons.count) * size + CGFloat(buttons.count - 1) * 1
        var x = bounds.width - p - buttonsWidth
        for button in buttons {
            button.frame = CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
            x += size + 1
        }
        let dividerX = bounds.width - p - buttonsWidth - 5
        divider.frame = CGRect(x: dividerX, y: 7, width: 1, height: bounds.height - 14)
        let fieldHeight = min(bounds.height - 6, ceil(fieldFontSize * 1.25) + 6)
        urlField.frame = CGRect(x: p + 1, y: (bounds.height - fieldHeight) / 2, width: max(40, dividerX - p - 6), height: fieldHeight)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        cardDelegate?.linkCard(self, commitURL: urlField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    @objc private func chooseTapped() { cardDelegate?.linkCardChooseFile(self) }
    @objc private func overviewTapped() { cardDelegate?.linkCardOverview(self, from: overviewButton) }
    @objc private func openTapped() { cardDelegate?.linkCardOpen(self) }
    @objc private func removeTapped() { cardDelegate?.linkCardRemove(self) }
    @objc private func copyTapped() {
        cardDelegate?.linkCardCopy(self)
        copyButton.flashCheckmark()
    }

    /// "Remove link": the link symbol with a slash through it (SF Symbols has no unlink glyph).
    static func unlinkImage() -> NSImage {
        let link = NSImage(systemSymbolName: "link", accessibilityDescription: "Remove link")?.withSymbolConfiguration(symbolConfig) ?? NSImage()
        let size = NSSize(width: max(link.size.width, 12) + 1, height: max(link.size.height, 12) + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: (rect.width - link.size.width) / 2, dy: (rect.height - link.size.height) / 2)
            link.draw(in: inset)
            // Cut a gap along the slash, then draw the slash.
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 1))
            slash.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
            slash.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.lineWidth = 2.8
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            slash.lineWidth = 1.1
            slash.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Remove link"
        return image
    }
}

/// Borderless 28 pt icon button with a rounded hover fill (like the code block's glass icons).
/// Borderless icon button (link / image card, page popover) with a rounded hover fill.
///
/// The icon is drawn by an image view filling the whole button — not by NSButton's own image
/// drawing: a button made with `NSButton(frame:)` is a push button, which lays its image out in
/// the bezel's content area (top and bottom margins even without a border); with a fixed-size
/// image, anything outside that area was cut off — icons truncated at the top and bottom.
final class LinkCardButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true; updateTint() } }
    private var symbolImage: NSImage?
    private let icon = NSImageView()

    convenience init(symbol: String, tip: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(LinkCardView.symbolConfig) ?? NSImage()
        self.init(image: image, tip: tip)
    }

    convenience init(image: NSImage, tip: String) {
        self.init(frame: .zero)
        title = ""
        bezelStyle = .shadowlessSquare   // no content insets
        isBordered = false
        imagePosition = .noImage
        symbolImage = image
        icon.image = image
        icon.imageScaling = .scaleProportionallyDown
        icon.imageAlignment = .alignCenter
        icon.translatesAutoresizingMaskIntoConstraints = true
        icon.autoresizingMask = [.width, .height]
        icon.frame = bounds
        addSubview(icon)
        toolTip = tip
        setAccessibilityLabel(tip)
        refusesFirstResponder = true
        updateTint()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    /// The icon view never takes the click (the button does).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === icon ? self : hit
    }

    func setTip(_ tip: String) {
        toolTip = tip
        setAccessibilityLabel(tip)
    }

    func setSymbol(_ image: NSImage, tip: String) {
        icon.image = image
        symbolImage = image
        setTip(tip)
    }

    /// The icon currently shown (tests).
    var shownImage: NSImage? { icon.image }
    var iconFrame: NSRect { icon.frame }

    private func updateTint() {
        icon.contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering && isEnabled {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }

    /// Copy feedback: a checkmark for a moment, as on code blocks.
    func flashCheckmark() {
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        icon.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.icon.image = self.symbolImage
                self.updateTint()
            }
        }
    }
}
