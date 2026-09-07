import AppKit
import ApplicationServices
import Combine

/// Decides whether the notch panel may be on screen.
///
/// Two independent signals, each behind its own setting:
/// - **Fullscreen** (`Settings.hideInFullscreen`): the active space's type,
///   read through SkyLight (`SLSMainConnectionID` / `SLSGetActiveSpace` /
///   `SLSSpaceGetType`, resolved with `dlsym` so a missing symbol only costs
///   the feature). Re-evaluated on `activeSpaceDidChangeNotification`. If the
///   symbols are unavailable it falls back to asking whether the frontmost app
///   owns a window the size of the screen.
/// - **Mission Control / App Exposé** (`Settings.hideInMissionControl`): the
///   Dock owns an on-screen window at `kCGWindowLayer == 18` while the overlay
///   is up. Polled every 250 ms, with an AX observer on the Dock as the fast
///   edge trigger when Accessibility is granted.
@MainActor
final class VisibilityMonitor {

    /// Called with `false` when the notch must disappear, `true` when it may
    /// come back. Only called on change.
    var onVisibilityChange: ((Bool) -> Void)?

    private(set) var isVisible = true

    private var isFullscreen = false
    private var isMissionControl = false

    private var spaceObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var settingsCancellables: Set<AnyCancellable> = []

    private var axObserver: AXObserver?
    private var axDockPID: pid_t?

    /// Mission Control / Exposé put a Dock-owned window at this layer.
    private static let missionControlWindowLayer = 18
    private static let pollInterval: TimeInterval = 0.25

    // MARK: - Lifecycle

    func start() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }

        // The Dock relaunches (crash, `killall Dock`): re-attach the observer.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.dock" else { return }
                MainActor.assumeIsolated {
                    self?.teardownAXObserver()
                    self?.setUpAXObserver()
                    self?.evaluate()
                }
            }
            appObservers.append(token)
        }

        Settings.shared.$hideInFullscreen
            .combineLatest(Settings.shared.$hideInMissionControl)
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            .store(in: &settingsCancellables)

        setUpAXObserver()
        startPolling()
        evaluate()
    }

    func stop() {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        for token in appObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        appObservers.removeAll()
        settingsCancellables.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        teardownAXObserver()
    }

    deinit {
        pollTimer?.invalidate()
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(axObserver),
                                  .defaultMode)
        }
    }

    // MARK: - Evaluation

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        // .common so the poll keeps running while a menu or a drag is up.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard Settings.shared.hideInMissionControl else {
            if isMissionControl {
                isMissionControl = false
                publish()
            }
            return
        }
        let up = Self.dockShowsOverlayWindow()
        guard up != isMissionControl else { return }
        isMissionControl = up
        publish()
    }

    /// Full re-check of both signals.
    func evaluate() {
        isFullscreen = Settings.shared.hideInFullscreen ? Self.activeSpaceIsFullscreen() : false
        isMissionControl = Settings.shared.hideInMissionControl ? Self.dockShowsOverlayWindow() : false
        publish()
    }

    private func publish() {
        let hide = (Settings.shared.hideInFullscreen && isFullscreen)
            || (Settings.shared.hideInMissionControl && isMissionControl)
        let visible = !hide
        guard visible != isVisible else { return }
        isVisible = visible
        Log.notch.debug("visibility -> \(visible ? "shown" : "hidden", privacy: .public)")
        onVisibilityChange?(visible)
    }

    // MARK: - Fullscreen

    private static func activeSpaceIsFullscreen() -> Bool {
        if let type = SkyLight.activeSpaceType() {
            // 0 user, 2 system, 4 fullscreen.
            return type == 4
        }
        return frontmostAppCoversScreen()
    }

    /// Fallback when SkyLight is unavailable: the frontmost app owns a
    /// normal-layer window the size of the notch screen.
    private static func frontmostAppCoversScreen() -> Bool {
        guard let screen = NotchGeometry.preferredScreen(),
              let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = front.processIdentifier
        let frame = screen.frame
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }
            if width >= frame.width - 1, height >= frame.height - 1 { return true }
        }
        return false
    }

    // MARK: - Mission Control

    private static func dockShowsOverlayWindow() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for window in windows {
            guard (window[kCGWindowOwnerName as String] as? String) == "Dock",
                  (window[kCGWindowLayer as String] as? Int) == missionControlWindowLayer
            else { continue }
            return true
        }
        return false
    }

    private func setUpAXObserver() {
        // Without the Accessibility grant the 250 ms poll is the only signal.
        guard AXIsProcessTrusted() else { return }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let pid = dock.processIdentifier

        var observer: AXObserver?
        guard AXObserverCreate(pid, notchAXObserverCallback, &observer) == .success,
              let observer else { return }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows",
                     "AXExposeShowDesktop", "AXExposeExit"] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        axDockPID = pid
    }

    private func teardownAXObserver() {
        guard let axObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(axObserver),
                              .defaultMode)
        self.axObserver = nil
        axDockPID = nil
    }

    /// Called from the AX callback: the edge is immediate, the poll confirms.
    fileprivate func handleExposeNotification(_ name: String) {
        guard Settings.shared.hideInMissionControl else { return }
        let up = name != "AXExposeExit"
        guard up != isMissionControl else { return }
        isMissionControl = up
        publish()
    }
}

/// AX callbacks are C function pointers, so this cannot be a method.
private func notchAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<VisibilityMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    DispatchQueue.main.async {
        MainActor.assumeIsolated { monitor.handleExposeNotification(name) }
    }
}

// MARK: - SkyLight

/// The three private SkyLight entry points needed to classify the active
/// space, resolved lazily with `dlsym`. Missing symbols disable the feature
/// rather than crashing the app.
private enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias SpaceGetType = @convention(c) (Int32, UInt64) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
    private static let getActiveSpace = symbol("SLSGetActiveSpace", as: GetActiveSpace.self)
    private static let spaceGetType = symbol("SLSSpaceGetType", as: SpaceGetType.self)

    /// 0 user, 2 system, 4 fullscreen. Nil when SkyLight is unavailable.
    static func activeSpaceType() -> Int32? {
        guard let mainConnectionID, let getActiveSpace, let spaceGetType else { return nil }
        let connection = mainConnectionID()
        let space = getActiveSpace(connection)
        guard space != 0 else { return nil }
        return spaceGetType(connection, space)
    }
}
