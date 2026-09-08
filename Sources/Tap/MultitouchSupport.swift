import Foundation
import os
import BenchCore

/// Tap's log category. The subsystem is Bench's, the category keeps the
/// module prefix so `log show --predicate 'category == "tap"'` isolates it.
nonisolated enum TapLog {
    static let log = Logger(subsystem: "com.fxreza.bench", category: "tap")
}

// MARK: - The private framework, as C sees it

// `MultitouchSupport.framework` is a private Apple framework: it is not in
// any SDK, it has no headers, and Apple is free to change or remove it. Bench
// therefore never links it. Every symbol is resolved with `dlopen`/`dlsym` at
// start, and a missing library or a missing symbol only means the Tap module
// reports itself unavailable - the app still launches.
//
// The struct layout below is reconstructed from the community headers used by
// MiddleClick (github.com/artginzburg/MiddleClick), everypinch,
// hs._asm.undocumented.touchdevice and OpenMultitouchSupport. It has been
// stable since 10.5. `MultitouchMonitor.start()` checks the size at runtime
// (`MTTouch.expectedStride`) and refuses to register the callback if the
// compiler laid the struct out differently than C would, rather than reading
// past the end of Apple's buffer.

/// `typedef struct { float x; float y; } MTPoint;` - a point in the pad's
/// normalized coordinate space (0...1 across the trackpad surface) when it
/// comes from `normalizedVector`, and in millimetres when it comes from
/// `absoluteVector`.
nonisolated struct MTPoint {
    var x: Float
    var y: Float
}

/// `typedef struct { MTPoint position; MTPoint velocity; } MTVector;`
nonisolated struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// One contact in one frame, `MTTouch` in the community headers (older ones
/// call it `Finger`). 96 bytes, 8-byte aligned. Field order and sizes must
/// match exactly: the callback receives a raw C array of these.
///
/// | offset | field | C type | meaning |
/// |---|---|---|---|
/// | 0  | `frame`            | `int`      | frame number this touch belongs to |
/// | 8  | `timestamp`        | `double`   | mach-time seconds, monotonic (4 bytes of padding sit before it) |
/// | 16 | `identifier`       | `int`      | path id, stable while one finger stays down |
/// | 20 | `stage`            | `int` enum | `MTPathStage`: not tracking / start / hover / make touch / touching / break touch / linger / out of range |
/// | 24 | `fingerID`         | `int`      | Apple's guess at which finger this is |
/// | 28 | `handID`           | `int`      | Apple's guess at which hand |
/// | 32 | `normalizedVector` | `MTVector` | position 0...1 across the pad plus its velocity; the tap detector measures movement in these units |
/// | 48 | `total`            | `float`    | total contact size |
/// | 52 | `pressure`         | `float`    | contact pressure (0 on Force Touch pads) |
/// | 56 | `angle`            | `float`    | ellipse rotation, radians |
/// | 60 | `majorAxis`        | `float`    | ellipse major axis, mm |
/// | 64 | `minorAxis`        | `float`    | ellipse minor axis, mm |
/// | 68 | `absoluteVector`   | `MTVector` | position and velocity in mm |
/// | 84 | `unknown14`        | `int`      | undocumented |
/// | 88 | `unknown15`        | `int`      | undocumented |
/// | 92 | `density`          | `float`    | contact density |
nonisolated struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var stage: Int32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var total: Float
    var pressure: Float
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var unknown14: Int32
    var unknown15: Int32
    var density: Float

    /// What C computes for this struct: 96 bytes with the 4 bytes of padding
    /// between `frame` and `timestamp`. Checked at start.
    static let expectedStride = 96
}

/// Opaque `MTDeviceRef`. A CoreFoundation object, so `CFRetain`/`CFRelease`
/// apply to it, but Swift is never told its type.
typealias MTDeviceRef = UnsafeMutableRawPointer

/// `void (*MTFrameCallbackFunction)(MTDeviceRef, MTTouch[], int, double, int)`.
/// Called on a private serial thread the framework owns, never on main.
/// `touches` is `MTTouch *`; it is declared raw because `@convention(c)`
/// function types may only mention types C itself could have written, and
/// `MTTouch` is a Swift struct as far as the compiler is concerned. The
/// callback binds it back with `assumingMemoryBound(to:)` after
/// `MultitouchMonitor.start()` has checked the layout.
typealias MTFrameCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Void

// MARK: - dlopen bridge

