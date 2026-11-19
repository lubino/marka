import AppKit
import MarkaCore

protocol LinkCardDelegate: AnyObject {
    func linkCard(_ view: LinkCardView, commitURL url: String)
    func linkCardOpen(_ view: LinkCardView)
    func linkCardCopy(_ view: LinkCardView)
    func linkCardRemove(_ view: LinkCardView)
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

        if looksLikeWebTarget(trimmed) {
            let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: withScheme) { return .remote(url) }
        }

        // Local paths: `<new idea.md>` and `new%20idea.md` both mean the file "new idea.md".
        var path = trimmed
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
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
                try createMarkdownFileIfMissing(url)
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

/// Word-style hyperlink card: visible text stays in the document; URL is edited here.
final class LinkCardView: NSView, NSTextFieldDelegate {
    weak var cardDelegate: LinkCardDelegate?
    private let urlField = NSTextField()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    static let cardHeight: CGFloat = 58

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 10
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.18)

        urlField.placeholderString = "https://"
        urlField.font = .systemFont(ofSize: 12)
        urlField.bezelStyle = .roundedBezel
        urlField.delegate = self
        urlField.placeholderString = "Address"

        for button in [openButton, copyButton, removeButton] {
            button.bezelStyle = .roundRect
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.isBordered = true
        }
        openButton.action = #selector(openTapped)
        copyButton.action = #selector(copyTapped)
        removeButton.action = #selector(removeTapped)
        openButton.toolTip = "Open link"
        copyButton.toolTip = "Copy address"
        removeButton.toolTip = "Remove hyperlink"

        addSubview(urlField)
        addSubview(openButton)
        addSubview(copyButton)
        addSubview(removeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var url: String { urlField.stringValue }

    func configure(url: String) {
        if urlField.currentEditor() == nil {
            urlField.stringValue = url
        }
    }

    func focusURLField() {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    override func layout() {
        super.layout()
        urlField.frame = CGRect(x: 8, y: 6, width: max(40, bounds.width - 16), height: 22)
        openButton.frame = CGRect(x: 8, y: 32, width: 56, height: 20)
        copyButton.frame = CGRect(x: 70, y: 32, width: 56, height: 20)
        removeButton.frame = CGRect(x: 132, y: 32, width: 70, height: 20)
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

    @objc private func openTapped() { cardDelegate?.linkCardOpen(self) }
    @objc private func copyTapped() { cardDelegate?.linkCardCopy(self) }
    @objc private func removeTapped() { cardDelegate?.linkCardRemove(self) }
}