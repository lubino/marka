import Foundation

/// Output of one `git` invocation.
public struct GitResult: Sendable, Equatable {
    public var status: Int32
    public var output: String
    public var error: String
    public var command: String

    public var ok: Bool { status == 0 }

    /// Command line plus everything git printed — what the failure window's "Show more" shows.
    public var log: String {
        var text = "$ \(command)\n"
        if !output.isEmpty { text += output.hasSuffix("\n") ? output : output + "\n" }
        if !error.isEmpty { text += error.hasSuffix("\n") ? error : error + "\n" }
        if !ok { text += "(exit code \(status))\n" }
        return text
    }
}

/// One changed path from `git status --porcelain`.
public struct GitChange: Sendable, Equatable {
    /// Path relative to the repository root.
    public var path: String
    /// Two-letter porcelain code ("M ", " M", "A ", "??", …).
    public var code: String

    public init(path: String, code: String) {
        self.path = path
        self.code = code
    }

    /// Short human label: Modified, Added, Deleted, Renamed, Untracked.
    public var label: String {
        if code == "??" { return "Untracked" }
        let letters = code.replacingOccurrences(of: " ", with: "")
        switch letters.first {
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        default: return "Modified"
        }
    }
}

/// One entry of `git log`.
public struct GitCommit: Sendable, Equatable {
    public var hash: String
    public var author: String
    public var date: Date
    public var subject: String

    public init(hash: String, author: String, date: Date, subject: String) {
        self.hash = hash
        self.author = author
        self.date = date
        self.subject = subject
    }
}

