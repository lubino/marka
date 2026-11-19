import MarkaUI

@main
@MainActor
enum MarkaLauncher {
    static func main() {
        MarkaRuntime.start()
    }
}