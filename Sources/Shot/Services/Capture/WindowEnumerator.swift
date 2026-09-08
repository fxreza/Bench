import AppKit
import CoreGraphics

/// One on-screen window as reported by the window server.
///
/// `frame` is already converted to **global AppKit coordinates**: points, with
/// the origin at the bottom-left of the primary screen and y growing upward.
/// `CGWindowListCopyWindowInfo` reports bounds with a top-left origin, so every
/// frame goes through `WindowEnumerator.toGlobalAppKit(cgBounds:)`.
nonisolated struct WindowInfo: Sendable, Identifiable {
    var id: CGWindowID
    var frame: CGRect
    var title: String
    var ownerName: String
    var ownerPID: pid_t
    var layer: Int
}

@MainActor
enum WindowEnumerator {

    /// Owner names that are part of the system UI and never useful targets.
    private static let excludedOwners: Set<String> = [
        "Window Server",        // desktop picture / wallpaper
        "Dock",                 // Dock and Mission Control tiles
        "Control Center",
        "Notification Center",
        "Spotlight",
        "SystemUIServer",
        "Screenshot",
    ]

    /// Window names that identify the desktop / menu bar even when the owner is
    /// a normal-looking process.
    private static let excludedTitles: Set<String> = [
        "Desktop", "Desktop Picture", "Wallpaper", "Menubar", "Menu Bar",
        "Backstop Menubar", "Spotlight",
    ]

    /// Smallest window we consider pickable.
    static let minimumSize = CGSize(width: 40, height: 40)

    /// On-screen, layer-0 (normal) windows ordered front-to-back.
    ///
    /// Excludes our own process, the desktop/wallpaper, the menu bar, the Dock,
    /// Control Center, Notification Center, Spotlight, and anything smaller
    /// than 40x40 points.
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []
        result.reserveCapacity(raw.count)

        for entry in raw {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }

            let pid = (entry[kCGWindowOwnerPID as String] as? pid_t) ?? -1
            if pid == ownPID { continue }

            let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            if excludedOwners.contains(owner) { continue }

            let title = (entry[kCGWindowName as String] as? String) ?? ""
            if excludedTitles.contains(title) { continue }

            if cgBounds.width < minimumSize.width || cgBounds.height < minimumSize.height { continue }

            result.append(WindowInfo(id: number,
                                     frame: toGlobalAppKit(cgBounds: cgBounds),
                                     title: title,
                                     ownerName: owner,
                                     ownerPID: pid,
                                     layer: layer))
        }
        return result
    }

    /// Front-most window in `windows` whose frame contains `point`
    /// (global AppKit coordinates). `windows` is expected front-to-back.
    static func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    /// The window a rubber-band selection is credited to: the front-most window
    /// in `windows` (expected front-to-back) whose frame intersects `rect`, and
    /// among those the one covering the most of it. `nil` when nothing overlaps.
    ///
    /// Pure and testable - `rect` and every frame are global AppKit points.
    nonisolated static func sourceWindow(for rect: CGRect, in windows: [WindowInfo]) -> WindowInfo? {
        let target = rect.standardized
        guard target.width > 0, target.height > 0 else { return nil }

        var best: WindowInfo?
        var bestArea: CGFloat = 0
        for window in windows {
            let overlap = window.frame.standardized.intersection(target)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            // Strictly greater keeps the front-most window on a tie, because
            // `windows` arrives front-to-back.
            if area > bestArea {
                bestArea = area
                best = window
            }
        }
        return best
    }

    /// Display name to credit for `window`: the running application's localized
    /// name, falling back to the window server's owner name. `nil` for our own
    /// process (Bench is never the source of its own capture) and for a blank
    /// name.
    static func sourceAppName(for window: WindowInfo) -> String? {
        guard window.ownerPID != ProcessInfo.processInfo.processIdentifier else { return nil }
        let running = NSRunningApplication(processIdentifier: window.ownerPID)
        let name = running?.localizedName ?? window.ownerName
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Bundle identifier behind `window`, when the process still exists.
    static func sourceBundleID(for window: WindowInfo) -> String? {
        guard window.ownerPID != ProcessInfo.processInfo.processIdentifier else { return nil }
        return NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier
    }

    /// `sourceWindow(for:in:)` resolved to (name, bundle id).
    static func source(for rect: CGRect, in windows: [WindowInfo]) -> (name: String, bundleID: String?)? {
        guard let window = sourceWindow(for: rect, in: windows),
              let name = sourceAppName(for: window) else { return nil }
        return (name, sourceBundleID(for: window))
    }

    /// Converts `CGWindowList` bounds (points, origin at the **top-left** of the
    /// primary display, y growing downward) to global AppKit coordinates
    /// (points, origin at the **bottom-left** of the primary screen).
    static func toGlobalAppKit(cgBounds: CGRect) -> CGRect {
        toGlobalAppKit(cgBounds: cgBounds, primaryHeight: primaryScreenHeight)
    }

    /// Pure, testable form of the conversion.
    nonisolated static func toGlobalAppKit(cgBounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cgBounds.origin.x,
               y: primaryHeight - cgBounds.origin.y - cgBounds.height,
               width: cgBounds.width,
               height: cgBounds.height)
    }

    /// Height of the primary screen (`NSScreen.screens.first`, the one whose
    /// AppKit origin is (0, 0)) - the flip reference for the conversion above.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }
}
