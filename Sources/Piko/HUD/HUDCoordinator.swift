import AppKit

/// Owns the media key tap and the two controllers, and turns every volume /
/// brightness change into a `HUDPayload` for the notch.
///
/// Wiring in `AppDelegate`:
/// ```swift
/// hud.onHUD = { [weak self] payload in self?.viewModel.show(.hud(payload)) }
/// hud.start()
/// ```
@MainActor
final class HUDCoordinator {

    var onHUD: ((HUDPayload) -> Void)?

    let interceptor = MediaKeyInterceptor()
    let volume = VolumeController()
    let brightness = BrightnessController()

    /// True when the media key tap is installed (Accessibility granted).
    var isIntercepting: Bool { interceptor.isRunning }

    /// External brightness changes only warrant a HUD if they closely follow a
    /// brightness key press; ambient-light drift must never pop the notch.
    private var lastBrightnessKey: Date = .distantPast
    private static let brightnessKeyWindow: TimeInterval = 1.0

    private var started = false

    func start() {
        guard !started else { return }
        started = true

        volume.onChange = { [weak self] level, isMuted in
            guard let self, Settings.shared.volumeHUDEnabled else { return }
            self.onHUD?(HUDPayload(kind: .volume, level: Double(level), isMuted: isMuted))
        }
        brightness.onExternalChange = { [weak self] level in
            guard let self, Settings.shared.brightnessHUDEnabled else { return }
            guard Date().timeIntervalSince(self.lastBrightnessKey) < Self.brightnessKeyWindow else { return }
            self.emitBrightness(level)
        }

        interceptor.onVolumeStep = { [weak self] direction, fine, shiftHeld in
            self?.volume.step(direction: direction, fine: fine, shiftHeld: shiftHeld)
        }
        interceptor.onMute = { [weak self] in
            self?.volume.toggleMute()
        }
        interceptor.onBrightnessStep = { [weak self] direction, fine in
            guard let self else { return }
            self.lastBrightnessKey = Date()
            self.brightness.step(direction: direction, fine: fine)
            // The panel ramps over ~0.15 s and our own writes are suppressed in
            // the notification path, so show the target immediately. This is
            // also what makes a key press at 0 % / 100 % still show a HUD.
            guard Settings.shared.brightnessHUDEnabled else { return }
            self.emitBrightness(self.brightness.level)
        }

        volume.start()
        brightness.start()
        _ = interceptor.start()
    }

    func stop() {
        interceptor.stop()
        volume.stop()
        brightness.stop()
        started = false
    }

    private func emitBrightness(_ level: Float) {
        onHUD?(HUDPayload(kind: .brightness, level: Double(level), isMuted: false))
    }
}
