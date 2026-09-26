import AppKit
import ApplicationServices

/// Brings one specific window to the front, switching to its Space when it
/// lives on another desktop.
///
/// `NSRunningApplication.activate()` plus `kAXRaiseAction` used to do this,
/// but on macOS 27 activating an app from the background only makes it the
/// menu-bar owner and leaves its window behind. Naming the window to
/// WindowServer fronts that exact window - the same SkyLight calls AltTab
/// and Hammerspoon use:
///
/// 1. `_SLPSSetFrontProcessWithOptions(psn, windowID, userGenerated)` fronts
///    the process *at that window*.
/// 2. Two synthetic `SLPSPostEventRecordTo` records make that window key,
///    so keyboard focus lands on it rather than on the app's last key window.
/// 3. When the window is on another Space, `SpaceSwitcher` goes there first:
///    on macOS 27 steps 1 and 2 no longer move the user.
///
/// Every symbol is resolved with `dlsym`; `bringForward` returns false when
/// one is missing or the window has no id, and the caller falls back to
/// plain activation.
enum WindowFocus {
    /// `kCPSUserGenerated`: the switch is treated as if the user asked for it.
    private static let userGenerated: UInt32 = 0x200

    private typealias SetFrontProcessWithOptions = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordTo = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetProcessForPID = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let skyLight: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY
    )

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let setFrontProcess = symbol(
        skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptions.self)
    private static let postEventRecord = symbol(
        skyLight, "SLPSPostEventRecordTo", as: PostEventRecordTo.self)
    // Deprecated since 10.9 but still exported by HIServices; resolved at run
    // time so the deprecation cannot turn into a link failure.
    private static let getProcessForPID = symbol(
        dlopen(nil, RTLD_LAZY), "GetProcessForPID", as: GetProcessForPID.self)

    /// Fronts `window` of `pid`, switching Spaces if needed. False when the
    /// SPI is unavailable or refused, so the caller can fall back.
    ///
    /// A press that arrives while a Space slide is still running is queued
    /// and carried out when the slide lands: shortcut presses posted
    /// mid-animation are not reliably honoured, and macOS keeps reporting
    /// the old Space until the slide ends, so counting steps then overshoots.
    @MainActor
    static func bringForward(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard setFrontProcess != nil, postEventRecord != nil, getProcessForPID != nil,
              let windowID = WindowController.windowID(of: window)
        else { return false }
        if slidingTo != nil {
            queued = (window, pid)
            settlingUntil = max(settlingUntil, Date().addingTimeInterval(0.8))
            return true
        }
        return focus(window, windowID: windowID, pid: pid, holdEvenWithoutSlide: false)
    }

    @MainActor
    private static func focus(_ window: AXUIElement, windowID: CGWindowID, pid: pid_t,
                              holdEvenWithoutSlide: Bool) -> Bool {
        guard let setFrontProcess, let postEventRecord, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let refront: @MainActor () -> Bool = {
            var psn = psn
            guard setFrontProcess(&psn, windowID, userGenerated) == .success else { return false }
            makeKey(windowID, psn: &psn, post: postEventRecord)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return true
        }

        generation += 1   // an earlier press's watch stops here
        guard refront() else { return false }
        // Even without a Space switch, the app reports the new focused
        // window only after a moment.
        settlingUntil = max(settlingUntil, Date().addingTimeInterval(0.8))

        // macOS 27 no longer follows the window to its Space; go there. The
        // slide takes about half a second a step, and arriving on a Space
        // makes macOS activate whatever is on top there, so keep the target
        // in front until it settles.
        let sliding = SpaceSwitcher.switchToSpace(of: windowID)
        if sliding { slidingTo = windowID }
        if sliding || holdEvenWithoutSlide {
            holdInFront(pid: pid, windowID: windowID) { _ = refront() }
        }
        return true
    }

    /// Bumped by every focus, so a newer press cancels an older press's
    /// watch instead of fighting it.
    @MainActor private static var generation = 0
    @MainActor private static var settlingUntil = Date.distantPast
    /// The window whose Space a slide is heading to, until it lands.
    @MainActor private static var slidingTo: CGWindowID?
    /// The latest press made during a slide, run when the slide lands.
    @MainActor private static var queued: (window: AXUIElement, pid: pid_t)?

    /// True shortly after a press, and while a Space switch is still
    /// sliding or settling. Focus reported by macOS then is often stale or
    /// macOS's own pick, so `FocusHistory` must not trust it.
    @MainActor static var isSettling: Bool { Date() < settlingUntil }

    /// Checks every 100 ms. Once the window's Space is current, the slide is
    /// over: a queued press runs now, otherwise the target is re-fronted
    /// whenever another app takes the front, for 0.8 s. Gives up after 3 s.
    /// (`NSWorkspace.activeSpaceDidChangeNotification` would be the natural
    /// trigger, but macOS 27 does not post it.)
    @MainActor
    private static func holdInFront(pid: pid_t, windowID: CGWindowID, refront: @escaping @MainActor () -> Void) {
        let current = generation
        settlingUntil = Date().addingTimeInterval(3)
        var landedAt: Date?
        let ticks = 30
        for tick in 1...ticks {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100 * tick)) {
                guard generation == current else { return }
                guard SpaceSwitcher.offset(to: windowID) == 0 else {
                    if tick == ticks { finishSlide() }
                    return
                }
                let now = Date()
                if landedAt == nil {
                    landedAt = now
                    if finishSlide() { return }
                }
                if let landedAt, now.timeIntervalSince(landedAt) > 0.8 {
                    settlingUntil = now
                    generation += 1   // done: stop the remaining ticks
                    return
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { refront() }
            }
        }
    }

    /// Ends the slide state and runs the press queued during it. True when
    /// a queued press took over.
    @MainActor @discardableResult
    private static func finishSlide() -> Bool {
        slidingTo = nil
        guard let next = queued else { return false }
        queued = nil
        guard let windowID = WindowController.windowID(of: next.window) else { return false }
        return focus(next.window, windowID: windowID, pid: next.pid, holdEvenWithoutSlide: true)
    }

    /// The two event records WindowServer sends a window when it is clicked
    /// to key: 0xf8 bytes, the window id at 0x3c, 0x01 then 0x02 at 0x08.
    private static func makeKey(_ windowID: CGWindowID, psn: inout ProcessSerialNumber, post: PostEventRecordTo) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { id in
            for (offset, byte) in id.enumerated() { bytes[0x3c + offset] = byte }
        }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
    }
}
