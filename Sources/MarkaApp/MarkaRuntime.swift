import AppKit

@MainActor
public enum MarkaRuntime {
    public static func start() {
        CrashReporter.install()
        let _ = MarkaDocumentController.shared
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate as NSApplicationDelegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
