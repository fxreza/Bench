import AppKit

/// Bench's entry point.
///
/// A hand-rolled `NSApplication` run rather than a SwiftUI `App`: Bench is an
/// `LSUIElement` accessory app whose only permanent UI is a status item, so
/// there is no `Scene` worth owning, and the SwiftUI lifecycle would create
/// the status item before AppKit has finished setting up the menu bar (see
/// `StatusBarController`). Ported from Transi's `App.swift`.
@main
struct BenchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        // `app.run()` never returns, but the delegate must outlive it: without
        // this the compiler is free to release it the moment `main` is
        // considered finished.
        _ = delegate
    }
}
