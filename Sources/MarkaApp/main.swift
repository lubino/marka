import AppKit

@main
enum MarkaMain {
    static func main() {
        let _ = MarkaDocumentController.shared
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate as NSApplicationDelegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
