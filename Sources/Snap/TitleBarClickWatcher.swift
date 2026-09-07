import AppKit
import ApplicationServices
import BenchCore

/// Watches for a double-click on a window's title bar and reports the window
/// that was hit.
///
/// ## How the click is seen
///
/// A **listen-only** session event tap (`CGEvent.tapCreate`, `.listenOnly`)
/// on `.leftMouseDown`. Listen-only means the click is never delayed,
/// swallowed or modified - the window still gets it - and the tap needs only
/// the Accessibility grant, which Snap needs anyway. The second click of a
/// double-click is the one that carries `.mouseEventClickState == 2`; a
/// triple-click reports 3 and is ignored, so holding the mouse down on a
/// title bar and clicking repeatedly does not run the action several times.
///
/// macOS's own "double-click a window's title bar to" setting
/// (`AppleActionOnDoubleClick`) is `None` on this Mac, so nothing else reacts
/// to the same gesture. If a user sets it to Zoom or Minimize, both will
/// happen - hence the `snap.titlebarDoubleClick` switch.
///
/// ## The hit rule
///
/// `AXUIElementCopyElementAtPosition` from the system-wide element gives the
/// deepest element under the click. We accept the click as a title bar hit
/// when, in `isTitleBarHit`:
///
/// - the point lies in the top `titleBarBand` (30) points of the enclosing
///   window's frame, and
/// - the element's role is not something interactive - a button, a text
///   field, a popup, a tab. Toolbar buttons and the traffic lights live in
///   exactly that band, and clicking them twice quickly must not maximize.
///
/// The window itself (`AXWindow`), a toolbar (`AXToolbar`), the title's
/// `AXStaticText` and unnamed chrome groups all pass. Any element with no
/// enclosing window - a menu, the Dock, the desktop - is rejected before the
/// rule is even asked.
///
/// Clicks carrying ⌘⌥⌃⇧ are ignored: ⌘-dragging a title bar moves a
/// background window, and BTT's trigger was unmodified too.
@MainActor
final class TitleBarClickWatcher {
    /// How far down from the top of a window a click still counts as being
    /// on the title bar. 30 points ~ the height of a standard title bar
    /// (28pt) with a point of slack at each end.
    static let titleBarBand: CGFloat = 30

    /// Roles that mean "the user clicked a control, not the chrome".
    /// Spelled out rather than taken from the `kAX*Role` constants: several
    /// of these (search field, segmented control, link) have no constant in
    /// ApplicationServices, and the strings are the API - they are what AX
    /// actually returns.
    static let interactiveRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXSlider",
        "AXIncrementor",
        "AXStepper",
        "AXSegmentedControl",
        "AXLink",
        "AXDisclosureTriangle",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXTabGroup",
    ]

    /// The pure rule, so it can be tested without a mouse, a window or the
    /// Accessibility grant.
    ///
    /// - Parameters:
    ///   - role: `kAXRoleAttribute` of the element under the click, nil when
    ///     the element did not answer (unnamed chrome, which is accepted).
    ///   - pointY: the click's y in **AX coordinates** (top-left origin), the
    ///     same space `windowFrame` is in.
    ///   - windowFrame: the enclosing window's AX frame.
    static func isTitleBarHit(role: String?, pointY: CGFloat, windowFrame: CGRect) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return false }
        // Top-left origin: the title bar is the *low* y end of the frame.
        guard pointY >= windowFrame.minY, pointY < windowFrame.minY + titleBarBand else { return false }
        guard let role else { return true }
        if role == (kAXWindowRole as String) { return true }
        if role == (kAXToolbarRole as String) { return true }
        if role == (kAXStaticTextRole as String) { return true }
        return !interactiveRoles.contains(role)
    }

    /// Called with the window element and its pid when a title bar was
    /// double-clicked.
    var onDoubleClick: ((AXUIElement, pid_t) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isInstalled: Bool { tap != nil }

    /// Installs the tap. A no-op when already installed or when
    /// Accessibility is not granted - `SnapFeature` re-calls this from
    /// `PermissionsState.onAccessibilityBecameTrusted`.
    func install() {
        guard tap == nil, PermissionsState.shared.accessibilityTrusted else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<TitleBarClickWatcher>.fromOpaque(userInfo).takeUnretainedValue()
            // The source is on the main run loop, so this callback already
            // runs on the main thread; the C function pointer just cannot say
            // so in its type.
            MainActor.assumeIsolated {
                watcher.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("[Snap] title bar tap could not be created (Accessibility?)")
            return
        }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func remove() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that took too long or was interrupted;
        // re-enabling is the documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .leftMouseDown else { return }
        guard event.getIntegerValueField(.mouseEventClickState) == 2 else { return }
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard modifiers.isEmpty else { return }

        // The AX hit test costs a few cross-process calls; doing it inside
        // the tap callback would count against the tap's own timeout, so it
        // runs right after the callback returns instead.
        let location = event.location
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.resolve(at: location) }
        }
    }

    /// Turns a click location (AX/CG global coordinates) into the window it
    /// hit, if it hit a title bar.
    private func resolve(at location: CGPoint) {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &hit) == .success,
              let element = hit
        else { return }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        // Never react to a click inside Bench itself.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        guard let window = WindowController.windowAncestor(of: element) else { return }
        guard let frame = axWindowFrame(window) else { return }
        guard Self.isTitleBarHit(role: WindowController.role(of: element), pointY: location.y, windowFrame: frame)
        else { return }

        onDoubleClick?(window, pid)
    }

    private func axWindowFrame(_ window: AXUIElement) -> CGRect? {
        guard let positionValue = WindowController.attribute(window, kAXPositionAttribute),
              let sizeValue = WindowController.attribute(window, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast - type ids checked above.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
