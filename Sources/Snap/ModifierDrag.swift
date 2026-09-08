import AppKit
import ApplicationServices
import BenchCore

/// BetterTouchTool's "Moving & Resizing Modifier Keys", reimplemented on
/// Accessibility.
///
/// Hold ⇧⌥ and move the mouse: the window under the pointer moves with it.
/// Hold ⇧⌃ instead and it resizes from its top-left corner. No click, no
/// title bar, no drag handle - the pointer only has to be over the window
/// when the modifiers go down.
///
/// ## Why a timer and not a mouse-moved monitor
///
/// The obvious implementation watches
/// `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` while a combo is
/// held. Piko shipped that once and had to take it out: a global mouse-moved
/// monitor is a system-wide event tap on the main run loop, and while any menu
/// is tracking it throttles mouse-move delivery to that menu, so highlights
/// lag and skip (see `NotchWindowController.startPointerTracking`). Sampling
/// `NSEvent.mouseLocation` from a `Timer` in `.common` mode installs no tap at
/// all, and 60 Hz is indistinguishable from event-driven for a drag.
///
/// The tick also re-reads `NSEvent.modifierFlags`. A `flagsChanged` event can
/// be missed - a Space switch, a lost monitor, a key released while a modal
/// tracking loop owns the event stream - and without that safety net a missed
/// key-up would leave a window glued to the pointer.
///
/// ## Coordinates
///
/// `NSEvent.mouseLocation` is Cocoa (bottom-left origin, y up); AX frames are
/// top-left origin, y down. The pointer delta is flipped into AX space once,
/// in `ModifierDragMath.axDelta`, and everything downstream stays in AX space
/// so each tick is a single `kAXPositionAttribute` or `kAXSizeAttribute`
/// write. `WindowController.setFrame`'s size-position-size dance is right for
/// a one-shot layout and far too slow to run sixty times a second.
@MainActor
final class ModifierDragController {
    /// How often the pointer is sampled while a combo is held. Matches Piko's
    /// notch tracking: 60 Hz reads as instant and costs one `mouseLocation`
    /// read plus one AX write per tick.
    private static let tickInterval: TimeInterval = 1.0 / 60.0

    /// One held-modifier gesture, from the moment the combo went down to the
    /// moment it was released. The target window and its frame are captured
    /// once, at the start: the pointer may wander off the window, and the
    /// window keeps following it.
    private struct Session {
        let mode: ModifierDragMath.Mode
        let modifiers: NSEvent.ModifierFlags
        let window: AXUIElement
        /// The window's frame when the combo went down, in AX coordinates.
        let startFrame: CGRect
        /// The pointer when the combo went down, in Cocoa coordinates.
        let startPointer: CGPoint
        /// The last frame written, so an idle tick writes nothing.
        var written: CGRect?
        /// Whether the window was raised already (at most once per gesture).
        var raised = false
    }

    private let settings: SnapSettings
    private let controller: WindowController

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var session: Session?

    init(settings: SnapSettings, controller: WindowController) {
        self.settings = settings
        self.controller = controller
    }

    // MARK: - Lifecycle