/// Thin, prompt-free wrapper around the `git` command-line tool. Everything here is synchronous:
/// callers run it off the main thread.
public struct Git: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// The installed git, or nil. `/usr/bin/git` is only a stub that offers to install the Command
    /// Line Tools, so it counts only when a developer directory is selected.
    public static let installed: Git? = locate()

    static func locate() -> Git? {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return Git(executable: URL(fileURLWithPath: path))
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/git") else { return nil }
        let select = Self.launch(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], in: nil, timeout: 5)
        let developer = select.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard select.ok, !developer.isEmpty, fm.fileExists(atPath: developer) else { return nil }
        return Git(executable: URL(fileURLWithPath: "/usr/bin/git"))
    }

    // MARK: Running

    @discardableResult
    public func run(_ arguments: [String], in directory: URL, timeout: TimeInterval = 60) -> GitResult {
        Self.launch(executable, arguments, in: directory, timeout: timeout)
    }

    static func launch(_ executable: URL, _ arguments: [String], in directory: URL?, timeout: TimeInterval) -> GitResult {
        let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; credential helpers (gh, git-lfs, …) usually live in Homebrew.
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        environment["GIT_TERMINAL_PROMPT"] = "0"     // never wait for a password on a terminal
        environment["GIT_LITERAL_PATHSPECS"] = "1"   // file names are paths, not glob patterns
        environment["GIT_OPTIONAL_LOCKS"] = "0"      // status reads never block other git tools
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return GitResult(status: -1, output: "", error: error.localizedDescription, command: command)
        }
        // Drain both pipes concurrently: a large diff would otherwise fill one and deadlock.
        let errorData = PipeReader(err.fileHandleForReading)
        let timer = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let status = process.terminationReason == .uncaughtSignal ? -2 : process.terminationStatus
        var error = String(decoding: errorData.wait(), as: UTF8.self)
        if status == -2 { error += "\nTimed out after \(Int(timeout)) seconds." }
        return GitResult(status: status, output: String(decoding: outputData, as: UTF8.self), error: error, command: command)
    }

    // MARK: Queries

    /// Root of the work tree containing `file` (which need not exist yet), or nil outside a repository.
    public func repositoryRoot(containing file: URL) -> URL? {
        var directory = file.deletingLastPathComponent()
        let fm = FileManager.default
        while !fm.fileExists(atPath: directory.path), directory.path != "/" {
            directory = directory.deletingLastPathComponent()
        }
        let result = run(["rev-parse", "--show-toplevel"], in: directory, timeout: 10)
        let path = result.output.trimmingCharacters(in: .newlines)
        guard result.ok, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `file`'s path relative to `root`, with symlinks resolved on both sides (`/var` → `/private/var`).
    public static func relativePath(of file: URL, root: URL) -> String? {
        let base = realPath(root.path)
        let full = realPath(file.path)
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    /// `realpath(3)`; for a file that does not exist yet, its folder is resolved instead.
    static func realPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        guard parent != path else { return path }
        return (realPath(parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// True when git knows the file (committed or added to the index).
    public func isTracked(_ file: URL, root: URL) -> Bool {
        guard let relative = Self.relativePath(of: file, root: root) else { return false }
        return run(["ls-files", "--error-unmatch", "--", relative], in: root, timeout: 10).ok
    }

    /// Changed paths among `paths` (relative to `root`).
    public func changes(_ paths: [String], root: URL) -> [GitChange] {
        guard !paths.isEmpty else { return [] }
        let result = run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"] + paths, in: root, timeout: 20)
        return result.ok ? Self.parsePorcelain(result.output) : []
    }

    /// Unified diff of `path` against the last commit (staged and unstaged together). New files
    /// show in full.
    public func diff(_ path: String, root: URL) -> String {
        let hasHead = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root, timeout: 10).ok
        let base = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff"]
        if hasHead {
            let result = run(base + ["HEAD", "--", path], in: root, timeout: 20)
            if !result.output.isEmpty { return result.output }
        } else {
            let result = run(base + ["--cached", "--", path], in: root, timeout: 20)
            if !result.output.isEmpty { return result.output }
        }
        // Untracked: compare with nothing (exit code 1 means "differs").
        return run(base + ["--no-index", "--", "/dev/null", path], in: root, timeout: 20).output
    }

    /// The last `count` commits of the current branch (empty in a repository without commits).
    public func recentCommits(root: URL, count: Int = 3) -> [GitCommit] {
        let result = run(["log", "-\(count)", "--format=%H%x1f%an%x1f%at%x1f%s%x1e"], in: root, timeout: 10)
        return result.ok ? Self.parseLog(result.output) : []
    }

    public func hasOrigin(root: URL) -> Bool {
        run(["remote", "get-url", "origin"], in: root, timeout: 10).ok
    }

    /// Current branch name, or nil on a detached HEAD.
    public func currentBranch(root: URL) -> String? {
        let result = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root, timeout: 10)
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !name.isEmpty ? name : nil
    }

    // MARK: Changes

    @discardableResult
    public func add(_ paths: [String], root: URL) -> GitResult {
        run(["add", "--"] + paths, in: root, timeout: 30)
    }

    /// Commits exactly `paths` (other staged work stays staged).
    public func commit(message: String, paths: [String], root: URL) -> GitResult {
        run(["commit", "--only", "-m", message, "--"] + paths, in: root, timeout: 120)
    }

    /// Pushes the current branch; sets `origin` as upstream on the first push.
    public func push(root: URL) -> GitResult {
        let upstream = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root, timeout: 10)
        if upstream.ok {
            return run(["push"], in: root, timeout: 120)
        }
        return run(["push", "--set-upstream", "origin", "HEAD"], in: root, timeout: 120)
    }

    // MARK: Published updates

    /// The branch's upstream ("origin/main"), or nil when none is configured.
    public func upstream(root: URL) -> String? {
        let result = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root, timeout: 10)
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !name.isEmpty ? name : nil
    }

    /// Downloads the upstream's new commits (no merge). Network: short timeout, never prompts.
    @discardableResult
    public func fetch(root: URL) -> GitResult {
        run(["fetch", "--quiet"], in: root, timeout: 30)
    }

    /// Upstream commits not in HEAD that change `path` (newest first).
    public func incomingCommits(path: String, root: URL, count: Int = 20) -> [GitCommit] {
        let result = run(["log", "-\(count)", "--format=%H%x1f%an%x1f%at%x1f%s%x1e", "HEAD..@{u}", "--", path], in: root, timeout: 10)
        return result.ok ? Self.parseLog(result.output) : []
    }

    /// Fast-forwards the branch to its upstream (`git pull --ff-only` after a fetch). Refuses when
    /// local commits diverge or local edits would be overwritten.
    public func fastForward(root: URL) -> GitResult {
        run(["merge", "--ff-only", "@{u}"], in: root, timeout: 60)
    }

    // MARK: Parsing

    /// Parses `git status --porcelain=v1 -z`. Renames carry the old path as an extra entry, skipped.
    public static func parsePorcelain(_ text: String) -> [GitChange] {
        var changes: [GitChange] = []
        var entries = text.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            changes.append(GitChange(path: String(entry.dropFirst(3)), code: code))
            if code.contains("R") || code.contains("C") { _ = entries.next() }
        }
        return changes
    }

    /// Parses `git log --format=%H%x1f%an%x1f%at%x1f%s%x1e`.
    public static func parseLog(_ text: String) -> [GitCommit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard fields.count >= 4, let seconds = TimeInterval(fields[2]) else { return nil }
            return GitCommit(hash: fields[0], author: fields[1], date: Date(timeIntervalSince1970: seconds), subject: fields[3])
        }
    }
}

/// Reads a pipe to its end on a background thread.
private final class PipeReader: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}

/// A newer published version of an open file: the upstream commits that changed it.
public struct PublishedUpdate: Sendable, Equatable {
    public var root: URL
    public var path: String
    public var upstream: String
    public var commits: [GitCommit]

    public init(root: URL, path: String, upstream: String, commits: [GitCommit]) {
        self.root = root
        self.path = path
        self.upstream = upstream
        self.commits = commits
    }
}

