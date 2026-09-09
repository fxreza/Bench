import Foundation

/// Finds a SwiftPM module resource bundle without trapping.
///
/// SwiftPM's generated `Bundle.module` resolves against
/// `Bundle.main.bundleURL` and then an absolute build-directory path baked in
/// at compile time, and calls `fatalError` when neither matches. Inside a
/// packaged `.app` the first candidate is the bundle root - not
/// `Contents/Resources`, which is where `scripts/build-app.sh` puts the module
/// bundles - so the only candidate that ever resolves is the build directory
/// on the machine that compiled the app. Every other Mac gets the trap: Piko
/// took the whole app down at launch that way on a second machine, from
/// `MediaRemoteAdapter.paths`.
///
/// `Bundle.main.resourceURL` is `Contents/Resources` inside a `.app` and the
/// executable's own directory for `swift run` and the test runners, so it
/// covers both layouts. Returning nil instead of trapping lets a caller turn
/// one missing resource into one disabled feature.
public enum ResourceBundle {
    /// The module bundle with `name` (for example `Bench_Piko`), or nil when
    /// it is not next to the running executable's resources.
    public static func named(_ name: String) -> Bundle? {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for base in candidates.compactMap({ $0 }) {
            let url = base.appendingPathComponent("\(name).bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }
}
