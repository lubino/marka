import AppKit
import MarkaCore

/// Test hooks for auto-load, Publish and the rendered-source editor (`swift run MarkaUITests`).
@MainActor
public final class DocumentFileHarness {
    let document: MarkdownDocument
    var controller: DocumentWindowController? { document.windowControllers.first as? DocumentWindowController }

    /// Opens `url` as a real document with its window (off-screen).
    public init(url: URL) throws {
        document = try MarkdownDocument(contentsOf: url, ofType: "Markdown Document")
        NSDocumentController.shared.addDocument(document)   // as when opened in the app
        document.makeWindowControllers()
        if let window = controller?.window {
            window.isReleasedWhenClosed = false
            window.setFrame(NSRect(x: -4800, y: -4800, width: 1100, height: 760), display: true)
            window.orderFrontRegardless()
        }
        document.watchFile()
        pump(0.3)
    }

    public var text: String { document.editorString() }
    public var isEdited: Bool { document.isDocumentEdited }
    public var gitRootPath: String? { controller?.gitRoot?.path }
    public var hasPublishToolbarItem: Bool {
        controller?.window?.toolbar?.items.contains { $0.itemIdentifier.rawValue == "publish" } ?? false
    }

    /// Types `text` at the end of the document (a normal, undoable edit).
    public func type(_ text: String) {
        controller?.testType(text)
        pump(0.1)
    }

    public func save() {
        var done = false
        document.save(to: document.fileURL!, ofType: document.fileType!, for: .saveOperation) { _ in done = true }
        let until = Date().addingTimeInterval(3)
        while !done, Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        pump(0.4)
    }

    public func checkForExternalChange() {
        document.checkForExternalChange()
        pump(0.2)
    }

    public func refreshGitState() {
        controller?.refreshGitState()
        pump(1.0)
    }

    public func close() {
        controller?.window?.orderOut(nil)
        document.close()
    }

    public func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: until) }
    }
}

/// The Publish popover's view controller, built from a fake snapshot.
@MainActor
public final class PublishPopoverHarness {
    let controller: PublishViewController

    public init(snapshot: PublishSnapshot) {
        controller = PublishViewController(snapshot: snapshot)
        _ = controller.view
        controller.view.setFrameSize(controller.preferredContentSize)
    }

    public var publishEnabled: Bool { controller.testPublishEnabled }
    public var message: String { controller.testMessage }
    public var visibleTab: Int { controller.testVisibleTab }
    public var diffText: String { controller.testDiffText }
    public var preferredSize: NSSize { controller.preferredContentSize }
    public var buttonFrames: (publish: NSRect, cancel: NSRect, bounds: NSRect) { controller.testButtonFrames }
    public func setMessage(_ text: String) { controller.testSetMessage(text) }
    public func selectTab(_ index: Int) { controller.testSelectTab(index) }
    public func clickFile(_ index: Int) { controller.testClickFile(index) }

    /// Writes the popover content as a PNG (visual check), drawn in a borderless window so
    /// materials and controls render like on screen.
    public func snapshot(tab: Int, to path: String, dark: Bool = false) {
        controller.testSelectTab(tab)
        render(controller.view, size: controller.preferredContentSize, to: path, dark: dark)
    }

