import AppKit
import ApplicationServices

/// Remembers which windows were focused, most recent first, so
/// "Activate Previous Window" can flip between the last two - BetterTouchTool
/// called it "Cycle Two Windows".
///
/// Two sources feed the list, because neither alone sees every switch:
///
/// - `NSWorkspace.didActivateApplicationNotification` catches app switches
///   (⌘⇥, the Dock, clicking another app's window).
/// - a per-app `AXObserver` on `kAXFocusedWindowChangedNotification` catches
///   window switches *inside* an app (⌘`, clicking a second document).
///
/// Observers are created lazily, only for apps that actually come forward,
/// and torn down when the app quits - a Bench that has been running all day
/// holds observers for the handful of apps the user used, not for every
/// process on the machine.
///
/// The list is short (`capacity`) and holds `AXUIElement`s, which go stale
/// silently when a window closes; a stale entry simply fails to activate and
/// is dropped.
@MainActor
final class FocusHistory {
    struct Entry {
        let pid: pid_t
        let window: AXUIElement
    }

    private(set) var entries: [Entry] = []
    private let capacity: Int

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var running = false

    init(capacity: Int = 8) {
        self.capacity = max(2, capacity)
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.applicationActivated(app) }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.applicationTerminated(app) }
        })

        // Seed with whatever is frontmost right now, so the first press after
        // launch already has something to flip away from.
        applicationActivated(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        guard running else { return }
        running = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { center.removeObserver($0) }
        workspaceTokens.removeAll()
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        entries.removeAll()
    }

    /// Called when an app quits, and by `SnapFeature` to drop dead entries.
    func forget(pid: pid_t) {
        entries.removeAll { $0.pid == pid }
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    // MARK: - Recording

    /// Moves `window` to the front of the list, dropping any older mention of
    /// the same window so the list is a most-recent-first set, not a log.
    func record(pid: pid_t, window: AXUIElement) {
        entries.removeAll { CFEqual($0.window, window) }
        entries.insert(Entry(pid: pid, window: window), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    private func applicationActivated(_ app: NSRunningApplication?) {
        guard let app else { return }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        addObserver(for: pid)
        let appElement = AXUIElementCreateApplication(pid)
        if let window = WindowController.element(WindowController.attribute(appElement, kAXFocusedWindowAttribute)) {
            record(pid: pid, window: window)
        }
    }

    private func applicationTerminated(_ app: NSRunningApplication?) {
        guard let app else { return }
        forget(pid: app.processIdentifier)
    }

    // MARK: - Activation

    /// Activates the second entry: the window that had focus before the
    /// current one. Moving it to the front immediately means the next press
    /// comes straight back, however slowly the activation notification
    /// arrives.
    @discardableResult
    func activatePrevious() -> Bool {
        guard entries.count >= 2 else { return false }
        let target = entries[1]
        guard let app = NSRunningApplication(processIdentifier: target.pid) else {
            entries.remove(at: 1)
            return false
        }
        app.activate()
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        entries.remove(at: 1)
        entries.insert(target, at: 0)
        return true
    }

    // MARK: - AX observer

    private func addObserver(for pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let history = Unmanaged<FocusHistory>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            // AX observer callbacks are delivered on the run loop the source
            // was added to - the main one.
            MainActor.assumeIsolated {
                history.record(pid: pid, window: element)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let result = AXObserverAddNotification(
            observer, appElement, kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque())
        guard result == .success else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }
}
