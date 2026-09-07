import Foundation

/// Facts about the app that more than one module needs and that must agree
/// everywhere: the bundle identifier, where the app is installed, and where
/// it lives on GitHub.
public enum BenchInfo {
    public static let appName = "Bench"
    public static let bundleIdentifier = "com.fxreza.bench"
    public static let installDestination = "/Applications/Bench.app"
    public static let repositoryURL = URL(string: "https://github.com/fxreza/Bench")!
    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/fxreza/Bench/releases")!

    public static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    public static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