    func render(_ content: NSView, size: NSSize, to path: String, dark: Bool = false) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        window.contentView = background
        content.frame = background.bounds
        background.addSubview(content)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let rep = background.bitmapImageRepForCachingDisplay(in: background.bounds) {
            background.cacheDisplay(in: background.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
        content.removeFromSuperview()
    }

    /// Failure sheet: texts, and whether "Show more" reveals the log (and grows the accessory).
    public static func failureAlert(_ outcome: PublishOutcome) -> (title: String, text: String, collapsedHeight: CGFloat, expandedHeight: CGFloat, log: Bool) {
        let alert = NSAlert()
        let texts = PublishFailureAlert.message(for: outcome)
        let view = LogDisclosureView(log: outcome.log, alert: alert)
        let collapsed = view.frame.height
        view.toggleLog()
        let shown = view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTextView
        return (texts.title, texts.text, collapsed, view.frame.height, view.isExpanded && shown?.string == outcome.log)
    }

    public static func renderedEditorSnapshot(mermaid: Bool, to path: String) {
        let source = mermaid ? "graph LR\n  A --> B" : "\\frac{a}{b}"
        let editor = RenderedSourceEditor(source: source, mermaid: mermaid) { _ in
            NSImage(size: NSSize(width: 160, height: 50), flipped: false) { rect in
                NSColor.systemBlue.withAlphaComponent(0.2).setFill(); rect.fill(); return true
            }
        }
        let harness = PublishPopoverHarness(snapshot: PublishSnapshot(root: URL(fileURLWithPath: "/"), branch: nil, hasOrigin: false, changes: [], diffs: [:], commits: []))
        _ = editor.view
        harness.render(editor.view, size: editor.preferredContentSize, to: path)
    }

    /// LaTeX / Mermaid source popover: Done button frame and root bounds.
    public static func renderedEditorDoneFrame(mermaid: Bool) -> (done: NSRect, bounds: NSRect) {
        let editor = RenderedSourceEditor(source: "x^2", mermaid: mermaid) { _ in NSImage(size: NSSize(width: 100, height: 40)) }
        _ = editor.view
        editor.view.setFrameSize(editor.preferredContentSize)
        return editor.testDoneFrame
    }
}

/// Insert menu and galleries.
@MainActor
public enum InsertHarness {
    /// Titles of the Insert menu ("-" for separators) and of the Format menu.
    public static func menuTitles() -> (insert: [String], format: [String]) {
        let delegate = AppDelegate()
        let main = delegate.makeMainMenu()
        defer { withExtendedLifetime(delegate) {} }
        func titles(_ name: String) -> [String] {
            main.items.first { $0.submenu?.title == name }?.submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        }
        return (titles("Insert"), titles("Format"))
    }

    /// Preview image sizes of a gallery (all must be non-empty).
    public static func previewSizes(_ kind: InsertKind) -> [CGSize] {
        InsertGalleryView(kind: kind, darkPaper: false).testPreviewSizes
    }

    public static func snapshot(_ kind: InsertKind, to path: String) {
        let gallery = InsertGalleryView(kind: kind, darkPaper: false)
        PublishPopoverHarness(snapshot: PublishSnapshot(root: URL(fileURLWithPath: "/"), branch: nil, hasOrigin: false, changes: [], diffs: [:], commits: []))
            .render(gallery, size: InsertGalleryView.preferredSize(for: kind), to: path)
    }

    public static func publishedUpdateTexts(_ update: PublishedUpdate) -> (title: String, text: String) {
        DocumentWindowController.publishedUpdateTexts(update, name: nil)
    }
}

extension EditorWindowHarness {
    /// Picks tile `index` of the `kind` gallery at the caret, as a click would.
    public func insertTemplate(_ kind: InsertKind, _ index: Int) {
        controller.testPickInsertTemplate(kind, index)
        pump(0.3)
    }
}

extension DocumentFileHarness {
    /// Runs the published-update flow as if the user answered Yes.
    public func applyPublishedUpdate(_ update: PublishedUpdate) {
        controller?.applyPublishedUpdate(update)
        pump(1.5)
    }
}

extension DocumentFileHarness {
    /// What Publish would show (paths and labels), gathered exactly as the toolbar button does.
    public func publishChanges() -> [GitChange] {
        var result: [GitChange]?
        controller?.gatherPublishSnapshot { result = $0.changes }
        let until = Date().addingTimeInterval(5)
        while result == nil, Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return result ?? []
    }

    public static func linkedFiles(in source: String, directory: URL) -> [String] {
        Hyperlink.linkedFiles(in: source, relativeTo: directory).map(\.lastPathComponent)
    }
}

/// File references (image insert, link Choose File) and the link card.
@MainActor
public enum FileReferenceHarness {
    /// "inside:<path>", "outside:<suggested name>" or "absolute:<path>".
    public static func decide(_ file: URL, image: Bool, documentDirectory: URL?, trackedRoot: URL?) -> String {
        switch FileReference.decide(file, kind: image ? .image : .link, documentDirectory: documentDirectory, trackedRoot: trackedRoot) {
        case .inside(let path): return "inside:\(path)"
        case .outside(let name): return "outside:\(name)"
        case .absolute(let path): return "absolute:\(path)"
        }
    }

