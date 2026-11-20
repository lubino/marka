import Foundation
import MarkaUI

@main
@MainActor
enum MarkaLauncher {
    static func main() {
        // `Marka -pdf in.md out.pdf` (and --help) run without the app's UI.
        if let code = MarkaCommandLine.run(CommandLine.arguments) { exit(code) }
        MarkaRuntime.start()
    }
}