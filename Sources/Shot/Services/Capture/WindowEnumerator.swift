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