    public static func copy(_ file: URL, named name: String, into directory: URL) throws -> URL {
        try FileReference.copyFile(file, named: name, into: directory)
    }

    public static func alertTexts(image: Bool, inRepository: Bool) -> (title: String, text: String, buttons: [String], field: String) {
        let (alert, field) = FileReference.makeAlert(file: URL(fileURLWithPath: "/tmp/My Photo.png"), kind: image ? .image : .link,
                                                     suggestedName: "assets/My Photo.png", inRepository: inRepository)
        return (alert.messageText, alert.informativeText, alert.buttons.map(\.title), field.stringValue)
    }

    public static func trackIfNeeded(_ url: URL) {
        GitService.trackIfNeeded(url)
        let until = Date().addingTimeInterval(1.5)
        while Date() < until { RunLoop.current.run(mode: .default, before: until) }
    }

    /// Link card laid out at `width`: frames of field and buttons, card bounds, button tooltips.
    public static func linkCardLayout(width: CGFloat, url: String) -> (field: NSRect, buttons: [NSRect], bounds: NSRect, tips: [String]) {
        let card = LinkCardView(frame: NSRect(x: 0, y: 0, width: width, height: LinkCardView.cardHeight))
        card.fieldFontSize = 10
        card.configure(url: url)
        card.layout()
        let buttons = [card.chooseButton, card.openButton, card.copyButton, card.removeButton]
        let field = card.subviews.first { $0 is NSTextField }?.frame ?? .zero
        return (field, buttons.map(\.frame), card.bounds, buttons.map { $0.toolTip ?? "" })
    }

    public static func linkCardSnapshot(to path: String, dark: Bool = false) {
        let card = LinkCardView(frame: NSRect(x: 12, y: 12, width: 300, height: LinkCardView.cardHeight))
        card.configure(url: "docs/file.md")
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 324, height: LinkCardView.cardHeight + 24))
        host.addSubview(card)
        PublishPopoverHarness(snapshot: PublishSnapshot(root: URL(fileURLWithPath: "/"), branch: nil, hasOrigin: false, changes: [], diffs: [:], commits: []))
            .render(host, size: host.frame.size, to: path, dark: dark)
    }
}

extension EditorWindowHarness {
    public var imageFrames: [CGRect] { controller.testCanvas.testImageFrames }
    public var imagePlaceholders: [Bool] { controller.testCanvas.testImagePlaceholders }
    public var contentWidth: CGFloat { controller.testCanvas.geometry.contentSize.width }
    public func clickImage(_ index: Int) { controller.testCanvas.testClickImage(index); pump(0.1) }
    public var imageCardURL: String? { controller.testCanvas.testImageCardURL }
    public func imageCardCommit(_ source: String) { controller.testCanvas.testImageCardCommit(source); pump(0.3) }
    public func imageCardRemove() { controller.testCanvas.testImageCardRemove(); pump(0.3) }

    /// Writes a solid PNG of `size` points (tests).
    public static func writePNG(_ size: CGSize, to url: URL) throws {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}

extension FileReferenceHarness {
    /// Code-block icon size vs link-card button size, and the card field's font size.
    public static func linkCardSizes() -> (button: CGFloat, codeIcon: CGFloat, symbolPoints: CGFloat, fieldFont: CGFloat) {
        let card = LinkCardView(frame: NSRect(x: 0, y: 0, width: 300, height: LinkCardView.cardHeight))
        card.fieldFontSize = 10
        let field = card.subviews.compactMap { $0 as? NSTextField }.first
        return (LinkCardView.buttonSize, 22, LinkCardView.symbolPointSize, field?.font?.pointSize ?? 0)
    }
}

extension EditorWindowHarness {
    /// Whether the text view shows the pointing hand at the centre of link-card button `index`
    /// (and the I-beam over the address field).
    public func linkCardPointer(button index: Int) -> (button: Bool, field: Bool) {
        let canvas = controller.testCanvas
        let card = canvas.linkCard
        guard card.superview != nil else { return (false, false) }
        let buttons = [card.chooseButton, card.openButton, card.copyButton, card.removeButton]
        let center = buttons[index].convert(NSPoint(x: buttons[index].bounds.midX, y: buttons[index].bounds.midY), to: nil)
        let field = card.subviews.compactMap { $0 as? NSTextField }.first
        let fieldPoint = field.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) } ?? .zero
        let hotspot = canvas.textView.pointerHotspot
        return (hotspot?(center) == true, hotspot?(fieldPoint) == true)
    }
}

