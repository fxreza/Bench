import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Tap detection

/// Decides whether a stretch of trackpad frames was a three-finger *tap*:
/// three fingers down, up again quickly, and barely moved in between.
///
/// Pure and nonisolated on purpose - it holds no framework handles, posts no
/// events and reads no clock, so `TapTests` can drive it frame by frame with
/// made-up timestamps and positions. `MultitouchMonitor` owns the only live
/// instance and calls it under its lock.
nonisolated struct TapDetector {
    struct Config: Equatable {
        /// How many fingers make the gesture.
        var fingers: Int = 3
        /// Longest touch still counted as a tap. Above this the user is
        /// resting fingers or scrolling, not tapping.
        var maxDuration: TimeInterval = 0.25
        /// Manhattan distance the *sum* of the finger positions may travel,
        /// in normalized pad units (0...1 across the pad). Summed rather
        /// than averaged so that three fingers sliding together, which is a
        /// scroll, is caught as easily as one finger sliding alone.
        var maxMovement: Float = 0.03
    }

    enum Outcome: Equatable {
        case none
        case middleClick
    }

    let config: Config

    /// True between the first three-finger frame and the frame where the pad
    /// goes empty again.
    private var isTracking = false
    private var startTime: Double = 0
    private var startSumX: Float = 0
    private var startSumY: Float = 0
    private var movement: Float = 0
    private var clicked = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// A physical click landed while the fingers were down: whatever else
    /// happens, this touch is not a tap. (In `both` mode the click was just
    /// turned into a middle click; emitting a second one on lift would
    /// double every three-finger click.)
    mutating func noteClick() {
        clicked = true
    }

    mutating func reset() {
        isTracking = false
        startTime = 0
        startSumX = 0
        startSumY = 0
        movement = 0
        clicked = false
    }

    /// Feeds one multitouch frame. `sumX`/`sumY` are the summed normalized
    /// positions of the fingers in this frame. Returns `.middleClick` on the
    /// frame where the pad empties out after a qualifying tap.
    mutating func update(fingerCount: Int, sumX: Float, sumY: Float, timestamp: Double) -> Outcome {
        // A fourth finger means some other gesture; give up on this touch.
        if fingerCount > config.fingers {
            reset()
            return .none
        }

        guard isTracking else {
            if fingerCount == config.fingers {
                isTracking = true
                startTime = timestamp
                startSumX = sumX
                startSumY = sumY
                movement = 0
                clicked = false
            }
            return .none
        }

        if fingerCount == config.fingers {
            // Track the furthest the fingers ever got from where they landed,
            // not just where they ended: a flick out and back is not a tap.
            movement = max(movement, abs(sumX - startSumX) + abs(sumY - startSumY))
            return .none
        }
        // Fingers coming off one at a time: keep waiting for an empty pad.
        if fingerCount > 0 { return .none }

        let duration = timestamp - startTime
        let isTap = !clicked && duration >= 0 && duration <= config.maxDuration
            && movement <= config.maxMovement
        reset()
        return isTap ? .middleClick : .none
    }

    /// Convenience for tests: takes the frame's contacts instead of the sums.
    mutating func update(fingers: [MTPoint], timestamp: Double) -> Outcome {
        var sumX: Float = 0
        var sumY: Float = 0
        for finger in fingers {
            sumX += finger.x
            sumY += finger.y
        }
        return update(fingerCount: fingers.count, sumX: sumX, sumY: sumY, timestamp: timestamp)
    }
}

// MARK: - Engine

/// Turns three fingers - or fn and a normal click - into the middle mouse
/// button.
///
/// Three triggers, independent of each other. Two are fed by
/// `MultitouchMonitor`'s finger count:
///
/// - **Click.** A `CGEvent` session tap rewrites `leftMouseDown` - or
///   `rightMouseDown`, which is what the driver sends when its own contact
///   count came up two and "secondary click" is two fingers - into
///   `otherMouseDown` with button 2 while three fingers are on the pad. The
///   drags and the matching up are rewritten too, so a middle-drag works and
///   no app ever sees half a click. The tap is `.defaultTap` (it has to
///   modify events) at `.headInsertEventTap`, and re-arms itself when macOS
///   disables it, exactly like `Piko`'s `MediaKeyInterceptor`.
/// - **Tap.** `TapDetector` watches the finger count for a quick three-finger
///   touch and the engine posts a synthetic middle click at the pointer.
///
/// The third asks the trackpad nothing at all:
///
/// - **fn+click.** The same event tap rewrites any click carrying
///   `maskSecondaryFn`. No finger counting, so none of the driver's
///   classification trouble can reach it - which is the point of having it.
///
/// Nothing here runs without Accessibility: `TapFeature` checks before it
/// starts the engine.
@MainActor
final class MiddleClickEngine {
    private(set) var isRunning = false

