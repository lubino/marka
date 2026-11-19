import Foundation

/// Writes a temporary `.command` file and opens it in Terminal.app.
public enum ShellRunner {
    public static let languages: Set<String> = ["sh", "bash", "zsh", "shell", "fish", "ksh"]

    public static func isShell(_ language: String?) -> Bool {
        guard let language, !language.isEmpty else { return false }
        return languages.contains(language.lowercased())
    }

    public static func escapePath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func commandFileContents(script: String, workingDirectory: String?) -> String {
        var lines = ["#!/bin/zsh", "set +e"]
        if let workingDirectory, !workingDirectory.isEmpty {
            lines.append("cd \(escapePath(workingDirectory))")
        }
        lines.append(script)
        lines.append("")
        lines.append("echo")
        lines.append("print -n 'Press Return to close. '")
        lines.append("read")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func writeCommandFile(script: String, workingDirectory: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marka-\(UUID().uuidString).command")
        let body = commandFileContents(script: script, workingDirectory: workingDirectory)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    public static func run(_ script: String, workingDirectory: URL?) {
        guard let file = try? writeCommandFile(script: script, workingDirectory: workingDirectory?.path) else {
            return
        }
        openInTerminal(file)
    }

    public static func openInTerminal(_ file: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", file.path]
        try? process.run()
    }
}
