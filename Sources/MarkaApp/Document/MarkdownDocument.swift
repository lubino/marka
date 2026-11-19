import AppKit
import MarkaCore

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    var codec = FileCodec()
    var loadedString = ""
    var loadedData: Data?
    var pendingString: String?

    override class var autosavesInPlace: Bool { true }

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
        return codec.encode(normalized: current, originalNormalized: loadedString, originalData: loadedData)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = FileCodec.decode(data)
        let applyOnMain = {
            MainActor.assumeIsolated {
                self.codec = decoded.codec
                self.loadedString = decoded.normalized
                self.loadedData = data
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
