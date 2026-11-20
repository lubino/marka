import AppKit
import MarkaCore

final class MarkaDocumentController: NSDocumentController {
    override var defaultType: String? { "Markdown Document" }

    override func documentClass(forType typeName: String) -> AnyClass? {
        MarkdownDocument.self
    }

    /// An untitled document nobody has typed into yet — it gives way to a file the user opens.
    static func isPristineUntitled(_ document: NSDocument) -> Bool {
        guard document.fileURL == nil, !document.isDocumentEdited else { return false }
        return (document as? MarkdownDocument)?.editorString().isEmpty ?? true
    }

    /// Opening a file while the only document is an untouched "Untitled" replaces it (TextEdit-style)
    /// instead of leaving an empty first tab.
    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        let placeholders = documents.filter(Self.isPristineUntitled)
        let replace = documents.count == 1 && placeholders.count == 1
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            if replace, document != nil, !alreadyOpen {
                placeholders.forEach { $0.close() }
            }
            completionHandler(document, alreadyOpen, error)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let shareItemID = NSUserInterfaceItemIdentifier("file.share")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenu()
        CrashReporter.presentPendingReportIfNeeded()
        // No explicit "open Untitled" here: files opened from Finder arrive *after* this callback, and
        // AppKit asks `applicationShouldOpenUntitledFile` only when nothing else is being opened.
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func buildMenu() {
        NSApp.mainMenu = makeMainMenu()
    }

