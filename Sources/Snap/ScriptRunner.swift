import AppKit

/// Runs the two user-editable AppleScripts.
///
/// `NSAppleScript.executeAndReturnError` blocks until the target app answers,
/// and "make a new Terminal window" can take a second on a cold launch, so it
/// never runs on the main thread: the hotkey must return immediately or the
/// whole menu bar stutters. The result comes back on the main actor.
///
/// The first run against each target app raises the system Automation
/// prompt; that is the `.automation` permission Snap declares. A refusal
/// arrives as error -1743 and is reported like any other script error.
enum ScriptRunner {
    /// Runs `source`, calling `completion` on the main actor with a
    /// human-readable error message, or nil on success.
    nonisolated static func run(_ source: String, completion: (@Sendable @MainActor (String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let message = runSynchronously(source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion?(message) }
            }
        }
    }

    /// The blocking call, kept separate so nothing on the main thread can
    /// reach it by accident. Returns nil on success.
    nonisolated static func runSynchronously(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            return "The script could not be compiled."
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        let message = errorInfo[NSAppleScript.errorMessage] as? String
        let number = errorInfo[NSAppleScript.errorNumber] as? Int
        switch (message, number) {
        case let (message?, number?): return "\(message) (error \(number))"
        case let (message?, nil): return message
        case let (nil, number?): return "AppleScript failed with error \(number)."
        default: return "AppleScript failed."
        }
    }
}
