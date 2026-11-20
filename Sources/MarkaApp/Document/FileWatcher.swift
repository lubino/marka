import Foundation
import MarkaCore

/// Watches one file for changes made by any process (kqueue vnode events, main queue).
/// Many editors and git save by writing a new file and renaming it over the old one, which ends
/// the watch on the old inode — so a delete / rename re-arms on the same path.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var rearmAttempts = 0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    private func arm() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file is being replaced; try again shortly (for ~3 s).
            rearmAttempts += 1
            if rearmAttempts <= 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
            }
            return
        }
        let wasReplaced = rearmAttempts > 0 || source != nil
        rearmAttempts = 0
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                let event = source.data
                if event.contains(.delete) || event.contains(.rename) {
                    source.cancel()
                    self.source = nil
                    self.arm()
                }
                self.scheduleChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        if wasReplaced { scheduleChange() }
    }

    /// Coalesces the burst of events one save produces.
    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}

/// Runs git work for the UI on one serial background queue, so actions stay in order
/// (a new file is added before the Publish state of its document is checked).
@MainActor
enum GitService {
    nonisolated static let queue = DispatchQueue(label: "sk.lubino.marka.git", qos: .userInitiated)
    /// Network work (fetch) runs here, so a slow server never delays Publish or file adds.
    nonisolated static let networkQueue = DispatchQueue(label: "sk.lubino.marka.git.network", qos: .utility)

    /// Adds a file Marka just created to git, when it lies inside a work tree (ignored paths fail
    /// quietly in `git add`).
    static func addNewFile(_ url: URL, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard SettingsStore.shared.current.gitEnabled, let git = Git.installed else { return }
        queue.async {
            if let root = git.repositoryRoot(containing: url), let path = Git.relativePath(of: url, root: root) {
                git.add([path], root: root)
                NewFiles.shared.insert(url)
            }
            if let completion { DispatchQueue.main.async { MainActor.assumeIsolated { completion() } } }
        }
    }

    /// Starts tracking an existing file inside a work tree when git does not track it yet (a
    /// tracked file is left alone — `git add` would stage its edits).
    static func trackIfNeeded(_ url: URL) {
        guard SettingsStore.shared.current.gitEnabled, let git = Git.installed else { return }
        queue.async {
            guard let root = git.repositoryRoot(containing: url), !git.isTracked(url, root: root),
                  let path = Git.relativePath(of: url, root: root) else { return }
            if git.add([path], root: root).ok { NewFiles.shared.insert(url) }
        }
    }

    /// Repository root of `url` when git tracks the file; nil otherwise.
    static func trackedRoot(of url: URL, completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard SettingsStore.shared.current.gitEnabled, let git = Git.installed else {
            completion(nil)
            return
        }
        queue.async {
            var tracked: URL?
            if let root = git.repositoryRoot(containing: url), git.isTracked(url, root: root) { tracked = root }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(tracked) } }
        }
    }
}

/// Files Marka created and added to git in this session (images, link-created documents); Publish
/// commits them with the open documents of the same repository.
final class NewFiles: @unchecked Sendable {
    static let shared = NewFiles()
    private let lock = NSLock()
    private var urls: [URL] = []

    func insert(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if !urls.contains(url) { urls.append(url) }
    }

    func all() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
