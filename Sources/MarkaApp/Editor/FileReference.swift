import AppKit
import MarkaCore

/// How a picked or dropped file (image or link target) becomes a path in the Markdown.
///
/// A file inside the document's *home* — its git work tree when the document is tracked,
/// otherwise its folder — is referenced relatively (and starts being tracked by git if it is
/// not yet). A file outside asks: copy it next to the document (editable name), or link to the
/// original location, which breaks on other computers.
@MainActor
enum FileReference {
    enum Kind { case image, link }

    enum Decision: Equatable {
        /// Use this Markdown path as is.
        case inside(String)
        /// Outside the home folder: ask, suggesting this name (relative to the document folder).
        case outside(suggestedName: String)
        /// Untitled document: nothing to be relative to.
        case absolute(String)
    }

    static func decide(_ file: URL, kind: Kind, documentDirectory: URL?, trackedRoot: URL?) -> Decision {
        guard let directory = documentDirectory else { return .absolute(markdownPath(file.path)) }
        let home = trackedRoot ?? directory
        if isInside(file, folder: home) {
            return .inside(relativeMarkdownPath(of: file, from: directory))
        }
        let name = file.lastPathComponent
        return .outside(suggestedName: kind == .image ? "assets/\(name)" : name)
    }

    /// Resolves `file` to a Markdown path, asking when needed; `completion(nil)` means cancelled.
    static func resolve(_ file: URL, kind: Kind, documentDirectory: URL?, trackedRoot: URL?,
                        window: NSWindow?, completion: @escaping (String?) -> Void) {
        switch decide(file, kind: kind, documentDirectory: documentDirectory, trackedRoot: trackedRoot) {
        case .absolute(let path):
            completion(path)
        case .inside(let path):
            if trackedRoot != nil { GitService.trackIfNeeded(file) }
            completion(path)
        case .outside(let suggested):
            guard let directory = documentDirectory else { return completion(nil) }
            ask(file: file, kind: kind, suggestedName: suggested, inRepository: trackedRoot != nil, window: window) { choice in
                switch choice {
                case .cancel:
                    completion(nil)
                case .original:
                    completion(markdownPath(file.path))
                case .copy(let name):
                    do {
                        let copy = try copyFile(file, named: name, into: directory)
                        GitService.addNewFile(copy)
                        completion(relativeMarkdownPath(of: copy, from: directory))
                    } catch {
                        NSApp.presentError(error)
                        completion(nil)
                    }
                }
            }
        }
    }

    // MARK: Asking

    enum Choice: Equatable {
        case copy(String)
        case original
        case cancel
    }

    static func makeAlert(file: URL, kind: Kind, suggestedName: String, inRepository: Bool) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        let what = kind == .image ? "image" : "file"
        alert.messageText = "“\(file.lastPathComponent)” is outside this document’s \(inRepository ? "repository" : "folder")"
        alert.informativeText = "Copy the \(what) next to the document so it travels with it\(inRepository ? " and is published with it" : ""), or keep a reference to its original location.\n\n⚠︎ A reference outside the \(inRepository ? "repository" : "document’s folder") only works on this Mac — the \(kind == .image ? "image" : "link") breaks on other computers\(inRepository ? " and for everyone the document is published to" : "")."
        alert.addButton(withTitle: "Copy \(kind == .image ? "Image" : "File")")
        alert.addButton(withTitle: "Use Original Location")
        alert.addButton(withTitle: "Cancel")
        let label = NSTextField(labelWithString: "Save the copy as:")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let field = NSTextField(string: suggestedName)
        field.placeholderString = file.lastPathComponent
        field.toolTip = "Path relative to the document’s folder"
        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    private static func ask(file: URL, kind: Kind, suggestedName: String, inRepository: Bool,
                            window: NSWindow?, completion: @escaping (Choice) -> Void) {
        let (alert, field) = makeAlert(file: file, kind: kind, suggestedName: suggestedName, inRepository: inRepository)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.copy(name.isEmpty ? suggestedName : name))
            case .alertSecondButtonReturn:
                completion(.original)
            default:
                completion(.cancel)
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            finish(alert.runModal())
        }
    }

    // MARK: Paths and copies

    /// True when `file` lies inside `folder` (symlinks resolved).
    static func isInside(_ file: URL, folder: URL) -> Bool {
        Git.relativePath(of: file, root: folder) != nil
    }

    /// `file` relative to `directory` (`assets/a.png`, `../docs/b.md`), escaped for Markdown.
    static func relativeMarkdownPath(of file: URL, from directory: URL) -> String {
        let target = URL(fileURLWithPath: realPath(file.path)).standardizedFileURL.pathComponents
        let base = URL(fileURLWithPath: realPath(directory.path)).standardizedFileURL.pathComponents
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] { common += 1 }
        let ups = Array(repeating: "..", count: base.count - common)
        return markdownPath((ups + target[common...]).joined(separator: "/"))
    }

    /// Escapes the characters that end or break a Markdown link destination.
    static func markdownPath(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    /// Copies `file` to `name` (relative to `directory`, folders created). An identical file
    /// already there is reused; a different one keeps both (`name-1.ext`). Never overwrites.
    static func copyFile(_ file: URL, named name: String, into directory: URL) throws -> URL {
        // Keep the copy inside the document's folder: no absolute paths, no "..".
        let parts = name.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let relative = parts.isEmpty ? file.lastPathComponent : parts.joined(separator: "/")
        var destination = directory.appendingPathComponent(relative)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stem = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var counter = 1
        while fm.fileExists(atPath: destination.path) {
            if fm.contentsEqual(atPath: destination.path, andPath: file.path) { return destination }
            let next = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            destination = destination.deletingLastPathComponent().appendingPathComponent(next)
            counter += 1
        }
        try fm.copyItem(at: file, to: destination)
        return destination
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
