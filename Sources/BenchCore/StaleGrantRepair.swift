import Foundation

/// Clears a permission grant that an update left behind, so the user only
/// has to switch it back on.
///
/// macOS stores each grant with the code requirement of the build it was
/// given to. An ad-hoc signed build's requirement is its own hash, so after
/// an update the old grant still shows as on in System Settings but no longer
/// matches the running copy: macOS refuses without asking, and toggling the
/// switch does not help - the row has to be removed and the app added again.
/// Bench does that removal itself (`tccutil reset <service> <bundle id>`),
/// for the affected permission only, and then asks again, which puts Bench
/// back in the list with its switch off.
///
/// "Affected" means granted under an earlier build and refused under this
/// one. A permission the user turned off under the running build is their
/// choice and is never reset. The first update onto a build with this check
/// has no record yet; it treats every refused permission as affected, once.
public enum StaleGrantRepair {
    /// Per-Mac bookkeeping, excluded from Settings Sync by its prefix.
    static let grantedBuildKey = "bench.permissions.grantedBuild"
    static let automationBuildKey = "bench.permissions.automationWorkedBuild"

    /// The permissions whose grant can be read at launch. Automation has no
    /// preflight; it is repaired when a script is refused instead.
    static let checkedAtLaunch: [BenchPermission] = [.accessibility, .screenRecording]

    public static var currentBuild: String { "\(BenchInfo.shortVersion) (\(BenchInfo.buildNumber))" }

    /// The pure part of the launch check: which permissions are stale, and
    /// the record to store afterwards. Keyed by `BenchPermission.rawValue`;
    /// `record` is nil when none was ever stored.
    static func evaluate(
        granted: [BenchPermission: Bool], record: [String: String]?, build: String, justUpdated: Bool
    ) -> (stale: [BenchPermission], record: [String: String]) {
        var stale: [BenchPermission] = []
        var next = record ?? [:]
        for permission in checkedAtLaunch {
            let key = permission.rawValue
            if granted[permission] == true {
                next[key] = build
            } else {
                // Refused now. Stale when it was last granted under another
                // build; either way forget it, so a reset happens at most once
                // and a switch turned off on purpose is left alone next time.
                if let grantedBuild = record?[key], grantedBuild != build {
                    stale.append(permission)
                } else if record == nil, justUpdated {
                    stale.append(permission)
                }
                next[key] = nil
            }
        }
        return (stale, next)
    }

    /// Run once at launch, before anything records grants for this build.
    /// `justUpdated` is true when the updater installed this build. Resets
    /// and re-requests each stale permission and returns them, so the caller
    /// can show where to turn them back on.
    @MainActor
    @discardableResult
    public static func repairAtLaunch(
        justUpdated: Bool,
        permissions: PermissionsState = .shared, defaults: UserDefaults = BenchDefaults.standard
    ) -> [BenchPermission] {
        permissions.refresh()
        let record = defaults.dictionary(forKey: grantedBuildKey) as? [String: String]
        let result = evaluate(granted: grants(permissions), record: record, build: currentBuild, justUpdated: justUpdated)
        defaults.set(result.record, forKey: grantedBuildKey)

        for permission in result.stale {
            NSLog("[Bench] \(permission.title) grant is from an earlier build; resetting it")
            reset(permission)
            switch permission {
            case .accessibility: permissions.requestAccessibility()
            case .screenRecording: permissions.requestScreenRecording()
            case .automation: break
            }
        }
        if !result.stale.isEmpty { permissions.refresh() }
        return result.stale
    }

    /// Records the current grants under this build. Call when a grant may
    /// have been made since launch (at quit, which an update relaunch also
    /// goes through).
    @MainActor
    public static func recordGrants(
        permissions: PermissionsState = .shared, defaults: UserDefaults = BenchDefaults.standard
    ) {
        permissions.refresh()
        var record = defaults.dictionary(forKey: grantedBuildKey) as? [String: String] ?? [:]
        for (permission, granted) in grants(permissions) where granted {
            record[permission.rawValue] = currentBuild
        }
        defaults.set(record, forKey: grantedBuildKey)
    }

    // MARK: - Automation

    /// A script reached its target app: Automation works under this build.
    public static func noteAutomationWorked(defaults: UserDefaults = BenchDefaults.standard) {
        defaults.set(currentBuild, forKey: automationBuildKey)
    }

    /// Call when a script is refused (error -1743). Resets Bench's Automation
    /// grants and returns true when they were last known to work under an
    /// earlier build, so the caller can run the script once more and macOS
    /// asks again. Returns false for a refusal made under this build.
    public static func resetAutomationIfStale(defaults: UserDefaults = BenchDefaults.standard) -> Bool {
        guard let workedBuild = defaults.string(forKey: automationBuildKey),
              workedBuild != currentBuild
        else { return false }
        defaults.removeObject(forKey: automationBuildKey)
        NSLog("[Bench] Automation grants are from an earlier build; resetting them")
        reset(.automation)
        return true
    }

    // MARK: - Private

    @MainActor
    private static func grants(_ permissions: PermissionsState) -> [BenchPermission: Bool] {
        [.accessibility: permissions.accessibilityTrusted,
         .screenRecording: permissions.screenRecordingGranted]
    }

    static func tccService(_ permission: BenchPermission) -> String {
        switch permission {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "ScreenCapture"
        case .automation: return "AppleEvents"
        }
    }

    /// Removes Bench's rows for this service only. Needs no admin rights for
    /// the app's own bundle id.
    private static func reset(_ permission: BenchPermission) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", tccService(permission), BenchInfo.bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                NSLog("[Bench] tccutil reset \(tccService(permission)) exited \(process.terminationStatus)")
            }
        } catch {
            NSLog("[Bench] tccutil reset \(tccService(permission)) failed: \(error)")
        }
    }
}
