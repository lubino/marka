import AppKit
import MarkaCore

final class MarkaDocumentController: NSDocumentController {
    override var defaultType: String? { "Markdown Document" }

    override func documentClass(forType typeName: String) -> AnyClass? {
        MarkdownDocument.self
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenu()
        CrashReporter.presentPendingReportIfNeeded()
        if NSDocumentController.shared.documents.isEmpty {
            _ = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Marka", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
        file.addItem(withTitle: "Export PDF…", action: #selector(DocumentWindowController.exportPDF), keyEquivalent: "e").keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Print…", action: #selector(DocumentWindowController.printDocumentAction), keyEquivalent: "p")
        file.addItem(withTitle: "Share", action: #selector(DocumentWindowController.shareAction(_:)), keyEquivalent: "")
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
        edit.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        let replace = edit.addItem(withTitle: "Find and Replace…", action: #selector(DocumentWindowController.findAction), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        editItem.submenu = edit
        main.addItem(editItem)

        let formatItem = NSMenuItem()
        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(DocumentWindowController.boldAction), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(DocumentWindowController.italicAction), keyEquivalent: "i")
        format.addItem(withTitle: "Strikethrough", action: #selector(DocumentWindowController.strikeAction), keyEquivalent: "")
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
        format.addItem(withTitle: "Code Block", action: #selector(DocumentWindowController.codeBlockAction), keyEquivalent: "")
        format.addItem(withTitle: "Link…", action: #selector(DocumentWindowController.linkAction), keyEquivalent: "k")
        format.addItem(withTitle: "Image…", action: #selector(DocumentWindowController.imageAction), keyEquivalent: "")
        format.addItem(withTitle: "Insert Table", action: #selector(DocumentWindowController.tableAction(_:)), keyEquivalent: "")
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
        tableItem.submenu = table
        format.addItem(tableItem)
        formatItem.submenu = format
        main.addItem(formatItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(DocumentWindowController.toggleSidebar), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Source Mode", action: #selector(DocumentWindowController.toggleSourceMode), keyEquivalent: "/")
        view.addItem(.separator())
        view.addItem(withTitle: "Auto Width", action: #selector(DocumentWindowController.zoomAuto), keyEquivalent: "")
        view.addItem(withTitle: "Wide", action: #selector(DocumentWindowController.zoomWide), keyEquivalent: "")
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
        helpItem.submenu = help
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    @objc private func openHelp() {
        if let url = URL(string: "https://github.com/lubino/marka") {
            NSWorkspace.shared.open(url)
        }
    }
}
