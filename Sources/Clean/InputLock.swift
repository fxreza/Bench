import AppKit
import CoreGraphics
import IOKit.pwr_mgt

// MARK: - Hold to unlock

/// Tracks the trackpad and mouse buttons during a lock and decides when they
/// have been held long enough to unlock.
///
/// Pure and nonisolated: no clock, no events, so `CleanTests` drives it with
/// made-up timestamps. The hold starts with the first button down and ends
/// when the last one comes up, so pressing a second button on the way does
/// not restart the count.
nonisolated struct UnlockHold {
    let duration: TimeInterval
    private(set) var pressed: Set<Int64> = []
    private(set) var startedAt: TimeInterval?

    init(duration: TimeInterval) {
        self.duration = duration
    }

    var isHolding: Bool { startedAt != nil }

    /// A button went down. Returns true when this starts a hold.
    mutating func press(button: Int64, at time: TimeInterval) -> Bool {
        let wasEmpty = pressed.isEmpty
        pressed.insert(button)
        guard wasEmpty else { return false }
        startedAt = time
        return true
    }

    /// A button came up. Returns true when this ends the hold.
    mutating func release(button: Int64) -> Bool {
        guard pressed.remove(button) != nil, pressed.isEmpty, startedAt != nil else { return false }
        startedAt = nil
        return true
    }

    /// 0...1, how far the current hold is.
    func progress(at time: TimeInterval) -> Double {
        guard let startedAt, duration > 0 else { return 0 }
        return min(max((time - startedAt) / duration, 0), 1)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return time - startedAt >= duration
    }
}

// MARK: - Engine

/// Blocks every keyboard, trackpad and mouse event while the lock is on.
///
/// One `CGEvent` tap at the HID level (where events enter the window
/// server, before any app, hotkey or the Dock sees them) with a mask of
/// every event type, so keys of all kinds (media and brightness keys arrive
/// as `NX_SYSDEFINED`), modifiers, clicks, movement, scrolling and gestures
/// are all dropped. Mouse button downs and ups are still read on their way
/// to the bin: holding any of them for `holdSeconds` is the only way out,
/// apart from quitting Bench, which takes the tap with it.
///
/// While locked the pointer is detached from the mouse and hidden, and a
/// power assertion keeps the display awake and the screensaver off.
@MainActor
final class InputLock {
    var onHoldBegan: ((TimeInterval) -> Void)?
    var onHoldCancelled: (() -> Void)?
    var onUnlockRequested: (() -> Void)?

    private(set) var isActive = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hold = UnlockHold(duration: 3)
    private var completion: DispatchWorkItem?
    private var displayAssertion: IOPMAssertionID = 0
    private var cursorHidden = false

    /// Installs the tap and takes the assertion. Returns false, holding
    /// nothing, when macOS refuses the tap (no Accessibility).
    func start(holdSeconds: Int) -> Bool {
        guard !isActive else { return true }
        hold = UnlockHold(duration: TimeInterval(holdSeconds))

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask.max
        // The HID tap is ahead of everything; the session tap is the fallback
        // if this macOS ever refuses the first.
        let created = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: inputLockCallback, userInfo: refcon)
            ?? CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: inputLockCallback, userInfo: refcon)
        guard let tap = created else {
            CleanLog.log.error("CGEvent.tapCreate failed; not locking")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isActive = true

        let reason = "Bench Clean: keyboard and trackpad locked for cleaning" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        if result != kIOReturnSuccess {
            displayAssertion = 0
            CleanLog.log.error("Display sleep assertion failed: \(result, privacy: .public)")
        }

        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        cursorHidden = true
        CleanLog.log.info("Input locked")
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        completion?.cancel()
        completion = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        CleanLog.log.info("Input unlocked")
    }

    /// Every event lands here and none comes out, except the tap's own
    /// disabled notices.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            CleanLog.log.error("Event tap disabled (\(type.rawValue, privacy: .public)); re-enabling")
            if let tap, isActive { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if hold.press(button: button, at: ProcessInfo.processInfo.systemUptime) {
                CleanLog.log.info("Hold began (button \(button, privacy: .public))")
                beginHold()
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if hold.release(button: button) {
                CleanLog.log.info("Hold released early (button \(button, privacy: .public))")
                completion?.cancel()
                completion = nil
                onHoldCancelled?()
            }
        default:
            break
        }
        return nil
    }

    private func beginHold() {
        onHoldBegan?(hold.duration)
        let work = DispatchWorkItem { [weak self] in
            // Cancelled on release, so still holding here means held long
            // enough; the clock check is not repeated against timer slack.
            guard let self, self.isActive, self.hold.isHolding else { return }
            CleanLog.log.info("Hold complete; unlocking")
            self.onUnlockRequested?()
        }
        completion?.cancel()
        completion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold.duration, execute: work)
    }
}

/// C trampoline. The run loop source is on the main run loop, so this always
/// arrives on the main thread.
private nonisolated func inputLockCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let lock = Unmanaged<InputLock>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { lock.handle(type: type, event: event) }
}
