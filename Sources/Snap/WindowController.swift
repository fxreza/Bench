import AppKit
import ApplicationServices

/// The private SPI that turns an `AXUIElement` window into its `CGWindowID`.
/// Present since 10.x and used by every window manager on the platform; the
/// call site treats a non-`.success` answer as "no id" and falls back to the
/// window title, so losing it degrades the restore memory instead of
/// breaking it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Moves and resizes the focused window through Accessibility.
///
/// ## Coordinate conventions (the thing that goes wrong)
///
/// Everything read from or written to AX (`kAXPositionAttribute`,
/// `kAXSizeAttribute`) is in the **top-left-origin global space**, while
/// layouts, `NSScreen.visibleFrame` and the restore memory are all in
/// **Cocoa bottom-left coordinates**. So every read flips AX -> Cocoa
/// immediately, all the arithmetic happens in Cocoa, and the single flip
/// back to AX happens in `setFrame`. `SnapGeometry` owns both flips.
///
/// ## Why the size is written twice
///
/// Apps clamp what they are told. A window with a minimum size, or one that
/// snaps to a character grid (Terminal, iTerm), answers a resize with
/// something else, and if the position was written first the window ends up
/// correctly placed at the wrong size *and* pushed off the target edge. Size,
/// then position, then size again gets both right for every app tried: the
/// first size makes room, the position lands the origin, and the second size
/// re-applies whatever the app rounded away.
@MainActor
final class WindowController {
    let memory = RestoreMemory()

    // MARK: - Focused window

    /// The frontmost app's focused window, or its first window when it has
    /// no focused one (some apps only answer `kAXWindowsAttribute`).
    ///
    /// One `NSWorkspace.frontmostApplication` read and two AX calls: cheap
    /// enough for the hotkey path, which must feel instant.
    func focusedWindow() -> (element: AXUIElement, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        if let focused = Self.element(Self.attribute(appElement, kAXFocusedWindowAttribute)) {
            return (focused, pid)
        }
        if let windows = Self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement], let first = windows.first {
            return (first, pid)
        }
        return nil
    }

    /// Whether Snap may move this window: resizable, not a native
    /// full-screen window. A sheet or a fixed-size panel answers
    /// `AXUIElementIsAttributeSettable` with false and is left alone.
    func isManageable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return false }
        if let fullScreen = Self.attribute(window, "AXFullScreen") as? Bool, fullScreen { return false }
        return true
    }

    // MARK: - Frames

    /// The window's frame in Cocoa coordinates.
    func cocoaFrame(of window: AXUIElement) -> CGRect? {
        guard let axRect = axFrame(of: window) else { return nil }
        return SnapGeometry.flipRect(axRect, primaryHeight: SnapGeometry.primaryHeight)
    }

    /// The window's frame exactly as AX reports it: top-left origin.
    func axFrame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = Self.attribute(window, kAXPositionAttribute),
              let sizeValue = Self.attribute(window, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast - the type id was just checked.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Writes a Cocoa-space frame to the window: size, position, size.
    func setFrame(_ window: AXUIElement, cocoaRect: CGRect) {
        let rect = cocoaRect.snapRounded
        let axRect = SnapGeometry.flipRect(rect, primaryHeight: SnapGeometry.primaryHeight)
        setSize(window, axRect.size)
        setPosition(window, axRect.origin)
        setSize(window, axRect.size)
    }

    /// One `kAXSizeAttribute` write. Internal because the modifier-drag
    /// gestures write size and position one at a time, sixty times a second.
    func setSize(_ window: AXUIElement, _ size: CGSize) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
    }

    /// One `kAXPositionAttribute` write. See `setSize`.
    func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
    }

    // MARK: - Identity

    func identity(of window: AXUIElement, pid: pid_t) -> WindowIdentity {
        var windowID = CGWindowID(0)
        if _AXUIElementGetWindow(window, &windowID) != .success { windowID = 0 }
        let title = (Self.attribute(window, kAXTitleAttribute) as? String) ?? ""
        return WindowIdentity(pid: pid, windowID: windowID, title: title)
    }

    // MARK: - Placement

    /// Applies `layout` to the focused window. Returns false when there was
    /// nothing to move (no focused window, or one Snap must not touch), so
    /// the caller can beep rather than fail silently.
    @discardableResult
    func apply(_ layout: SnapLayout, gap: CGFloat) -> Bool {
        guard let (window, pid) = focusedWindow() else { return false }
        return apply(layout, to: window, pid: pid, gap: gap)
    }

    @discardableResult
    func apply(_ layout: SnapLayout, to window: AXUIElement, pid: pid_t, gap: CGFloat) -> Bool {
        guard isManageable(window), let current = cocoaFrame(of: window) else { return false }
        guard let screen = SnapGeometry.screen(for: current) else { return false }

        // Remember where the window was before Snap first moved it. Done
        // before the move and only once per window, so "Restore" always
        // means "back to how the user had it".
        memory.rememberIfNeeded(identity(of: window, pid: pid), frame: current)

        let target = layout.frame(in: screen.visibleFrame, gap: gap, currentSize: current.size)
        setFrame(window, cocoaRect: target)
        return true
    }

    /// Puts the focused window back to its pre-Snap frame and forgets it.
    @discardableResult
    func restore() -> Bool {
        guard let (window, pid) = focusedWindow() else { return false }
        return restore(window, pid: pid)
    }

    @discardableResult
    func restore(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard isManageable(window) else { return false }
        guard let frame = memory.restore(identity(of: window, pid: pid)) else { return false }
        setFrame(window, cocoaRect: frame)
        return true
    }

    // MARK: - AX helpers

    /// One attribute read, nil on any failure.
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// A checked `AXUIElement` unwrap: casting a `CFTypeRef` to a CF type is
    /// unchecked in Swift and would trap on a surprising value, so ask
    /// CoreFoundation what it really is first.
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast - guarded by the type id above.
        return (value as! AXUIElement)
    }

    static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    /// The closest ancestor (or the element itself) whose role is
    /// `AXWindow`, walking at most `limit` parents so a cycle or a very deep
    /// hierarchy cannot hang the click path.
    static func windowAncestor(of element: AXUIElement, limit: Int = 12) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0...limit {
            guard let node = current else { return nil }
            if role(of: node) == (kAXWindowRole as String) { return node }
            current = self.element(attribute(node, kAXParentAttribute))
        }
        return nil
    }
}
