import AppKit
import MarkaCore

final class MarkdownDocument: NSDocument {
    var codec = FileCodec()
    var loadedString = ""
    var loadedData: Data?
    var pendingString: String?

    override class var autosavesInPlace: Bool { true }

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
        codec = decoded.codec
        loadedString = decoded.normalized
        loadedData = data
        pendingString = decoded.normalized
        MainActor.assumeIsolated {
            if let controller = windowControllers.first as? DocumentWindowController {
                controller.setMarkdown(decoded.normalized)
                pendingString = nil
            }
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
