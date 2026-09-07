import AppKit
import ApplicationServices
import CoreGraphics

/// Swallows the volume / brightness / mute media keys before macOS sees them,
/// so `OSDUIHelper` is never asked to draw the system bezel. Piko then applies
/// the change itself (`VolumeController`, `BrightnessController`) and shows its
/// own HUD.
///
/// Technique notes (see docs/research/tech-reference.md §1.1):
/// - The tap must be `.cghidEventTap` + `.headInsertEventTap` + `.defaultTap`
///   so the event vanishes before Control Center can react to it.
/// - An *active* tap only needs Accessibility; a listen-only tap would also
///   demand Input Monitoring.
/// - The system disables taps it thinks are unresponsive: re-arm on
///   `.tapDisabledByTimeout` / `.tapDisabledByUserInput`.
/// - Fail soft: with no Accessibility trust we install nothing and the native
///   HUD keeps working. A retry timer arms the tap the moment trust appears,
///   with no relaunch.
@MainActor
final class MediaKeyInterceptor {

    // MARK: Callbacks

    /// `(direction: +1 / -1, fine: 1/64 step, shiftHeld: inverts the click sound)`
    var onVolumeStep: ((Int, Bool, Bool) -> Void)?
    var onMute: (() -> Void)?
    /// `(direction: +1 / -1, fine: 1/64 step)`
    var onBrightnessStep: ((Int, Bool) -> Void)?

    // MARK: State

    private(set) var isRunning = false
    /// True between `stop()` and the next `start()`. Every deferred re-arm
    /// (retry timer, trust notification, `PikoFeature`'s permission hook)
    /// checks it, so a stopped module never installs a tap behind Bench's back.
    private(set) var isStopped = true

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var trustObserver: NSObjectProtocol?
    /// Whether a given key's key-down was consumed, so its key-up can be
    /// consumed too and the system never sees half a press.
    private var downConsumed: [Int: Bool] = [:]

    /// `CGEventType` 14 == `kCGEventSystemDefined` / `NX_SYSDEFINED`.
    private static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`
    private static let auxControlSubtype: Int16 = 8

    /// NX aux key codes (IOKit/hidsystem/ev_keymap.h).
    private enum AuxKey {
        static let soundUp = 0
        static let soundDown = 1
        static let brightnessUp = 2
        static let brightnessDown = 3
        static let mute = 7
    }

    private static let retryInterval: TimeInterval = 5

    deinit {
        if let trustObserver {
            DistributedNotificationCenter.default().removeObserver(trustObserver)
        }
    }

    // MARK: Accessibility

    /// Live check. `PermissionsState.shared.accessibilityTrusted` is the
    /// published mirror the Settings pane shows, but it only refreshes while
    /// something is polling it, so the tap asks the system directly.
    /// Prompting is Bench's job: `PermissionsState.shared.requestAccessibility()`
    /// from the module's "Grant…" button.
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    // MARK: Lifecycle

    /// Installs the event tap. Returns `false` when it cannot be created
    /// (no Accessibility trust); a retry timer keeps trying every 5 s.
    @discardableResult
    func start() -> Bool {
        isStopped = false
        if isRunning { return true }
        observeTrustChanges()

        guard Self.hasAccessibilityPermission else {
            Log.hud.info("Media key tap not installed: no Accessibility trust")
            scheduleRetry()
            return false
        }

        let mask = CGEventMask(1 << Self.systemDefinedEventType)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: refcon
        ) else {
            Log.hud.error("CGEvent.tapCreate failed")
            scheduleRetry()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        isRunning = true
        cancelRetry()
        Log.hud.info("Media key tap installed")
        return true
    }

    /// Full teardown: the tap, its run loop source, the retry timer and the
    /// trust observer all go. A stopped Piko leaves no tap and no timer.
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        downConsumed.removeAll()
        isRunning = false
        cancelRetry()
        if let trustObserver {
            DistributedNotificationCenter.default().removeObserver(trustObserver)
            self.trustObserver = nil
        }
        isStopped = true
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRunning, !self.isStopped else { return }
                _ = self.start()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// `com.apple.accessibility.api` is undocumented but long stable: it fires
    /// when the TCC accessibility list changes, so the tap arms immediately
    /// after the user flips the switch instead of up to 5 s later.
    private func observeTrustChanges() {
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // TCC needs a beat to settle before AXIsProcessTrusted() flips.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let self, !self.isRunning, !self.isStopped else { return }
                    _ = self.start()
                }
            }
        }
    }

    // MARK: Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == Self.auxControlSubtype
        else { return Unmanaged.passUnretained(event) }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let isKeyDown = ((data1 & 0x0000_FF00) >> 8) == 0x0A
        let isRepeat = (data1 & 0x1) == 1

        switch keyCode {
        case AuxKey.soundUp, AuxKey.soundDown, AuxKey.mute,
             AuxKey.brightnessUp, AuxKey.brightnessDown:
            break
        default:
            return Unmanaged.passUnretained(event)   // not ours
        }

        guard isKeyDown else {
            // Mirror whatever happened to the matching key-down.
            let consumed = downConsumed.removeValue(forKey: keyCode) ?? false
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        let flags = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        // Option alone opens System Settings ▸ Sound / Displays natively:
        // let the system have the key. Shift+Option is the fine-step modifier.
        let optionOnly = option && !shift
        let fine = option && shift

        let settings = Settings.shared
        let consumed: Bool
        switch keyCode {
        case AuxKey.soundUp, AuxKey.soundDown:
            consumed = settings.volumeHUDEnabled && !optionOnly
            if consumed { onVolumeStep?(keyCode == AuxKey.soundUp ? 1 : -1, fine, shift) }
        case AuxKey.mute:
            consumed = settings.volumeHUDEnabled && !optionOnly
            // Auto-repeat on mute would flap the state; act on the first press only.
            if consumed && !isRepeat { onMute?() }
        case AuxKey.brightnessUp, AuxKey.brightnessDown:
            consumed = settings.brightnessHUDEnabled && !optionOnly
            if consumed { onBrightnessStep?(keyCode == AuxKey.brightnessUp ? 1 : -1, fine) }
        default:
            consumed = false
        }

        downConsumed[keyCode] = consumed
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}

/// C trampoline. The run loop source lives on the main run loop, so this is
/// always called on the main thread.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { interceptor.handle(type: type, event: event) }
}
