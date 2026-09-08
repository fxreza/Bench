import AppKit
import Combine
import SwiftUI
import BenchCore

/// Trackpad gestures that turn into mouse buttons.
///
/// One gesture so far, the last BetterTouchTool trigger this Mac still needed:
/// **three fingers on the trackpad become the middle mouse button**, either by
/// clicking with three fingers down or by tapping with three fingers, or both.
///
/// How it works, in two independent pieces:
///
/// - `MultitouchMonitor` counts fingers through the private
///   `MultitouchSupport.framework`, loaded with `dlopen` at start and never
///   linked, so a macOS release that drops or renames it costs Bench this
///   module and nothing else. When it cannot load, `isAvailable` is false and
///   the Settings pane says why.
/// - `MiddleClickEngine` owns a `CGEvent` session tap that rewrites
///   `leftMouseDown`/`Dragged`/`Up` into their `otherMouse` equivalents with
///   button 2 while three fingers are down, and posts a synthetic middle click
///   for the tap gesture.
///
/// Accessibility is required: without it the tap cannot modify events, so
/// `start()` does nothing and logs once. The grant is asked for in Bench's
/// Permissions pane, not here.
///
/// If BetterTouchTool is still running with its own "3 finger click ->
/// middle click" trigger, both fire and apps see two middle clicks; the
/// Settings pane says so.
public final class TapFeature: BenchFeature {
    public let id = "tap"
    public let title = "Tap"
    public let symbolName = "hand.tap"
    public let summary = "Three-finger click or tap as middle click"
    public let requiredPermissions: [BenchPermission] = [.accessibility]
    public let hotkeyActions: [HotkeyAction] = []

    /// False when the multitouch bridge could not be brought up on this Mac
    /// (no trackpad, or the private framework would not load). The reason is
    /// in `TapStatus.shared.unavailableReason` and in the Settings pane.
    public var isAvailable: Bool { TapStatus.shared.isAvailable }

    private let settings = TapSettings.shared
    private let engine = MiddleClickEngine()
    private var cancellables: Set<AnyCancellable> = []
    private var wakeObserver: NSObjectProtocol?
    private var isRunning = false

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }

        guard PermissionsState.shared.accessibilityTrusted else {
            TapStatus.shared.accessibilityMissing = true
            TapLog.log.info("Tap not started: no Accessibility trust")
            return
        }
        TapStatus.shared.accessibilityMissing = false
        isRunning = true

        guard engine.start(mode: settings.mode) else {
            TapStatus.shared.unavailableReason = engine.unavailableReason
                ?? "The trackpad could not be watched on this Mac."
            return
        }
        TapStatus.shared.unavailableReason = nil

        settings.$mode
            .dropFirst()
            .sink { [weak self] mode in self?.engine.apply(mode: mode) }
            .store(in: &cancellables)

        // Trackpads come back as new devices after sleep; the callback
        // registered on the old ones is gone.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.handleWake() }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        cancellables.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        engine.stop()
    }

    // MARK: - Menu and Settings

    /// No status menu section: the module has one setting and no action to
    /// invoke by hand.
    public func menuItems() -> [NSMenuItem] { [] }

    public func makeSettingsView() -> AnyView {
        AnyView(TapSettingsView())
    }
}