    /// Starts watching modifier keys. Cheap while idle: two `flagsChanged`
    /// monitors and no timer until a combo is actually held.
    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        // The global monitor sees other apps; the local one is what fires
        // while a Bench window (Settings, the annotation editor) is key,
        // because a key window's events never reach the global monitor.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event.modifierFlags) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event.modifierFlags) }
            return event
        }
    }

    /// Removes the monitors and the timer; after this the controller holds
    /// nothing that runs.
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        endSession()
    }

    // MARK: - Modifier tracking

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard settings.modifierDragEnabled else {
            endSession()
            return
        }
        // Silence, not a prompt: `flagsChanged` fires on every ⇧ of every
        // word typed, and asking for Accessibility there would be a modal
        // storm. The Permissions pane is where the grant is asked for.
        guard PermissionsState.shared.accessibilityTrusted else {
            endSession()
            return
        }

        guard let mode = mode(for: flags) else {
            endSession()
            return
        }
        // Adding a third modifier to a live gesture (⇧⌥ -> ⇧⌥⌘) matches
        // nothing and ends it above; coming back to the same combo starts a
        // fresh gesture from wherever the pointer is now.
        if let session, session.mode == mode, session.modifiers == flags { return }
        beginSession(mode: mode, modifiers: flags)
    }

    /// Which gesture, if any, this exact modifier state means. Move is
    /// checked first; a user who configures the same combination for both
    /// gets the move.
    private func mode(for flags: NSEvent.ModifierFlags) -> ModifierDragMath.Mode? {
        if ModifierDragMath.matches(flags, settings.moveModifiers) { return .move }
        if ModifierDragMath.matches(flags, settings.resizeModifiers) { return .resize }
        return nil
    }

    private func beginSession(mode: ModifierDragMath.Mode, modifiers: NSEvent.ModifierFlags) {
        endSession()
        let pointer = NSEvent.mouseLocation
        // No window under the pointer, or one Snap must not touch: do
        // nothing at all, and leave the timer off until the next combo.
        guard let window = windowUnderPointer(pointer),
              let frame = controller.axFrame(of: window)
        else { return }

        session = Session(
            mode: mode, modifiers: modifiers, window: window,
            startFrame: frame, startPointer: pointer)
        startTimer()
    }

    private func endSession() {
        timer?.invalidate()
        timer = nil
        session = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` keeps the gesture alive while a menu or a window drag
        // owns the run loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - The tick

    private func tick() {
        guard var session else {
            endSession()
            return
        }
        // Safety net: a `flagsChanged` we never saw cannot strand a window.
        guard settings.modifierDragEnabled,
              mode(for: NSEvent.modifierFlags) == session.mode
        else {
            endSession()
            return
        }

        guard let target = ModifierDragMath.frame(
            for: session.mode,
            startFrame: session.startFrame,
            startPointer: session.startPointer,
            pointer: NSEvent.mouseLocation,
            threshold: settings.effectiveDragThreshold)
        else { return }
        guard target != session.written else { return }

        if !session.raised, settings.bringToFront {
            session.raised = true
            raise(session.window)
        }

        switch session.mode {
        case .move:
            controller.setPosition(session.window, target.origin)
        case .resize:
            controller.setSize(session.window, target.size)
        }
        session.written = target
        self.session = session
    }

    /// Off by default: BTT's "bring moving window to front" is a separate
    /// switch there too, and raising a window the user only meant to nudge
    /// steals focus from whatever they were typing in.
    private func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return }
        app.activate()
    }

    // MARK: - Hit testing

    /// The manageable window under `pointer` (Cocoa coordinates), or nil.
    private func windowUnderPointer(_ pointer: CGPoint) -> AXUIElement? {
        let axPoint = SnapGeometry.flipPoint(pointer, primaryHeight: SnapGeometry.primaryHeight)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &element) == .success,
            let hit = element
        else { return nil }

        // Bench's own windows are off limits: dragging the Settings window
        // out from under the pointer that is configuring this feature is not
        // a feature.
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        guard let window = WindowController.windowAncestor(of: hit),
              controller.isManageable(window)
        else { return nil }
        return window
    }
}

/// The arithmetic behind the gesture, with no Accessibility and no pointer in
/// it, so the tests can drive every case from plain rectangles.
nonisolated enum ModifierDragMath {
    enum Mode: Equatable, Sendable {
        case move
        case resize
    }

    /// Floor on a resize. The app's own minimum wins whenever it is larger:
    /// this only stops a window being driven down to nothing when the app
    /// declares no minimum at all.
    static let minimumSize = CGSize(width: 50, height: 50)

    /// The only modifiers a combination may be built from. Restricting the
    /// comparison to these five keeps Caps Lock (physically Right Control on
    /// this Mac, but a stuck `.capsLock` on any other keyboard) and the
    /// numeric-pad flag from silently breaking an exact match.
    static let usableModifiers: NSEvent.ModifierFlags = [.shift, .function, .control, .option, .command]

    /// True when `flags` is exactly `combination` - ⇧⌥ triggers a ⇧⌥ gesture,
    /// ⇧⌥⌘ triggers nothing. An empty combination never matches, or every
    /// idle moment of the day would be a gesture.
    static func matches(_ flags: NSEvent.ModifierFlags, _ combination: NSEvent.ModifierFlags) -> Bool {
        let wanted = combination.intersection(usableModifiers)
        guard !wanted.isEmpty else { return false }
        return flags.intersection(.deviceIndependentFlagsMask).intersection(usableModifiers) == wanted
    }

    /// A Cocoa pointer delta as an AX-space delta: x is unchanged, y is
    /// negated, because Cocoa's y grows upwards and AX's grows downwards.
    /// Moving the pointer down the screen therefore gives a positive height,
    /// which is what "moving down grows the window" means.
    static func axDelta(from start: CGPoint, to current: CGPoint) -> CGSize {
        CGSize(width: current.x - start.x, height: start.y - current.y)
    }

    /// Whether the pointer has travelled far enough to commit to the gesture.
    /// Below the threshold nothing is written, so a combination pressed
    /// without meaning to move anything leaves the window exactly where it is.
    static func passedThreshold(from start: CGPoint, to current: CGPoint, threshold: CGFloat) -> Bool {
        guard threshold > 0 else { return true }
        let dx = current.x - start.x
        let dy = current.y - start.y
        return (dx * dx + dy * dy) >= (threshold * threshold)
    }

    /// The frame to write this tick, in AX coordinates, or nil while the
    /// pointer is still inside the threshold.
    ///
    /// The delta is measured from the *start* of the gesture rather than from
    /// the previous tick, so a window whose app clamped a resize snaps back to
    /// the right size as soon as the pointer comes back, instead of drifting.
    static func frame(
        for mode: Mode,
        startFrame: CGRect,
        startPointer: CGPoint,
        pointer: CGPoint,
        threshold: CGFloat,
        minimum: CGSize = minimumSize
    ) -> CGRect? {
        guard passedThreshold(from: startPointer, to: pointer, threshold: threshold) else { return nil }
        let delta = axDelta(from: startPointer, to: pointer)
        switch mode {
        case .move: return moved(startFrame, by: delta)
        case .resize: return resized(startFrame, by: delta, minimum: minimum)
        }
    }

    /// Move: the origin follows the pointer, the size is untouched.
    static func moved(_ frame: CGRect, by delta: CGSize) -> CGRect {
        CGRect(
            x: (frame.origin.x + delta.width).rounded(),
            y: (frame.origin.y + delta.height).rounded(),
            width: frame.width,
            height: frame.height)
    }

    /// Resize: the top-left corner stays put, the size follows the pointer,
    /// never below `minimum`.
    static func resized(_ frame: CGRect, by delta: CGSize, minimum: CGSize = minimumSize) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: max(minimum.width, (frame.width + delta.width).rounded()),
            height: max(minimum.height, (frame.height + delta.height).rounded()))
    }
}