extension EditorWindowHarness {
    /// "underline", "superscript", "subscript", "keyboard" — as the Effects pull-down does.
    public func applyEffect(_ name: String) {
        switch name {
        case "underline": controller.underlineAction()
        case "superscript": controller.superscriptAction()
        case "subscript": controller.subscriptAction()
        default: controller.keyboardAction()
        }
        pump(0.2)
    }

    public func underlined(at location: Int) -> Bool {
        (controller.testCanvas.textView.textStorage?.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int ?? 0) != 0
    }

    public func baselineOffset(at location: Int) -> CGFloat {
        controller.testCanvas.textView.textStorage?.attribute(.baselineOffset, at: location, effectiveRange: nil) as? CGFloat ?? 0
    }

    /// Alert kind of each drawn quote bar ("" for a plain quote).
    public var quoteBars: [String] { controller.testCanvas.quoteChromes.map { $0.alert?.rawValue ?? "" } }
    public var alertTitlesDrawn: Int { controller.testCanvas.quoteChromes.filter { $0.titleRect != nil }.count }

    public func openAnchor(_ anchor: String) {
        controller.markdownTextView(controller.testCanvas.textView, openAnchor: anchor)
        pump(0.2)
    }

    public var caretLocation: Int { controller.testCanvas.textView.selectedRange().location }

    /// Overview popover rows ("§ Headings", "# intro", "file notes.md"), optionally filtered.
    /// Which overview rows show the pointing hand (headings and files yes, section titles no).
    public func overviewPointers(directory: URL) -> [Bool] {
        let overview = DocumentOverviewViewController(headings: MarkdownSyntax.headingAnchors(in: markdown),
                                                      files: DocumentOverviewViewController.linkableFiles(in: directory, excluding: nil), navigation: true)
        _ = overview.view
        return overview.testRowPointers
    }

    /// Rows left highlighted after hovering row `a`, then `b` (the list scrolled under the pointer).
    public func overviewHoverAfterScroll(directory: URL, from a: Int, to b: Int) -> [Int] {
        let overview = DocumentOverviewViewController(headings: MarkdownSyntax.headingAnchors(in: markdown),
                                                      files: DocumentOverviewViewController.linkableFiles(in: directory, excluding: nil), navigation: true)
        return overview.testHoverSequence(a, b)
    }

    public func insertImageInCell(path: String, alt: String) {
        controller.testInsertImageInCell(path: path, alt: alt)
        pump(0.2)
    }

    public var toolbarIdentifiers: [String] { controller.testToolbarIdentifiers }
    public func openOverviewFromToolbar() -> Bool {
        let shown = controller.testOpenOverviewFromToolbar()
        pump(0.1)
        return shown
    }

    /// Page popover: the overview button is the link-card style hover button (pointing hand).
    public static var pageOverviewButtonSize: CGSize? {
        let info = DocumentInfoViewController()
        _ = info.view
        guard let button = info.overviewButton else { return nil }
        info.view.layoutSubtreeIfNeeded()
        return button.frame.size
    }

    public func overviewRows(filter: String = "", directory: URL? = nil) -> [String] {
        let files = directory.map { DocumentOverviewViewController.linkableFiles(in: $0, excluding: nil) } ?? []
        let overview = DocumentOverviewViewController(headings: MarkdownSyntax.headingAnchors(in: markdown), files: files, navigation: true)
        _ = overview.view
        overview.filter(filter)
        return overview.testItems.map { item in
            switch item {
            case .section(let title): return "§ " + title
            case .heading(let anchor): return "# " + anchor.slug
            case .file(_, let relative): return "file " + relative
            }
        }
    }

    public func applyImageOptions(_ index: Int, width: String, align: String) {
        let canvas = controller.testCanvas
        canvas.testClickImage(index)
        guard let location = canvas.imageCardLocation,
              let image = MarkdownSyntax.imageLines(in: markdown).flatMap(\.images).first(where: { $0.group.location == location }) else { return }
        var options = ImageOptions(image)
        options.width = width
        options.align = align
        canvas.applyImageOptions(at: location, options)
        pump(0.3)
    }