    func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Marka", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(DocumentWindowController.showSettings), keyEquivalent: ",")
        settings.target = nil
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Marka", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Marka", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        file.items.last?.submenu = NSMenu()
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        file.addItem(.separator())
        let exportPDF = file.addItem(withTitle: "Export PDF…", action: #selector(DocumentWindowController.exportPDF), keyEquivalent: "e")
        exportPDF.keyEquivalentModifierMask = [.command, .shift]
        exportPDF.image = DocumentWindowController.menuSymbol("arrow.down.document")
        exportPDF.showsImage()
        file.addItem(withTitle: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        let publish = file.addItem(withTitle: "Publish…", action: #selector(DocumentWindowController.publishAction), keyEquivalent: "")
        publish.image = DocumentWindowController.menuSymbol("paperplane")
        publish.showsImage()
        // Replaced by the system Share submenu for the current document each time the menu opens.
        let share = file.addItem(withTitle: "Share", action: nil, keyEquivalent: "")
        share.identifier = Self.shareItemID
        share.isEnabled = false
        file.delegate = self
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(DocumentWindowController.undoAction), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(DocumentWindowController.redoAction), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let undoControl = edit.addItem(withTitle: "Undo", action: #selector(DocumentWindowController.undoAction), keyEquivalent: "z")
        undoControl.keyEquivalentModifierMask = [.control]
        undoControl.isHidden = true
        let redoControl = edit.addItem(withTitle: "Redo", action: #selector(DocumentWindowController.redoAction), keyEquivalent: "z")
        redoControl.keyEquivalentModifierMask = [.control, .shift]
        redoControl.isHidden = true
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(DocumentWindowController.findAction), keyEquivalent: "f")
        edit.addItem(withTitle: "Find Next", action: #selector(DocumentWindowController.findNextAction), keyEquivalent: "g")
        edit.addItem(withTitle: "Find Previous", action: #selector(DocumentWindowController.findPreviousAction), keyEquivalent: "G")
        let replace = edit.addItem(withTitle: "Find and Replace…", action: #selector(DocumentWindowController.findAndReplaceAction), keyEquivalent: "f")
        edit.addItem(withTitle: "Replace Emojis…", action: #selector(DocumentWindowController.replaceEmojisAction), keyEquivalent: "")
        replace.keyEquivalentModifierMask = [.command, .option]
        editItem.submenu = edit
        main.addItem(editItem)

        let formatItem = NSMenuItem()
        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(DocumentWindowController.boldAction), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(DocumentWindowController.italicAction), keyEquivalent: "i")
        format.addItem(withTitle: "Strikethrough", action: #selector(DocumentWindowController.strikeAction), keyEquivalent: "")
        format.addItem(withTitle: "Underline", action: #selector(DocumentWindowController.underlineAction), keyEquivalent: "u")
        format.addItem(withTitle: "Superscript", action: #selector(DocumentWindowController.superscriptAction), keyEquivalent: "")
        format.addItem(withTitle: "Subscript", action: #selector(DocumentWindowController.subscriptAction), keyEquivalent: "")
        format.addItem(withTitle: "Keyboard Key", action: #selector(DocumentWindowController.keyboardAction), keyEquivalent: "")
        format.addItem(withTitle: "Inline Code", action: #selector(DocumentWindowController.codeAction), keyEquivalent: "")
        format.addItem(.separator())
        format.addItem(withTitle: "Heading 1", action: #selector(DocumentWindowController.applyHeading1), keyEquivalent: "1").keyEquivalentModifierMask = [.command, .option]
        format.addItem(withTitle: "Heading 2", action: #selector(DocumentWindowController.applyHeading2), keyEquivalent: "2").keyEquivalentModifierMask = [.command, .option]
        format.addItem(withTitle: "Heading 3", action: #selector(DocumentWindowController.applyHeading3), keyEquivalent: "3").keyEquivalentModifierMask = [.command, .option]
        format.addItem(.separator())
        format.addItem(withTitle: "Bulleted List", action: #selector(DocumentWindowController.listAction), keyEquivalent: "")
        format.addItem(withTitle: "Numbered List", action: #selector(DocumentWindowController.orderedListAction), keyEquivalent: "")
        format.addItem(withTitle: "Task List", action: #selector(DocumentWindowController.taskListAction), keyEquivalent: "")
        format.addItem(withTitle: "Quote", action: #selector(DocumentWindowController.quoteAction), keyEquivalent: "")
        let codeBlockItem = NSMenuItem(title: "Code Block", action: nil, keyEquivalent: "")
        let codeBlocks = NSMenu(title: "Code Block")
        codeBlocks.addItem(withTitle: "Text", action: #selector(DocumentWindowController.insertPlainCodeBlock), keyEquivalent: "")
        codeBlocks.addItem(withTitle: "Bash", action: #selector(DocumentWindowController.insertBashCodeBlock), keyEquivalent: "")
        codeBlocks.addItem(withTitle: "Python", action: #selector(DocumentWindowController.insertPythonCodeBlock), keyEquivalent: "")
        codeBlocks.addItem(withTitle: "Swift", action: #selector(DocumentWindowController.insertSwiftCodeBlock), keyEquivalent: "")
        codeBlocks.addItem(withTitle: "JSON", action: #selector(DocumentWindowController.insertJSONCodeBlock), keyEquivalent: "")
        codeBlockItem.submenu = codeBlocks
        format.addItem(codeBlockItem)
        format.addItem(withTitle: "Link…", action: #selector(DocumentWindowController.linkAction), keyEquivalent: "k")
        format.addItem(withTitle: "Image…", action: #selector(DocumentWindowController.imageAction), keyEquivalent: "")
        format.addItem(withTitle: "Horizontal Rule", action: #selector(DocumentWindowController.ruleAction), keyEquivalent: "")
        format.addItem(withTitle: "Page Break", action: #selector(DocumentWindowController.pageBreakAction), keyEquivalent: "")
        format.addItem(.separator())
        let tableItem = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
        let table = NSMenu(title: "Table")
        table.addItem(withTitle: "Insert Row Above", action: #selector(DocumentWindowController.insertTableRowAbove), keyEquivalent: "")
        table.addItem(withTitle: "Insert Row Below", action: #selector(DocumentWindowController.insertTableRowBelow), keyEquivalent: "")
        table.addItem(withTitle: "Insert Column Left", action: #selector(DocumentWindowController.insertTableColumnLeft), keyEquivalent: "")
        table.addItem(withTitle: "Insert Column Right", action: #selector(DocumentWindowController.insertTableColumnRight), keyEquivalent: "")
        table.addItem(.separator())
        table.addItem(withTitle: "Delete Row", action: #selector(DocumentWindowController.deleteTableRow), keyEquivalent: "")
        table.addItem(withTitle: "Delete Column", action: #selector(DocumentWindowController.deleteTableColumn), keyEquivalent: "")
        table.addItem(withTitle: "Delete Table", action: #selector(DocumentWindowController.deleteTable), keyEquivalent: "")
        table.addItem(.separator())
        table.addItem(withTitle: "Align Column Left", action: #selector(DocumentWindowController.alignColumnLeft), keyEquivalent: "")
        table.addItem(withTitle: "Align Column Center", action: #selector(DocumentWindowController.alignColumnCenter), keyEquivalent: "")
        table.addItem(withTitle: "Align Column Right", action: #selector(DocumentWindowController.alignColumnRight), keyEquivalent: "")
        tableItem.submenu = table
        format.addItem(tableItem)
        formatItem.submenu = format
        main.addItem(formatItem)

        // Insert: each item opens a gallery of examples at the caret (blocks | math | Mermaid).
        let insertItem = NSMenuItem()
        let insert = NSMenu(title: "Insert")
        insert.addItem(withTitle: "Table", action: #selector(DocumentWindowController.tableAction(_:)), keyEquivalent: "")
        insert.addItem(withTitle: "Image…", action: #selector(DocumentWindowController.imageAction), keyEquivalent: "")
        insert.addItem(withTitle: "Code Block", action: #selector(DocumentWindowController.insertCodeBlockGallery), keyEquivalent: "")
        insert.addItem(.separator())
        insert.addItem(withTitle: "Equation", action: #selector(DocumentWindowController.insertEquationGallery), keyEquivalent: "")
        insert.addItem(withTitle: "Matrix", action: #selector(DocumentWindowController.insertMatrixGallery), keyEquivalent: "")
        insert.addItem(.separator())
        insert.addItem(withTitle: "Flowchart", action: #selector(DocumentWindowController.insertFlowchartGallery), keyEquivalent: "")
        insert.addItem(withTitle: "Left-to-right flow", action: #selector(DocumentWindowController.insertLeftToRightGallery), keyEquivalent: "")
        insert.addItem(withTitle: "Sequence Diagram", action: #selector(DocumentWindowController.insertSequenceGallery), keyEquivalent: "")
        insert.addItem(withTitle: "Pie chart", action: #selector(DocumentWindowController.insertPieGallery), keyEquivalent: "")
        insert.addItem(.separator())
        // GitHub alerts: > [!NOTE] … > [!CAUTION]
        for (title, selector) in [("Note", #selector(DocumentWindowController.insertNoteAlert)), ("Tip", #selector(DocumentWindowController.insertTipAlert)),
                                  ("Important", #selector(DocumentWindowController.insertImportantAlert)), ("Warning", #selector(DocumentWindowController.insertWarningAlert)),
                                  ("Caution", #selector(DocumentWindowController.insertCautionAlert))] {
            insert.addItem(withTitle: title, action: selector, keyEquivalent: "")
        }
        insertItem.submenu = insert
        main.addItem(insertItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(DocumentWindowController.toggleSidebar), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Source Mode", action: #selector(DocumentWindowController.toggleSourceMode), keyEquivalent: "/")
        view.addItem(.separator())
        view.addItem(withTitle: "Go to Page…", action: #selector(DocumentWindowController.showDocumentInfo(_:)), keyEquivalent: "g").keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Go to Content…", action: #selector(DocumentWindowController.goToContentAction), keyEquivalent: "l")
        view.addItem(.separator())
        view.addItem(withTitle: "Auto Zoom", action: #selector(DocumentWindowController.zoomAuto), keyEquivalent: "")
        view.addItem(withTitle: "Zoom In", action: #selector(DocumentWindowController.zoomIn), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(DocumentWindowController.zoomOut), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(DocumentWindowController.zoomActual), keyEquivalent: "0")
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Marka Help", action: #selector(openHelp), keyEquivalent: "?")
        help.addItem(withTitle: "Keyboard Shortcuts", action: #selector(openShortcuts), keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)

        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.identifier == Self.shareItemID }) else { return }
        let controller = (NSApp.mainWindow ?? NSApp.keyWindow)?.windowController as? DocumentWindowController
        let item: NSMenuItem
        if let controller {
            item = controller.makeShareMenuItem()
        } else {
            item = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        item.identifier = Self.shareItemID
        menu.removeItem(at: index)
        menu.insertItem(item, at: index)
    }

    static let projectURL = URL(string: "https://github.com/lubino/marka")!

    /// The standard About panel, with a clickable link to the project on GitHub in its credits.
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits()])
        NSApp.activate(ignoringOtherApps: true)
    }

    static func aboutCredits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString(string: "A free, native Markdown editor for macOS.\n", attributes: [
            .font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center
        ])
        text.append(NSAttributedString(string: "github.com/lubino/marka", attributes: [
            .font: small, .link: projectURL, .paragraphStyle: center
        ]))
        return text
    }

    @objc private func openHelp() { openBundledGuide("Help") }
    @objc private func openShortcuts() { openBundledGuide("Shortcuts") }

    /// Opens Help.md / Shortcuts.md from the app bundle as a Marka tab. A fresh read-only copy in
    /// ~/Library/Application Support/Marka/Help keeps the bundle untouched (and up to date after
    /// updates); without the bundled file (swift run), the GitHub page opens instead.
    private func openBundledGuide(_ name: String) {
        guard let source = Bundle.main.url(forResource: name, withExtension: "md") else {
            if let url = URL(string: "https://github.com/lubino/marka/blob/main/\(name).md") { NSWorkspace.shared.open(url) }
            return
        }
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Marka/Help", isDirectory: true)
        let copy = folder.appendingPathComponent("\(name).md")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: copy.path) {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
                try fm.removeItem(at: copy)
            }
            try fm.copyItem(at: source, to: copy)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)
        } catch {
            NSWorkspace.shared.open(source)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: copy, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}

extension NSMenuItem {
    /// macOS 27 decides itself whether menu item images show — and usually hides them (only a few
    /// standard items like Print or Share keep theirs). `preferredImageVisibility = .visible`
    /// asks for ours. Set through KVC: the property only exists in the macOS 27 SDK, and CI
    /// builds with an older one.
    func showsImage() {
        let key = "preferredImageVisibility"
        guard responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        setValue(1, forKey: key)   // NSMenuItemImageVisibilityVisible
    }

    /// The image visibility AppKit was asked for (nil before macOS 27).
    var preferredImageVisibilityValue: Int? {
        responds(to: NSSelectorFromString("preferredImageVisibility")) ? (value(forKey: "preferredImageVisibility") as? Int) : nil
    }
}
