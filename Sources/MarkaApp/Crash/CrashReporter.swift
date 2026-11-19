import AppKit
import Darwin

/// Local crash logs under `~/Library/Logs/Marka`. No third-party telemetry.
public enum CrashReporter {
    private static let pathCapacity = 1024
    nonisolated(unsafe) private static var logPath = [CChar](repeating: 0, count: pathCapacity)
    nonisolated(unsafe) private static var installed = false

    public static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Marka", isDirectory: true)
    }

    public static var pendingFlagURL: URL {
        logsDirectory.appendingPathComponent("pending.flag")
    }

    public static func install() {
        guard !installed else { return }
        installed = true
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        refreshLogPath()
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.record(exception: exception)
        }
        let handled: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP]
        for sig in handled {
            signal(sig, markaCrashSignal)
        }
    }

    @MainActor
    public static func presentPendingReportIfNeeded() {
        guard FileManager.default.fileExists(atPath: pendingFlagURL.path) else { return }
        try? FileManager.default.removeItem(at: pendingFlagURL)
        let report = latestReport()
        let alert = NSAlert()
        alert.messageText = "Marka closed unexpectedly"
        alert.informativeText = report.map {
            "A crash log was saved to:\n\($0.path)\n\nYou can attach this file when reporting the issue."
        } ?? "A crash log was saved in ~/Library/Logs/Marka."
        alert.addButton(withTitle: "Show Log")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let report {
            NSWorkspace.shared.activateFileViewerSelecting([report])
        }
    }

    public static func latestReport() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    public static func writeDiagnostic(title: String, body: String) -> URL {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let name = "crash-\(Self.stamp()).log"
        let url = logsDirectory.appendingPathComponent(name)
        let text = """
        Marka crash report
        Time: \(ISO8601DateFormatter().string(from: Date()))
        \(title)

        \(body)
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: pendingFlagURL.path, contents: nil)
        return url
    }

    static func record(exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        _ = writeDiagnostic(
            title: "Uncaught exception: \(exception.name.rawValue)",
            body: "Reason: \(exception.reason ?? "")\n\n\(stack)"
        )
    }

    nonisolated(unsafe) private static var flagPath = [CChar](repeating: 0, count: pathCapacity)

    static func recordSignal(_ sig: Int32) {
        let fd = logPath.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return open(base, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard fd >= 0 else { return }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, 64)
        let header: StaticString
        switch sig {
        case SIGABRT: header = "Marka crash report\nSignal: SIGABRT\n"
        case SIGILL: header = "Marka crash report\nSignal: SIGILL\n"
        case SIGSEGV: header = "Marka crash report\nSignal: SIGSEGV\n"
        case SIGFPE: header = "Marka crash report\nSignal: SIGFPE\n"
        case SIGBUS: header = "Marka crash report\nSignal: SIGBUS\n"
        case SIGTRAP: header = "Marka crash report\nSignal: SIGTRAP\n"
        default: header = "Marka crash report\nSignal: unknown\n"
        }
        header.withUTF8Buffer { buf in
            if let base = buf.baseAddress {
                _ = write(fd, base, buf.count)
            }
        }
        if let symbols = backtrace_symbols(&frames, count) {
            for i in 0..<Int(count) {
                if let line = symbols[i] {
                    _ = write(fd, line, strlen(line))
                    _ = write(fd, "\n", 1)
                }
            }
            free(symbols)
        }
        close(fd)
        let flagFd = flagPath.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return open(base, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        if flagFd >= 0 { close(flagFd) }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func refreshLogPath() {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let url = logsDirectory.appendingPathComponent("crash-\(stamp()).log")
        url.path.withCString { src in
            logPath.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                strncpy(base, src, pathCapacity - 1)
                base[pathCapacity - 1] = 0
            }
        }
        pendingFlagURL.path.withCString { src in
            flagPath.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                strncpy(base, src, pathCapacity - 1)
                base[pathCapacity - 1] = 0
            }
        }
    }
}

private let markaCrashSignal: @convention(c) (Int32) -> Void = { sig in
    CrashReporter.recordSignal(sig)
    signal(sig, SIG_DFL)
    raise(sig)
}