/// The handful of `MultitouchSupport` entry points Tap needs, resolved once
/// with `dlsym`. `load()` returns nil when the framework is absent or has
/// dropped a symbol, which is the only failure mode Tap has to handle.
nonisolated final class MultitouchBridge: @unchecked Sendable {
    typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    typealias Register = @convention(c) (MTDeviceRef, MTFrameCallback) -> Bool
    typealias Unregister = @convention(c) (MTDeviceRef, MTFrameCallback) -> Bool
    typealias Start = @convention(c) (MTDeviceRef, Int32) -> Void
    typealias Stop = @convention(c) (MTDeviceRef) -> Void
    typealias Release = @convention(c) (MTDeviceRef) -> Void

    static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    let createList: CreateList
    let register: Register
    let unregister: Unregister
    let deviceStart: Start
    let deviceStop: Stop
    let deviceRelease: Release

    /// The handle is deliberately never `dlclose`d: the framework starts
    /// threads of its own, and unloading it under them would crash.
    private let handle: UnsafeMutableRawPointer

    private init?(handle: UnsafeMutableRawPointer) {
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        guard let createList = symbol("MTDeviceCreateList", CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", Register.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", Unregister.self),
              let deviceStart = symbol("MTDeviceStart", Start.self),
              let deviceStop = symbol("MTDeviceStop", Stop.self),
              let deviceRelease = symbol("MTDeviceRelease", Release.self)
        else { return nil }
        self.handle = handle
        self.createList = createList
        self.register = register
        self.unregister = unregister
        self.deviceStart = deviceStart
        self.deviceStop = deviceStop
        self.deviceRelease = deviceRelease
    }

    /// Loads the framework once. `nil` means "no multitouch support on this
    /// Mac", which the Settings pane reports verbatim.
    static func load() -> MultitouchBridge? {
        if let cached { return cached }
        guard let handle = dlopen(path, RTLD_LAZY) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            TapLog.log.error("dlopen(MultitouchSupport) failed: \(reason, privacy: .public)")
            return nil
        }
        guard let bridge = MultitouchBridge(handle: handle) else {
            TapLog.log.error("MultitouchSupport is missing an expected symbol")
            return nil
        }
        cached = bridge
        return bridge
    }

    private nonisolated(unsafe) static var cached: MultitouchBridge?
}

// MARK: - Device monitor

