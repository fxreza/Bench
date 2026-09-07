import AppKit
import BenchCore
import Combine
import SwiftUI

/// Piko: a Dynamic Island for the MacBook notch.
///
/// This is the whole of the standalone app's `AppDelegate` folded into a
/// `BenchFeature`: it builds the notch panel and its view model, the HUD
/// coordinator (media key tap + volume/brightness controllers), the
/// now-playing service (a `/usr/bin/perl` mediaremote-adapter subprocess), the
/// Bluetooth and battery monitors, and the fullscreen / Mission Control
/// visibility monitor, and wires them to the view model.
///
/// `start()` is idempotent and `stop()` is total: no panel, no event tap, no
/// perl subprocess, no timers and no observers survive it.
@MainActor
public final class PikoFeature: BenchFeature {
    public let id = "piko"
    public let title = "Piko"
    public let symbolName = "sparkles.rectangle.stack"
    public let summary = "Dynamic Island for the notch: HUDs, now playing, devices, battery"
    /// The media key tap needs Accessibility. Bluetooth is prompted for by
    /// CoreBluetooth on first use and is not one of `BenchPermission`'s cases.
    public let requiredPermissions: [BenchPermission] = [.accessibility]
    /// Piko has no rebindable global shortcuts: it reacts to the hardware
    /// media keys through an event tap, which is not a Carbon hotkey.
    public let hotkeyActions: [HotkeyAction] = []

    // MARK: - Owned objects

    private var notchController: NotchWindowController?
    private var visibilityMonitor: VisibilityMonitor?
    private var hud: HUDCoordinator?
    private var bluetoothMonitor: BluetoothMonitor?
    private var batteryMonitor: BatteryMonitor?
    private var nowPlaying: NowPlayingService?
    private var cancellables = Set<AnyCancellable>()

    private var isRunning = false
    /// `PermissionsState.onAccessibilityBecameTrusted` has no removal handle,
    /// so the hook is appended once per feature instance and stays for the
    /// life of the process rather than growing on every start/stop cycle.
    private var didRegisterAccessibilityHook = false
    private lazy var menuTarget = MenuTarget(feature: self)

    private var settings: Settings { Settings.shared }

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Log.app.info("Piko started")

        let controller = NotchWindowController()
        notchController = controller

        setUpNowPlaying(controller.viewModel)
        controller.show()

        setUpHUD(controller.viewModel)
        setUpDevices(controller.viewModel)
        setUpVisibility(controller)
        observeAccessibility()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        cancellables.removeAll()

        hud?.stop()
        hud = nil
        nowPlaying?.stop()
        nowPlaying = nil
        bluetoothMonitor?.stop()
        bluetoothMonitor = nil
        batteryMonitor?.stop()
        batteryMonitor = nil
        visibilityMonitor?.stop()
        visibilityMonitor = nil
        notchController?.teardown()
        notchController = nil