public enum GitUpdater {
    /// Fetches and reports upstream commits that change `file`; nil when the file is untracked,
    /// the branch has no upstream, the fetch fails (offline) or the file is up to date.
    public static func check(git: Git, file: URL) -> PublishedUpdate? {
        guard let root = git.repositoryRoot(containing: file),
              let path = Git.relativePath(of: file, root: root),
              git.isTracked(file, root: root),
              let upstream = git.upstream(root: root),
              git.fetch(root: root).ok else { return nil }
        let commits = git.incomingCommits(path: path, root: root)
        return commits.isEmpty ? nil : PublishedUpdate(root: root, path: path, upstream: upstream, commits: commits)
    }

    /// Brings the work tree up to the upstream (fast-forward only).
    public static func update(git: Git, root: URL) -> GitResult {
        git.fastForward(root: root)
    }
}

/// Everything the Publish popover shows, gathered off the main thread.
public struct PublishSnapshot: Sendable {
    public var root: URL
    public var branch: String?
    public var hasOrigin: Bool
    /// Changed files among the candidates (relative paths).
    public var changes: [GitChange]
    /// Diff per changed path.
    public var diffs: [String: String]
    public var commits: [GitCommit]

    public init(root: URL, branch: String?, hasOrigin: Bool, changes: [GitChange], diffs: [String: String], commits: [GitCommit]) {
        self.root = root
        self.branch = branch
        self.hasOrigin = hasOrigin
        self.changes = changes
        self.diffs = diffs
        self.commits = commits
    }

    public var repositoryName: String { root.lastPathComponent }
}

/// What a Publish run ended with. Every case carries the full git log.
public enum PublishOutcome: Sendable, Equatable {
    case pushed(log: String)
    case committedOnly(log: String)
    case commitFailed(log: String)
    case pushFailed(log: String)

    public var log: String {
        switch self {
        case .pushed(let log), .committedOnly(let log), .commitFailed(let log), .pushFailed(let log): return log
        }
    }

    public var succeeded: Bool {
        switch self {
        case .pushed, .committedOnly: return true
        case .commitFailed, .pushFailed: return false
        }
    }
}

/// Publish = commit the given files, then push when the repository has an `origin` remote.
public enum GitPublisher {
    public static func snapshot(git: Git, root: URL, files: [URL]) -> PublishSnapshot {
        let paths = uniquePaths(files, root: root)
        let changes = git.changes(paths, root: root)
        var diffs: [String: String] = [:]
        for change in changes { diffs[change.path] = git.diff(change.path, root: root) }
        return PublishSnapshot(
            root: root,
            branch: git.currentBranch(root: root),
            hasOrigin: git.hasOrigin(root: root),
            changes: changes,
            diffs: diffs,
            commits: git.recentCommits(root: root)
        )
    }

    public static func publish(git: Git, root: URL, paths: [String], message: String) -> PublishOutcome {
        var log = ""
        let add = git.add(paths, root: root)
        log += add.log
        guard add.ok else { return .commitFailed(log: log) }
        let commit = git.commit(message: message, paths: paths, root: root)
        log += commit.log
        guard commit.ok else { return .commitFailed(log: log) }
        guard git.hasOrigin(root: root) else { return .committedOnly(log: log) }
        let push = git.push(root: root)
        log += push.log
        return push.ok ? .pushed(log: log) : .pushFailed(log: log)
    }

    /// `git add`s the files among `files` that lie inside the work tree at `root` and are not
    /// tracked yet; returns their relative paths. Ignored paths stay ignored (`git add` refuses
    /// them), files outside the work tree are left alone.
    @discardableResult
    public static func trackLinkedFiles(git: Git, root: URL, files: [URL]) -> [String] {
        let fm = FileManager.default
        let untracked = uniquePaths(files.filter { fm.fileExists(atPath: $0.path) }, root: root).filter { path in
            !git.isTracked(root.appendingPathComponent(path), root: root)
        }
        // One add per file: a single ignored path would make a combined `git add` add nothing.
        return untracked.filter { git.add([$0], root: root).ok }
    }

    static func uniquePaths(_ files: [URL], root: URL) -> [String] {
        var seen = Set<String>()
        return files.compactMap { Git.relativePath(of: $0, root: root) }.filter { seen.insert($0).inserted }
    }

    /// Added / removed line counts of a unified diff (file headers excluded).
    public static func lineCounts(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }

    /// A ready-to-edit default message: "Update README.md" or "Update 3 files".
    public static func suggestedMessage(for changes: [GitChange]) -> String {
        guard let first = changes.first else { return "" }
        let verb = changes.allSatisfy { $0.label == "Added" || $0.label == "Untracked" } ? "Add" : "Update"
        if changes.count == 1 { return "\(verb) \((first.path as NSString).lastPathComponent)" }
        return "\(verb) \(changes.count) files"
    }
}
