import Foundation

/// Writes a temporary `.command` file and opens it in Terminal.app. Shell fences run as zsh
/// script; Python fences are saved as a `.py` file and run with `python3` (so `input()` works).
public enum ShellRunner {
    public static let languages: Set<String> = ["sh", "bash", "zsh", "shell", "fish", "ksh"]
    public static let pythonLanguages: Set<String> = ["python", "python3", "py"]

    public static func isPython(_ language: String?) -> Bool {
        guard let language, !language.isEmpty else { return false }
        return pythonLanguages.contains(language.lowercased())
    }

    /// Code blocks with a Run-in-Terminal icon.
    public static func isRunnable(_ language: String?) -> Bool { isShell(language) || isPython(language) }

    public static func isShell(_ language: String?) -> Bool {
        guard let language, !language.isEmpty else { return false }
        return languages.contains(language.lowercased())
    }

    public static func escapePath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `.command` file: removes itself (and `cleanup` files, e.g. the `.py`) when it ends,
    /// runs `script` in `workingDirectory`, and — only with `waitForKey` (Settings) — shows whether
    /// it succeeded and waits for any key. Without it Terminal keeps the window and its output
    /// ("[Process completed]") anyway.
    public static func commandFileContents(script: String, workingDirectory: String?, waitForKey: Bool = false,
                                           cleanup: [String] = []) -> String {
        var lines = ["#!/bin/zsh"]
        let remove = (["\"$0\""] + cleanup.map(escapePath)).joined(separator: " ")
        lines.append("trap 'rm -f -- \(remove.replacingOccurrences(of: "'", with: "'\\''"))' EXIT")
        if let workingDirectory, !workingDirectory.isEmpty {
            lines.append("cd \(escapePath(workingDirectory)) || exit 1")
        }
        lines.append(script)
        if waitForKey {
            lines += [
                "marka_status=$?",
                "print",
                "if (( marka_status == 0 )); then",
                "  print -P '%F{green}✓ Finished%f'",
                "else",
                "  print -P \"%F{red}✗ Exited with code $marka_status%f\"",
                "fi",
                "print -n 'Press any key to close… '",
                "read -rs -k 1",
                "print",
                "exit $marka_status"
            ]
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func writeCommandFile(script: String, workingDirectory: String?, language: String? = nil,
                                        waitForKey: Bool = false) throws -> URL {
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marka-\(id).command")
        var command = script
        var cleanup: [String] = []
        if isPython(language) {
            let python = FileManager.default.temporaryDirectory.appendingPathComponent("marka-\(id).py")
            try script.write(to: python, atomically: true, encoding: .utf8)
            command = "python3 \(escapePath(python.path))"
            cleanup.append(python.path)
        }
        let body = commandFileContents(script: command, workingDirectory: workingDirectory, waitForKey: waitForKey, cleanup: cleanup)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    public static func run(_ script: String, language: String? = nil, workingDirectory: URL?) {
        let wait = SettingsStore.shared.current.waitAfterScript
        guard let file = try? writeCommandFile(script: script, workingDirectory: workingDirectory?.path, language: language, waitForKey: wait) else {
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
