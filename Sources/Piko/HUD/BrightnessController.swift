import AppKit
import CoreGraphics

/// Built-in display brightness through the private DisplayServices framework,
/// loaded with `dlopen`/`dlsym` so no private-framework link is recorded in the
/// binary. Verified on macOS 26.6.2 / Apple Silicon: DisplayServices is the only
/// API that works (CoreDisplay's getter is stubbed and returns 1.0, and IOKit's
/// `IODisplayConnect` matches nothing on Apple Silicon).
///
/// `DisplayServicesSetBrightness` is a step change while native key handling
/// ramps smoothly, so this ramps to the target itself over ~0.15 s at 60 Hz.
@MainActor
final class BrightnessController {

    /// Brightness changed by something other than us (Control Center slider,
    /// System Settings, the ambient light sensor). De-duped by rounded percent.
    var onExternalChange: ((Float) -> Void)?

    /// The logical level: a step updates this immediately, before the ramp
    /// has finished writing it to the panel.
    private(set) var level: Float = 0
    private(set) var canControl: Bool = false

    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var registeredDisplayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?
    private var started = false

    private var rampTimer: DispatchSourceTimer?
    private var isRamping = false
    /// Notifications lag our writes slightly; ignore them for a beat afterwards.
    private var suppressExternalUntil: Date = .distantPast
    private var lastNotifiedPercent: Int?

    private let rampQueue = DispatchQueue(label: "com.fxreza.piko.brightness-ramp", qos: .userInteractive)
    private static let rampDuration: TimeInterval = 0.15
    private static let rampHz: Double = 60

    // MARK: DisplayServices symbols

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, CGDirectDisplayID, CFNotificationCallback) -> Int32
    private typealias UnregisterFn = @convention(c) (CGDirectDisplayID, CGDirectDisplayID) -> Int32

    private static let handle: UnsafeMutableRawPointer? = {
        let paths = [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices",
        ]
        for path in paths {
            if let handle = dlopen(path, RTLD_LAZY) { return handle }
        }
        return nil
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let getBrightness = symbol("DisplayServicesGetBrightness", as: GetBrightnessFn.self)
    private static let setBrightness = symbol("DisplayServicesSetBrightness", as: SetBrightnessFn.self)
    private static let canChangeBrightness = symbol("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
    private static let registerNotifications = symbol(
        "DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self)
    private static let unregisterNotifications = symbol(
        "DisplayServicesUnregisterForBrightnessChangeNotifications", as: UnregisterFn.self)

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        resolveDisplay()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolveDisplay() }
        }
    }

    func stop() {
        rampTimer?.cancel()
        rampTimer = nil
        unregisterNotifications()
        brightnessNotificationRelay.setHandler(nil)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        started = false
    }

    // MARK: Public API

    /// Steps to the next 1/16 (or 1/64) grid point and ramps there.
    func step(direction: Int, fine: Bool) {
        guard canControl else { return }
        // Base the step on the logical level so a fast key repeat does not
        // re-snap against a value the ramp has not reached yet.
        let target = HUDStepGrid.next(from: level, direction: direction, fine: fine)
        set(target)
    }

    func set(_ value: Float) {
        guard canControl, let setBrightness = Self.setBrightness else { return }
        let target = min(max(value, 0), 1)
        let start = readLevel() ?? level
        level = target
        lastNotifiedPercent = Int((target * 100).rounded())
        startRamp(from: start, to: target, using: setBrightness)
    }

    /// Re-reads the panel (used at launch and after a display change).
    func refresh() {
        if let value = readLevel() { level = value }
    }

    // MARK: Display

    private func resolveDisplay() {
        unregisterNotifications()
        displayID = Self.builtInDisplayID()
        canControl = Self.handle != nil
            && Self.getBrightness != nil
            && Self.setBrightness != nil
            && (Self.canChangeBrightness?(displayID) ?? true)
        refresh()
        lastNotifiedPercent = Int((level * 100).rounded())
        registerForNotifications()
    }

    private static func builtInDisplayID() -> CGDirectDisplayID {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            return CGMainDisplayID()
        }
        for display in displays.prefix(Int(count)) where CGDisplayIsBuiltin(display) != 0 {
            return display
        }
        return CGMainDisplayID()
    }

    private func readLevel() -> Float? {
        guard let getBrightness = Self.getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return nil }
        return min(max(value, 0), 1)
    }

    // MARK: Ramp

    private func startRamp(from start: Float, to target: Float, using setBrightness: @escaping SetBrightnessFn) {
        rampTimer?.cancel()
        guard abs(target - start) > 1e-4 else {
            _ = setBrightness(displayID, target)
            return
        }

        isRamping = true
        let display = displayID
        let ticks = max(1, Int((Self.rampDuration * Self.rampHz).rounded()))
        let interval = Self.rampDuration / Double(ticks)
        var tick = 0

        let timer = DispatchSource.makeTimerSource(queue: rampQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            tick += 1
            let progress = min(1.0, Double(tick) / Double(ticks))
            // Ease-out cubic, matching the system's post-press ramp shape.
            let eased = 1 - pow(1 - progress, 3)
            _ = setBrightness(display, start + (target - start) * Float(eased))
            guard progress >= 1 else { return }
            timer.cancel()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRamping = false
                    self.suppressExternalUntil = Date().addingTimeInterval(0.3)
                    self.rampTimer = nil
                }
            }
        }
        rampTimer = timer
        timer.resume()
    }

    // MARK: Change notifications

    /// `DisplayServicesRegisterForBrightnessChangeNotifications` works on
    /// macOS 26 (verified): the callback's `userInfo["value"]` is the new
    /// brightness as a number in 0...1. It also fires for ambient-light
    /// changes, so the payload is de-duped by rounded percent and the caller
    /// decides whether a HUD is warranted.
    private func registerForNotifications() {
        guard let register = Self.registerNotifications else { return }
        brightnessNotificationRelay.setHandler { [weak self] value in
            Task { @MainActor in self?.handleExternalChange(value) }
        }
        let status = register(displayID, displayID, brightnessNotificationCallback)
        if status == 0 {
            registeredDisplayID = displayID
        } else {
            Log.hud.error("DisplayServicesRegisterForBrightnessChangeNotifications failed: \(status)")
        }
    }

    private func unregisterNotifications() {
        guard let registeredDisplayID, let unregister = Self.unregisterNotifications else { return }
        _ = unregister(registeredDisplayID, registeredDisplayID)
        self.registeredDisplayID = nil
    }

    private func handleExternalChange(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        let percent = Int((clamped * 100).rounded())
        level = clamped
        guard !isRamping, Date() >= suppressExternalUntil else {
            lastNotifiedPercent = percent
            return
        }
        guard percent != lastNotifiedPercent else { return }
        lastNotifiedPercent = percent
        onExternalChange?(clamped)
    }
}

// MARK: - C callback plumbing

/// The DisplayServices callback is a bare C function pointer with no context,
/// so the handler lives in a lock-protected box that the callback can reach.
private final class BrightnessNotificationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Float) -> Void)?

    func setHandler(_ handler: ((Float) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fire(_ value: Float) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(value)
    }
}

private let brightnessNotificationRelay = BrightnessNotificationRelay()

private let brightnessNotificationCallback: CFNotificationCallback = { _, _, _, _, userInfo in
    guard let info = userInfo as NSDictionary?,
          let value = info["value"] as? Double else { return }
    brightnessNotificationRelay.fire(Float(value))
}
