import AppKit
import BenchCore
import Shot
import Klip
import Lingo
import Snap

/// Placeholder entry point until the app shell lands. Registers the four
/// features and runs the app with no UI.
@main
struct BenchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FeatureRegistry.shared.register([ShotFeature(), KlipFeature(), LingoFeature(), SnapFeature()])
        FeatureRegistry.shared.startEnabled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FeatureRegistry.shared.stopAll()
    }
}