/// Watches every multitouch device and keeps two things the rest of Tap asks
/// for: how many fingers of one hand are on the pad right now, and whether
/// the last touch was a quick three-finger tap.
///
/// Every frame goes through `ContactFilter` first, which drops hovering
/// contacts and palms and groups the rest by hand, so `fingerCount` is the
/// size of the gesture cluster rather than the raw contact count. Without
/// that step a palm resting on the pad either cancels the gesture (four
/// contacts) or completes it by accident (palm plus two fingers).
///
/// The framework calls `handle(touches:)` on its own thread, so all mutable
/// state sits behind `lock` and nothing here touches AppKit. `onTap` is
/// likewise called on that thread; `MiddleClickEngine` hops to the main queue
/// before posting anything.
///
/// Set `tap.logContacts` to true in Bench's defaults to have every change in
/// the raw contact count logged with each contact's stage, size and position,
/// for tuning `ContactFilter.Config` against a particular trackpad:
///
///     defaults write com.fxreza.bench tap.logContacts -bool YES
///     /usr/bin/log stream --info --predicate 'category == "tap"'
///
/// A singleton because the C callback has no user-data parameter to carry an
/// instance pointer; `start()` / `stop()` still leave nothing running.
nonisolated final class MultitouchMonitor: @unchecked Sendable {
    static let shared = MultitouchMonitor()

    /// Why the monitor could not start, for the Settings pane. Nil while it
    /// is running or has not been started.
    private(set) var unavailableReason: String?

    private let lock = NSLock()
    private var bridge: MultitouchBridge?
    private var devices: [MTDeviceRef] = []
    private var isRunning = false

    /// Defaults key for the contact log; read once at `start()`.
    static let logContactsKey = "tap.logContacts"

    // Guarded by `lock`.
    private var _fingerCount = 0
    private var filter = ContactFilter()
    private var detector = TapDetector()
    private var logContacts = false
    private var lastRawCount = 0
    private var tapDetectionEnabled = false
    private var tapHandler: (() -> Void)?

    private init() {}

    /// Fingers of the gesture cluster currently on the pad, after palm
    /// rejection. Read from the event tap callback on the main thread.
    var fingerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _fingerCount
    }

    /// Called on the framework's thread when a three-finger tap completes.
    func setTapHandler(_ handler: (() -> Void)?) {
        lock.lock()
        tapHandler = handler
        lock.unlock()
    }

    /// Whether the tap gesture should be looked for at all. Click conversion
    /// only needs `fingerCount`, so the detector is left idle in click mode.
    func setTapDetectionEnabled(_ enabled: Bool) {
        lock.lock()
        tapDetectionEnabled = enabled
        detector.reset()
        lock.unlock()
    }

    /// Tells the detector a physical click happened during the current
    /// touch, which disqualifies it as a tap.
    func noteClick() {
        lock.lock()
        detector.noteClick()
        lock.unlock()
    }

    // MARK: Lifecycle

    /// Loads the framework, enumerates the devices and registers the frame
    /// callback. Returns false and fills `unavailableReason` when there is
    /// no multitouch hardware or the framework would not load.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        guard MTTouch.expectedStride == MemoryLayout<MTTouch>.stride else {
            unavailableReason = "The multitouch frame layout is not what this build expects "
                + "(\(MemoryLayout<MTTouch>.stride) bytes, expected \(MTTouch.expectedStride))."
            TapLog.log.error("MTTouch stride mismatch: \(MemoryLayout<MTTouch>.stride)")
            return false
        }
        guard let bridge = MultitouchBridge.load() else {
            unavailableReason = "macOS did not load MultitouchSupport.framework, "
                + "so Bench cannot count fingers on the trackpad."
            return false
        }
        self.bridge = bridge

        let devices = Self.enumerateDevices(bridge)
        guard !devices.isEmpty else {
            unavailableReason = "No multitouch trackpad was found on this Mac."
            TapLog.log.info("MTDeviceCreateList returned no devices")
            return false
        }

        self.devices = devices
        lock.lock()
        logContacts = BenchDefaults.standard.bool(forKey: Self.logContactsKey)
        lastRawCount = 0
        filter.reset()
        detector.reset()
        lock.unlock()
        for device in devices {
            _ = bridge.register(device, mtFrameCallback)
            bridge.deviceStart(device, 0)
        }
        isRunning = true
        unavailableReason = nil
        TapLog.log.info("Multitouch monitor started on \(devices.count, privacy: .public) device(s)")
        return true
    }

    /// Unregisters the callback, stops and releases every device. After this
    /// the framework holds no reference back into Bench.
    func stop() {
        guard let bridge else { return }
        for device in devices {
            _ = bridge.unregister(device, mtFrameCallback)
            bridge.deviceStop(device)
            bridge.deviceRelease(device)
        }
        devices = []
        isRunning = false
        lock.lock()
        _fingerCount = 0
        filter.reset()
        detector.reset()
        lock.unlock()
    }

    /// Devices vanish and come back across sleep; re-enumerating is the only
    /// way to get frames again.
    func restart() {
        guard isRunning else { return }
        stop()
        _ = start()
    }

    /// `MTDeviceCreateList` hands back a `CFMutableArray` it owns. The array
    /// is released here, so each device is retained once on the way out and
    /// balanced by `MTDeviceRelease` in `stop()`.
    private static func enumerateDevices(_ bridge: MultitouchBridge) -> [MTDeviceRef] {
        guard let list = bridge.createList()?.takeRetainedValue() else { return [] }
        var devices: [MTDeviceRef] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
            devices.append(device)
        }
        return devices
    }

    // MARK: Frames

    /// One multitouch frame, on the framework's thread. Keep it short: it
    /// runs at the pad's report rate (~120 Hz) and blocks the driver.
    fileprivate func handle(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        var contacts: [ContactFilter.Contact] = []
        if let touches, count > 0 {
            contacts.reserveCapacity(count)
            for index in 0..<count {
                let touch = touches[index]
                contacts.append(ContactFilter.Contact(
                    id: touch.identifier,
                    stage: touch.stage,
                    majorAxis: touch.majorAxis,
                    total: touch.total,
                    position: touch.normalizedVector.position,
                    absolute: touch.absoluteVector.position))
            }
        }

        lock.lock()
        let frame = filter.update(contacts: contacts)
        _fingerCount = frame.fingerCount
        var fire = false
        if tapDetectionEnabled {
            let outcome = detector.update(
                fingerCount: frame.fingerCount, sumX: frame.sumX, sumY: frame.sumY,
                timestamp: timestamp)
            fire = outcome == .middleClick
        }
        let handler = fire ? tapHandler : nil
        let logLine: String? = if logContacts, contacts.count != lastRawCount {
            Self.describe(touches: touches, count: count, frame: frame)
        } else {
            nil
        }
        lastRawCount = contacts.count
        lock.unlock()

        if let logLine { TapLog.log.info("\(logLine, privacy: .public)") }
        handler?()
    }

    /// One line per change in the raw contact count: what the pad reported
    /// and what the filter made of it. Only built when `tap.logContacts` is
    /// on, so the hot path never formats strings otherwise.
    private static func describe(
        touches: UnsafeMutablePointer<MTTouch>?, count: Int, frame: ContactFilter.Frame
    ) -> String {
        var line = "contacts=\(max(0, count)) fingers=\(frame.fingerCount)"
        guard let touches, count > 0 else { return line }
        for index in 0..<count {
            let t = touches[index]
            let n = t.normalizedVector.position
            let a = t.absoluteVector.position
            line += String(
                format: " | id=%d st=%d hand=%d maj=%.1f min=%.1f tot=%.2f abs=(%.1f,%.1f) norm=(%.3f,%.3f)",
                t.identifier, t.stage, t.handID, t.majorAxis, t.minorAxis, t.total,
                a.x, a.y, n.x, n.y)
        }
        return line
    }
}

/// C trampoline. `MTFrameCallbackFunction` carries no user-data pointer, so
/// it goes through the singleton.
private nonisolated func mtFrameCallback(
    device: MTDeviceRef?,
    touches: UnsafeMutableRawPointer?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) {
    let typed = touches?.assumingMemoryBound(to: MTTouch.self)
    MultitouchMonitor.shared.handle(touches: typed, count: Int(numTouches), timestamp: timestamp)
}