    /// Turns emoji shortcodes on for this editor only (Settings are not touched).
    public func setEmojiShortcodes(_ on: Bool) {
        var settings = controller.testCanvas.textView.editorSettings
        settings.emojiShortcodes = on
        controller.testCanvas.textView.editorSettings = settings
        controller.testCanvas.textView.applyStyles()
        pump(0.2)
    }

    public var drawnEmoji: [String] {
        guard let storage = controller.testCanvas.textView.textStorage else { return [] }
        var found: [String] = []
        storage.enumerateAttribute(.markaEmoji, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let emoji = value as? String { found.append(emoji) }
        }
        return found
    }

    /// Edit → Replace Emojis…, then All.
    public func replaceAllEmojis() -> String {
        controller.replaceEmojisAction()
        pump(0.2)
        let count = controller.testFindController.testCountText
        controller.testFindController.replaceAll()
        pump(0.2)
        return count
    }
}

extension EditorWindowHarness {
    /// Snapshots of the image options and overview popovers (visual checks).
    public func popoverSnapshots(to dir: String, directory: URL) {
        let painter = PublishPopoverHarness(snapshot: PublishSnapshot(root: URL(fileURLWithPath: "/"), branch: nil, hasOrigin: false, changes: [], diffs: [:], commits: []))
        let options = ImageOptionsViewController(options: ImageOptions(alt: "Logo", width: "100", align: "center"), naturalSize: CGSize(width: 200, height: 100))
        _ = options.view
        painter.render(options.view, size: options.preferredContentSize, to: "\(dir)/image-options.png")
        let overview = DocumentOverviewViewController(headings: MarkdownSyntax.headingAnchors(in: markdown),
                                                      files: DocumentOverviewViewController.linkableFiles(in: directory, excluding: nil), navigation: false)
        _ = overview.view
        painter.render(overview.view, size: overview.preferredContentSize, to: "\(dir)/overview.png")
    }
}

extension InsertHarness {
    /// View menu titles with their shortcuts ("Go to Content… ⌘L").
    public static func viewMenu() -> [String] {
        let delegate = AppDelegate()
        let main = delegate.makeMainMenu()
        defer { withExtendedLifetime(delegate) {} }
        let view = main.items.first { $0.submenu?.title == "View" }?.submenu
        return view?.items.filter { !$0.isSeparatorItem }.map { item in
            var keys = ""
            if item.keyEquivalentModifierMask.contains(.option) { keys += "⌥" }
            if item.keyEquivalentModifierMask.contains(.command) && !item.keyEquivalent.isEmpty { keys += "⌘" }
            return keys.isEmpty ? item.title : "\(item.title) \(keys)\(item.keyEquivalent.uppercased())"
        } ?? []
    }
}

extension EditorWindowHarness {
    public var toolbarPaletteLabels: [String: String] {
        var labels: [String: String] = [:]
        for item in controller.window?.toolbar?.items ?? [] { labels[item.itemIdentifier.rawValue] = item.paletteLabel }
        return labels
    }
}

extension InsertHarness {
    /// File menu items with an icon.
    public static func fileMenuItemsWithIcons() -> [String] {
        let delegate = AppDelegate()
        let main = delegate.makeMainMenu()
        defer { withExtendedLifetime(delegate) {} }
        let file = main.items.first { $0.submenu?.title == "File" }?.submenu
        // An image only counts when macOS 27 is also asked to show it.
        return file?.items.filter { $0.image != nil && ($0.preferredImageVisibilityValue ?? 1) == 1 }.map(\.title) ?? []
    }
}

extension EditorWindowHarness {
    /// Where File → Share's services appear (screen rect) and the window's frame.
    public var menuShareAnchor: (anchor: NSRect?, window: NSRect) {
        (controller.testMenuShareAnchorRect, controller.window?.frame ?? .zero)
    }

    /// Page count of a PDF file.
    public static func pdfPageCount(_ url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }
}

