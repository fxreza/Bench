import AppKit

/// A private WindowServer space that holds the notch panel.
///
/// A panel that merely joins all desktops (`.canJoinAllSpaces`) is a member
/// of every desktop, so a trackpad space swipe slides it out with the
/// outgoing desktop and in with the next. Alcove (and boring.notch) instead
/// create their own space, give it a very high absolute level, show it, and
/// move the notch window into it: such a space is drawn over every desktop
/// and is not part of any switch animation. SkyLight private API, resolved
/// with dlsym; everything is a no-op when a symbol is missing.
@MainActor
final class NotchSpace {
    private typealias ConnectionID = Int32
    private typealias SpaceID = UInt64

    private let cid: ConnectionID
    private let spaceCreate: @convention(c) (ConnectionID, Int32, CFDictionary?) -> SpaceID
    private let spaceDestroy: @convention(c) (ConnectionID, SpaceID) -> Void
    private let setAbsoluteLevel: @convention(c) (ConnectionID, SpaceID, Int32) -> Void
    private let showSpaces: @convention(c) (ConnectionID, CFArray) -> Void
    private let hideSpaces: @convention(c) (ConnectionID, CFArray) -> Void
    private let addWindows: @convention(c) (ConnectionID, CFArray, CFArray) -> Void
    private let removeWindows: @convention(c) (ConnectionID, CFArray, CFArray) -> Void
    private let spacesForWindows: @convention(c) (ConnectionID, Int32, CFArray) -> CFArray?

    private(set) var spaceID: UInt64 = 0

    init?() {
        guard let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(sl, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let main = sym("SLSMainConnectionID", (@convention(c) () -> ConnectionID).self),
              let create = sym("SLSSpaceCreate", (@convention(c) (ConnectionID, Int32, CFDictionary?) -> SpaceID).self),
              let destroy = sym("SLSSpaceDestroy", (@convention(c) (ConnectionID, SpaceID) -> Void).self),
              let level = sym("SLSSpaceSetAbsoluteLevel", (@convention(c) (ConnectionID, SpaceID, Int32) -> Void).self),
              let show = sym("SLSShowSpaces", (@convention(c) (ConnectionID, CFArray) -> Void).self),
              let hide = sym("SLSHideSpaces", (@convention(c) (ConnectionID, CFArray) -> Void).self),
              let add = sym("SLSAddWindowsToSpaces", (@convention(c) (ConnectionID, CFArray, CFArray) -> Void).self),
              let remove = sym("SLSRemoveWindowsFromSpaces", (@convention(c) (ConnectionID, CFArray, CFArray) -> Void).self),
              let spacesFor = sym("SLSCopySpacesForWindows", (@convention(c) (ConnectionID, Int32, CFArray) -> CFArray?).self)
        else {
            Log.notch.error("SkyLight space symbols missing; notch will slide with space swipes")
            return nil
        }
        cid = main()
        spaceCreate = create; spaceDestroy = destroy; setAbsoluteLevel = level
        showSpaces = show; hideSpaces = hide; addWindows = add; removeWindows = remove
        spacesForWindows = spacesFor
    }

    /// Creates (once) and shows the private space.
    private func ensureSpace() {
        guard spaceID == 0 else { return }
        spaceID = spaceCreate(cid, 1, nil)
        guard spaceID != 0 else { Log.notch.error("SLSSpaceCreate failed"); return }
        // Above every managed space, including fullscreen ones, so the notch
        // overlay is never hidden behind a space's own content.
        setAbsoluteLevel(cid, spaceID, Int32.max)
        showSpaces(cid, [NSNumber(value: spaceID)] as CFArray)
        Log.notch.info("private notch space \(self.spaceID) created")
    }

    /// Moves the window into the private space (and out of every desktop it
    /// was added to by `.canJoinAllSpaces`). Safe to call repeatedly.
    func adopt(_ window: NSWindow) {
        ensureSpace()
        guard spaceID != 0 else { return }
        let wid = NSNumber(value: UInt32(window.windowNumber))
        let current = (spacesForWindows(cid, 0x7, [wid] as CFArray) as? [NSNumber]) ?? []
        if current.contains(where: { $0.uint64Value == spaceID }) && current.count == 1 { return }
        addWindows(cid, [wid] as CFArray, [NSNumber(value: spaceID)] as CFArray)
        let others = current.filter { $0.uint64Value != spaceID }
        if !others.isEmpty {
            removeWindows(cid, [wid] as CFArray, others as CFArray)
        }
        Log.notch.info("notch window moved to private space \(self.spaceID) (was in \(others.count) spaces)")
    }

    func tearDown() {
        guard spaceID != 0 else { return }
        hideSpaces(cid, [NSNumber(value: spaceID)] as CFArray)
        spaceDestroy(cid, spaceID)
        spaceID = 0
    }
}