        Log.app.info("Piko stopped")
    }

    // MARK: - HUD

    private func setUpHUD(_ viewModel: NotchViewModel) {
        let hud = HUDCoordinator()
        self.hud = hud
        hud.onHUD = { [weak self, weak viewModel] payload in
            guard let self, let viewModel else { return }
            switch payload.kind {
            case .volume: guard self.settings.volumeHUDEnabled else { return }
            case .brightness: guard self.settings.brightnessHUDEnabled else { return }
            }
            viewModel.show(.hud(payload))
        }
        hud.start()
    }

    // MARK: - Now playing

    private func setUpNowPlaying(_ viewModel: NotchViewModel) {
        let service = NowPlayingService()
        nowPlaying = service
        viewModel.mediaController = service

        service.$info
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak viewModel] info in
                guard let self, let viewModel else { return }
                viewModel.nowPlaying = self.settings.nowPlayingEnabled ? info : nil
            }
            .store(in: &cancellables)

        service.onTrackChange = { [weak self, weak viewModel] info in
            guard let self, let viewModel, self.settings.nowPlayingEnabled else { return }
            viewModel.showTrackPeek(info)
        }

        // Starts the perl subprocess when the switch is on, and kills it the
        // moment it is switched off. `@Published` replays the current value,
        // so this is also what starts the stream at launch.
        settings.$nowPlayingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak viewModel, weak service] enabled in
                guard let self, let service, self.isRunning else { return }
                if enabled {
                    service.start()
                } else {
                    service.stop()
                    viewModel?.nowPlaying = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Devices / battery

    private func setUpDevices(_ viewModel: NotchViewModel) {
        let bluetooth = BluetoothMonitor()
        bluetoothMonitor = bluetooth
        bluetooth.onEvent = { [weak self, weak viewModel] event in
            guard let self, let viewModel, self.settings.connectivityEnabled else { return }
            viewModel.show(.device(event))
        }
        bluetooth.start()

        let battery = BatteryMonitor()
        batteryMonitor = battery
        battery.onLowBattery = { [weak self, weak viewModel] status in
            guard let self, let viewModel, self.settings.lowBatteryEnabled else { return }
            viewModel.show(.lowBattery(status))
        }
        battery.start()
    }

    // MARK: - Visibility (fullscreen / Mission Control)

    private func setUpVisibility(_ controller: NotchWindowController) {
        let monitor = VisibilityMonitor()
        visibilityMonitor = monitor
        monitor.onVisibilityChange = { [weak controller] visible in
            controller?.setVisible(visible)
        }
        monitor.start()
    }

    // MARK: - Accessibility

    /// Re-arms the media key tap when the Accessibility grant appears while
    /// Bench is running.
    ///
    /// `PermissionsState.onAccessibilityBecameTrusted` is an append-only array
    /// with no removal handle, so the closure is registered once, carries a
    /// weak reference and checks `isRunning`: after `stop()` it becomes a
    /// no-op instead of re-installing a tap for a switched-off module.
    /// (`MediaKeyInterceptor` also watches `com.apple.accessibility.api`
    /// itself, which is the path that fires when nothing is polling
    /// `PermissionsState` - it only refreshes while a window asks it to.)
    private func observeAccessibility() {
        guard !didRegisterAccessibilityHook else { return }
        didRegisterAccessibilityHook = true
        PermissionsState.shared.onAccessibilityBecameTrusted.append { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, let hud = self.hud else { return }
                guard !hud.isIntercepting else { return }
                Log.hud.info("Accessibility granted; re-arming the media key tap")
                hud.interceptor.start()
            }
        }
    }

    // MARK: - Status menu

    /// Rebuilt on every menu open, so the check marks always show the current
    /// switch states. Piko no longer has a status item of its own, so the
    /// panel's most-used switches live here and the rest in Settings.
    public func menuItems() -> [NSMenuItem] {
        let hudState: NSControl.StateValue
        switch (settings.volumeHUDEnabled, settings.brightnessHUDEnabled) {
        case (true, true): hudState = .on
        case (false, false): hudState = .off
        default: hudState = .mixed
        }

        return [
            item("HUDs", action: #selector(MenuTarget.toggleHUDs), state: hudState),
            item("Now Playing", action: #selector(MenuTarget.toggleNowPlaying),
                 state: settings.nowPlayingEnabled ? .on : .off),
            item("Devices", action: #selector(MenuTarget.toggleDevices),
                 state: settings.connectivityEnabled ? .on : .off),
            item("Battery", action: #selector(MenuTarget.toggleBattery),
                 state: settings.lowBatteryEnabled ? .on : .off),
            .separator(),
            item("Piko Settings…", action: #selector(MenuTarget.openSettings), state: .off),
        ]
    }

    private func item(_ title: String, action: Selector, state: NSControl.StateValue) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = menuTarget
        item.state = state
        return item
    }

    fileprivate func toggleHUDs() {
        let turnOn = !(settings.volumeHUDEnabled && settings.brightnessHUDEnabled)
        settings.volumeHUDEnabled = turnOn
        settings.brightnessHUDEnabled = turnOn
    }

    fileprivate func toggleNowPlaying() { settings.nowPlayingEnabled.toggle() }
    fileprivate func toggleDevices() { settings.connectivityEnabled.toggle() }
    fileprivate func toggleBattery() { settings.lowBatteryEnabled.toggle() }

    // MARK: - Settings pane

    public func makeSettingsView() -> AnyView {
        AnyView(PikoSettingsView())
    }
}

/// `NSMenuItem.target` is unowned, and a menu item cannot target a non-`NSObject`
/// Swift class, so the feature keeps this small trampoline alive for the life
/// of the module.
@MainActor
private final class MenuTarget: NSObject {
    private weak var feature: PikoFeature?

    init(feature: PikoFeature) {
        self.feature = feature
        super.init()
    }

    @objc func toggleHUDs() { feature?.toggleHUDs() }
    @objc func toggleNowPlaying() { feature?.toggleNowPlaying() }
    @objc func toggleDevices() { feature?.toggleDevices() }
    @objc func toggleBattery() { feature?.toggleBattery() }
    @objc func openSettings() { BenchSettings.open(.feature("piko")) }
}
