import AppKit
import ApplicationServices

/// Moves the user to the desktop Space a window lives on.
///
/// Up to macOS 26, activating an app and raising its window was enough:
/// WindowServer followed the window to its Space. On macOS 27 it does not,
/// not even for the system's own ⌘⇥ - the app comes forward, its window
/// stays on the other desktop, and the user stays where they were. (The
/// "switch to a Space with open windows" preference no longer changes this.)
///
/// There is no public call to change Space, and the private
/// `SLSManagedDisplaySetCurrentSpace` only works from inside the Dock. What
/// every Mac does have is Mission Control's "Move left/right a space"
/// shortcuts (⌃← / ⌃→ by default). So Snap reads the display's ordered Space
/// list, counts how far the window's Space is from the current one, and
/// posts that many presses of the user's own binding - the same animation as
/// doing it by hand.
///
/// SkyLight symbols are resolved with `dlsym`; anything missing, a window on
/// no single Space (sticky windows), or a disabled shortcut makes
/// `switchToSpace(of:)` a no-op that returns false.
enum SpaceSwitcher {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// `kCGSAllSpacesMask`: ask about the window on every Space type.
    private static let allSpacesMask: Int32 = 7

    private static let skyLight: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64

    private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
    private static let getActiveSpace = symbol("SLSGetActiveSpace", as: GetActiveSpace.self)
    private static let copyManagedDisplaySpaces = symbol(
        "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let copySpacesForWindows = symbol(
        "SLSCopySpacesForWindows", as: CopySpacesForWindows.self)

    /// The Space the user is looking at (on the display with the menu bar
    /// focus). Nil when SkyLight does not answer.
    static func activeSpace() -> UInt64? {
        guard let mainConnectionID, let getActiveSpace else { return nil }
        let space = getActiveSpace(mainConnectionID())
        return space == 0 ? nil : space
    }

    /// Every Space the window is on: one for a normal window, several for a
    /// window shown on all desktops. Nil when SkyLight does not answer.
    static func spaces(of windowID: CGWindowID) -> [UInt64]? {
        guard let mainConnectionID, let copySpacesForWindows else { return nil }
        let spaces = copySpacesForWindows(mainConnectionID(), allSpacesMask, [windowID] as CFArray)?
            .takeRetainedValue() as? [NSNumber]
        return spaces?.map(\.uint64Value)
    }

    /// Goes to the Space `windowID` is on. True when shortcut presses were
    /// posted, false when the window is already there or the move is not
    /// possible.
    static func switchToSpace(of windowID: CGWindowID) -> Bool {
        guard let offset = offset(to: windowID), offset != 0 else { return false }
        return move(by: offset)
    }

    /// How many Spaces the window is to the right (positive) or left
    /// (negative) of the current Space on its display. Nil when it cannot be
    /// told; 0 when the window is already on screen.
    static func offset(to windowID: CGWindowID) -> Int? {
        guard let mainConnectionID, let copyManagedDisplaySpaces,
              let windowSpaces = spaces(of: windowID), windowSpaces.count == 1, let target = windowSpaces.first,
              let displays = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }

        for display in displays {
            let order = (display["Spaces"] as? [[String: Any]] ?? []).compactMap(spaceID)
            guard let targetIndex = order.firstIndex(of: target) else { continue }
            guard let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID),
                  let currentIndex = order.firstIndex(of: current)
            else { return nil }
            return targetIndex - currentIndex
        }
        return nil
    }

    /// Posts the Mission Control shortcut `abs(offset)` times. False when
    /// the needed shortcut is turned off in Keyboard Shortcuts.
    @discardableResult
    static func move(by offset: Int) -> Bool {
        guard offset != 0 else { return true }
        // 79 "Move left a space", 81 "Move right a space".
        guard let shortcut = missionControlShortcut(id: offset < 0 ? 79 : 81) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<abs(offset) {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: keyDown)
                else { return false }
                event.flags = shortcut.flags
                event.post(tap: .cghidEventTap)
            }
        }
        return true
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        (space["id64"] as? NSNumber)?.uint64Value ?? (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    /// The user's binding for a Mission Control symbolic hot key, from
    /// `com.apple.symbolichotkeys`; the factory ⌃← / ⌃→ when the entry was
    /// never customised, nil when it is switched off.
    private static func missionControlShortcut(id: Int) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let fallbackKey: CGKeyCode = id == 79 ? 123 : 124
        let fallbackFlags = CGEventFlags(rawValue: 0x840000)   // ⌃ + fn, as the system stores arrows
        let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        guard let entry = hotKeys?[String(id)] as? [String: Any] else { return (fallbackKey, fallbackFlags) }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        guard let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
              parameters.count == 3
        else { return (fallbackKey, fallbackFlags) }
        return (CGKeyCode(parameters[1].intValue), CGEventFlags(rawValue: parameters[2].uint64Value))
    }
}