    private var triggers = MiddleClickTriggers(mode: .off, fnClick: false)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Which physical button the driver reported for the click currently
    /// being served as the middle button, nil when none.
    ///
    /// The finger count is deliberately not consulted again while it is set:
    /// the user lifts fingers during a middle-drag and the button still has
    /// to come up as button 2. The source button is remembered rather than a
    /// bare flag so only *its* drags and its up are rewritten - a right click
    /// held as middle must not be released by a stray `leftMouseUp`.
    private var held: HeldButton?

    /// The two physical buttons a three-finger click can arrive as. Both are
    /// rewritten identically; see `handle(type:event:)`.
    private enum HeldButton { case left, right }

    private let monitor = MultitouchMonitor.shared

    /// Set when the multitouch side could not start, shown in the pane.
    var unavailableReason: String? { monitor.unavailableReason }

    // MARK: Lifecycle

    /// Starts the multitouch monitor and, unless every trigger is off, the
    /// event tap. Returns false when multitouch is unavailable.
    @discardableResult
    func start(triggers: MiddleClickTriggers) -> Bool {
        self.triggers = triggers
        guard monitor.start() else { return false }
        isRunning = true

        monitor.setTapHandler { [weak self] in
            // Framework thread: get onto main before touching CGEvent or self.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.postMiddleClick() }
            }
        }
        apply(triggers: triggers)
        return true
    }

    func stop() {
        isRunning = false
        triggers = MiddleClickTriggers(mode: .off, fnClick: false)
        monitor.setTapHandler(nil)
        monitor.setTapDetectionEnabled(false)
        monitor.stop()
        removeEventTap()
    }

    /// Re-enumerates the trackpads. Devices disappear across sleep and the
    /// registered callback goes with them.
    func handleWake() {
        guard isRunning else { return }
        monitor.restart()
    }

    /// Follows the settings while running.
    func apply(triggers: MiddleClickTriggers) {
        self.triggers = triggers
        guard isRunning else { return }
        monitor.setTapDetectionEnabled(triggers.detectsTap)
        if triggers.needsEventTap {
            installEventTap()
        } else {
            removeEventTap()
        }
    }

    // MARK: Event tap

    private func installEventTap() {
        guard tap == nil else { return }
        // Both buttons: with "secondary click" set to two fingers, the
        // trackpad driver counts the contacts itself and a three-finger
        // click whose third finger lands late (or is rejected as a palm)
        // arrives as `rightMouseDown`. That click is the one the user meant
        // as a middle click, so it has to be caught here too - otherwise it
        // passes through and opens a context menu.
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: middleClickTapCallback,
            userInfo: refcon
        ) else {
            TapLog.log.error("CGEvent.tapCreate failed; three-finger click is off")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        TapLog.log.info("Middle-click event tap installed")
    }

    private func removeEventTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        held = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            // Any click cancels a tap in progress, in every mode, whichever
            // button the driver decided on.
            monitor.noteClick()
            guard held == nil else { break }
            // Either trigger on its own is enough. fn is checked first
            // because it costs nothing: no finger count, no trackpad.
            let byFn = triggers.fnClick && event.flags.contains(.maskSecondaryFn)
            let byFingers = triggers.convertsClick
                && monitor.fingerCount == TapDetector.Config().fingers
            guard byFn || byFingers else { break }
            held = type == .leftMouseDown ? .left : .right
            convert(event, to: .otherMouseDown)
        case .leftMouseDragged where held == .left,
             .rightMouseDragged where held == .right:
            convert(event, to: .otherMouseDragged)
        case .leftMouseUp where held == .left,
             .rightMouseUp where held == .right:
            held = nil
            convert(event, to: .otherMouseUp)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Rewrites the event in place. The original left click never reaches
    /// the app: it *is* the middle click now, same location, same click
    /// count, same modifiers.
    private func convert(_ event: CGEvent, to type: CGEventType) {
        event.type = type
        event.setIntegerValueField(
            .mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
        // fn was how the user asked for a middle click, not something they
        // meant the app to see. Chrome reads ⇧ on a middle click (open the
        // tab in front) and would be within its rights to read others, so
        // the flag comes off and the app gets a plain middle click.
        event.flags.remove(.maskSecondaryFn)
    }

    // MARK: Synthetic click

    /// Posts a middle click where the pointer is, for the tap gesture.
    private func postMiddleClick() {
        guard isRunning, triggers.detectsTap else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center
            )?.post(tap: .cghidEventTap)
        }
    }
}

/// C trampoline. The run loop source is on the main run loop, so this always
/// arrives on the main thread.
private nonisolated func middleClickTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<MiddleClickEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { engine.handle(type: type, event: event) }
}