extension EditorWindowHarness {
    /// While a cell is edited: is it the picture-drawing editor, how many pictures does it show,
    /// and its text.
    public var cellPictureState: (drawsPictures: Bool, pictures: Int, text: String) {
        guard let editor = controller.window?.firstResponder as? NSTextView, editor !== controller.testCanvas.textView,
              let storage = editor.textStorage else { return (false, 0, "") }
        var count = 0
        storage.enumerateAttribute(.markaCellImage, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return (editor is CellFieldEditor, count, editor.string)
    }
}

extension EditorWindowHarness {
    /// Height of a storage row of the first table.
    public func tableRowHeight(_ row: Int) -> CGFloat { controller.testCanvas.firstTable?.height(of: row) ?? 0 }

    /// Clicking picture `index` in a cell of the first table (as the cell's field editor reports it).
    public func clickCellImage(row: Int, column: Int, index: Int = 0) {
        let canvas = controller.testCanvas
        guard let table = canvas.firstTable else { return }
        canvas.pagesTable(table, clickedImage: index, row: row, column: column, cellRect: CGRect(x: table.frame.minX, y: table.frame.minY, width: 100, height: 40))
        pump(0.2)
    }

    /// Caret in the edited cell.
    public var cellCaret: Int {
        (controller.window?.firstResponder as? NSTextView).map { $0.selectedRange().location } ?? -1
    }
}

extension EditorWindowHarness {
    public var findReplaceTextStarts: (find: CGFloat, replace: CGFloat) { controller.testFindController.testTextStarts }

    public func findPopoverSnapshot(to path: String) {
        let find = controller.testFindController
        _ = find.view
        let size = find.view.fittingSize
        PublishPopoverHarness(snapshot: PublishSnapshot(root: URL(fileURLWithPath: "/"), branch: nil, hasOrigin: false, changes: [], diffs: [:], commits: []))
            .render(find.view, size: size, to: path)
    }
}

extension EditorWindowHarness {
    /// For each code block's chip: does it have the Run-in-Terminal icon?
    public var codeRunIcons: [Bool] {
        controller.testCanvas.codeHeaders.compactMap { $0 as? CopyChipView }.map(\.showsRun)
    }
}

extension EditorWindowHarness {
    /// The link card as the window draws it (zoom included), as a PNG.
    public func linkCardScreenSnapshot(to path: String, image: Bool = false) {
        let card = image ? controller.testCanvas.imageCard : controller.testCanvas.linkCard
        guard let window = controller.window, card.superview != nil, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let rect = card.convert(card.bounds, to: content).insetBy(dx: -4, dy: -4)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return }
        content.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension EditorWindowHarness {
    /// The image card as the window server composites it (layers, Liquid Glass) — not a redraw.
    public func cardCompositedSnapshot(to path: String, image: Bool) {
        let card = image ? controller.testCanvas.imageCard : controller.testCanvas.linkCard
        guard let window = controller.window, card.superview != nil, let content = window.contentView else { return }
        window.displayIfNeeded()
        pump(0.3)
        guard let shot = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
        let scale = CGFloat(shot.width) / window.frame.width
        let inWindow = card.convert(card.bounds, to: nil)   // window coordinates, y up
        let crop = CGRect(x: (inWindow.minX - 4) * scale, y: (window.frame.height - inWindow.maxY - 4) * scale,
                          width: (inWindow.width + 8) * scale, height: (inWindow.height + 8) * scale)
        guard let cut = shot.cropping(to: crop) else { return }
        try? NSBitmapImageRep(cgImage: cut).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        _ = content
    }
}

extension FileReferenceHarness {
    /// For each card icon: image view frame, button bounds, symbol size.
    public static func cardIconFits() -> [Bool] {
        let card = LinkCardView(imageMode: true)
        card.frame = NSRect(x: 0, y: 0, width: 300, height: LinkCardView.cardHeight)
        card.layout()
        return [card.overviewButton, card.chooseButton, card.openButton, card.copyButton, card.removeButton].map { button in
            button.layoutSubtreeIfNeeded()
            let size = button.shownImage?.size ?? .zero
            return button.iconFrame == button.bounds && size.width > 0 && size.width <= button.bounds.width && size.height <= button.bounds.height
        }
    }
}

extension InsertHarness {
    /// About panel credits: text and the link it carries.
    public static var aboutCredits: (text: String, link: String?) {
        let credits = AppDelegate.aboutCredits()
        var link: String?
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { link = url.absoluteString }
        }
        return (credits.string, link)
    }
}
