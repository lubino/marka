import AppKit
import MarkaCore

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    var codec = FileCodec()
    var loadedString = ""
    var loadedData: Data?
    var pendingString: String?
    /// The bytes Marka believes are on disk (read, written or accepted); the file watcher ignores
    /// events whose file still matches them, so Marka's own saves never reload.
    private var knownDiskData: Data?
    private var watcher: FileWatcher?
    private var isAskingAboutExternalChange = false

    /// Settings → Autosave. Off: edits are saved only with ⌘S (closing asks).
    override class var autosavesInPlace: Bool { SettingsStore.shared.current.autosave }

    override class var readableTypes: [String] {
        [
            "Markdown Document",
            "net.daringfireball.markdown",
            "public.markdown",
            "public.plain-text",
            "public.utf8-plain-text",
            "public.text"
        ]
    }

    override class var writableTypes: [String] {
        ["Markdown Document", "net.daringfireball.markdown"]
    }

    override class func isNativeType(_ type: String) -> Bool {
        readableTypes.contains(type)
    }

    override func makeWindowControllers() {
        MainActor.assumeIsolated {
            let controller = DocumentWindowController()
            addWindowController(controller)
            controller.bind(document: self)
            if let pendingString {
                controller.setMarkdown(pendingString)
                self.pendingString = nil
            } else {
                controller.setMarkdown("")
            }
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        let current = editorString()
        let data = codec.encode(normalized: current, originalNormalized: loadedString, originalData: loadedData)
        knownDiskData = data
        return data
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = FileCodec.decode(data)
        let applyOnMain = {
            MainActor.assumeIsolated {
                self.codec = decoded.codec
                self.loadedString = decoded.normalized
                self.loadedData = data
                self.knownDiskData = data
                self.pendingString = decoded.normalized
                if let controller = self.windowControllers.first as? DocumentWindowController {
                    controller.setMarkdown(decoded.normalized)
                    self.pendingString = nil
                }
            }
        }
        if Thread.isMainThread {
            applyOnMain()
        } else {
            DispatchQueue.main.sync(execute: applyOnMain)
        }
    }

    // MARK: Watching the file

    override var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            performSelector(onMainThread: #selector(restartWatching), with: nil, waitUntilDone: false)
        }
    }

    @objc private func restartWatching() {
        MainActor.assumeIsolated { watchFile() }
    }

    override func close() {
        MainActor.assumeIsolated {
            watcher?.stop()
            watcher = nil
        }
        super.close()
    }

    @MainActor
    func watchFile() {
        watcher?.stop()
        watcher = nil
        guard let url = fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in self?.checkForExternalChange() }
    }

    /// Called when the file changed on disk (watcher) or the window became active. Marka's own
    /// saves are recognised by their bytes; anything else is loaded (Settings → Auto-load; `force`
    /// loads even with auto-load off — after Marka itself updated the file from git).
    @MainActor
    func checkForExternalChange(force: Bool = false) {
        guard force || SettingsStore.shared.current.autoload, !isAskingAboutExternalChange,
              let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let diskDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if data == knownDiskData {
            if let diskDate { fileModificationDate = diskDate }
            return
        }
        let decoded = FileCodec.decode(data)
        let accept = {
            self.codec = decoded.codec
            self.loadedString = decoded.normalized
            self.loadedData = data
            self.knownDiskData = data
            if let diskDate { self.fileModificationDate = diskDate }
        }
        if decoded.normalized == editorString() {
            accept()
            return
        }
        guard let controller = windowControllers.first as? DocumentWindowController else { return }
        if !isDocumentEdited {
            accept()
            reload(decoded.normalized, in: controller)
            return
        }
        // Unsaved edits in Marka and a different file on disk: let the user pick.
        guard let window = controller.window else { return }
        isAskingAboutExternalChange = true
        let alert = NSAlert()
        alert.messageText = "“\(displayName ?? url.lastPathComponent)” was changed by another app."
        alert.informativeText = "You also have unsaved changes in Marka. Load the version on disk, or keep yours (it replaces the file on the next save)?"
        alert.addButton(withTitle: "Load from Disk")
        alert.addButton(withTitle: "Keep Mine")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                self.isAskingAboutExternalChange = false
                if response == .alertFirstButtonReturn {
                    accept()
                    self.reload(decoded.normalized, in: controller)
                } else {
                    // Keep: our next save overwrites without AppKit's "changed by another app" alert.
                    if let diskDate { self.fileModificationDate = diskDate }
                }
            }
        }
    }

    /// The reload is one undoable edit; NSDocument counts it as a change when the undo group
    /// closes (after this run-loop turn), so the clean state is restored on the next turn.
    @MainActor
    private func reload(_ text: String, in controller: DocumentWindowController) {
        controller.reloadMarkdown(text)
        updateChangeCount(.changeCleared)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.editorString() == self.loadedString else { return }
                self.updateChangeCount(.changeCleared)
            }
        }
    }

    // MARK: Git

    /// A document saved to a new file inside a git work tree is added to git.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let isNew = saveOperation == .saveAsOperation && !FileManager.default.fileExists(atPath: url.path)
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            completionHandler(error)
            guard error == nil, isNew else { return }
            MainActor.assumeIsolated {
                GitService.addNewFile(url) { [weak self] in
                    (self?.windowControllers.first as? DocumentWindowController)?.refreshGitState()
                }
            }
        }
    }

    /// Saves pending edits to the file (Publish commits what is on disk).
    @MainActor
    func saveForPublish(_ completion: @escaping @MainActor () -> Void) {
        guard isDocumentEdited, let url = fileURL, let type = fileType else {
            completion()
            return
        }
        save(to: url, ofType: type, for: .saveOperation) { _ in
            MainActor.assumeIsolated { completion() }
        }
    }

    /// File → Print… / toolbar Print: AppKit shows the standard print sheet on the document window.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let controller = windowControllers.first as? DocumentWindowController else {
            throw CocoaError(.featureUnsupported)
        }
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        return MainActor.assumeIsolated { controller.makePrintOperation(printInfo: info) }
    }

    func editorString() -> String {
        (windowControllers.first as? DocumentWindowController)?.markdownString() ?? pendingString ?? loadedString
    }

    func noteEditorChanged() {
        updateChangeCount(.changeDone)
        if let current = (windowControllers.first as? DocumentWindowController)?.markdownString(),
           current == loadedString {
            updateChangeCount(.changeCleared)
        }
    }
}
