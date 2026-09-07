import AppKit
import AudioToolbox
import CoreAudio

/// The step grid macOS uses for the volume and brightness keys: 1/16 normally,
/// 1/64 with Shift+Option. A press always *lands on the grid*, so an off-grid
/// value (0.44) snaps to the next grid point (0.5) rather than drifting.
enum HUDStepGrid {
    static let coarse: Float = 1.0 / 16.0
    static let fine: Float = 1.0 / 64.0

    static func size(fine: Bool) -> Float { fine ? Self.fine : coarse }

    /// `direction` is +1 (up) or -1 (down).
    static func next(from current: Float, direction: Int, fine: Bool) -> Float {
        let step = size(fine: fine)
        // The epsilon keeps a value that is already exactly on the grid from
        // being treated as "just past" it by float error.
        let target: Float = direction > 0
            ? ((current / step + 1e-3).rounded(.down) * step) + step
            : ((current / step - 1e-3).rounded(.up) * step) - step
        return min(max(target, 0), 1)
    }
}

/// System output volume via CoreAudio: reads, writes, mute, and property
/// listeners that also catch changes made elsewhere (menu bar slider, System
/// Settings, another app). Re-binds its listeners when the default output
/// device changes (AirPods connecting, headphones plugged in).
@MainActor
final class VolumeController {

    /// `(level 0...1, isMuted)`. Fires on our own steps *and* on external
    /// changes. Our own steps always fire, even at 0 % / 100 % where nothing
    /// actually changes, so the HUD still appears for a swallowed key.
    var onChange: ((Float, Bool) -> Void)?

    private(set) var level: Float = 0
    private(set) var isMuted: Bool = false
    /// False when the current output device exposes no writable volume.
    private(set) var canControl: Bool = false

    private var device: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var hasHardwareMute = false
    /// Level to restore when the device has no hardware mute and we faked it.
    private var softMuteRestore: Float?
    private var lastReported: (level: Float, muted: Bool)?
    private var started = false

    private let feedbackSound = NSSound(
        contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
        byReference: true
    )

    // MARK: Property addresses

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func outputAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    /// `'vmvc'` — the virtual main volume. Present on devices that have no
    /// master element of their own (verified on a Bluetooth speaker here,
    /// where `kAudioDevicePropertyVolumeScalar` main is absent).
    private static let virtualMainVolume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.bindDefaultDevice() }
        }
        systemListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )

        bindDefaultDevice()
        // Prime the de-dupe so binding at launch never flashes a HUD.
        lastReported = (level, isMuted)
    }

    func stop() {
        detachDeviceListeners()
        if let systemListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, systemListener
            )
        }
        systemListener = nil
        started = false
    }

    // MARK: Public API

    /// Steps to the next 1/16 (or 1/64) grid point, exactly like macOS does.
    /// `shiftHeld` only inverts the feedback-click preference.
    func step(direction: Int, fine: Bool, shiftHeld: Bool = false) {
        refreshFromDevice()
        guard canControl else {
            emit(force: true)
            return
        }

        if direction > 0 && isMuted {
            // Volume-up unmutes, matching the system's key handling.
            applyMute(false)
        }

        let target = HUDStepGrid.next(from: level, direction: direction, fine: fine)
        if abs(target - level) > .ulpOfOne {
            if write(volume: target) { level = target }
        }
        playFeedback(shiftHeld: shiftHeld)
        emit(force: true)
    }

    func set(_ value: Float) {
        refreshFromDevice()
        guard canControl else { return }
        let clamped = min(max(value, 0), 1)
        if write(volume: clamped) { level = clamped }
        emit(force: true)
    }

    func toggleMute() {
        refreshFromDevice()
        applyMute(!isMuted)
        emit(force: true)
    }

    /// Re-reads the device and fires `onChange` unconditionally.
    func showCurrentState() {
        refreshFromDevice()
        emit(force: true)
    }

    // MARK: Device binding

    private func bindDefaultDevice() {
        detachDeviceListeners()
        device = Self.defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            canControl = false
            return
        }

        var muteAddress = Self.outputAddress(kAudioDevicePropertyMute)
        hasHardwareMute = AudioObjectHasProperty(device, &muteAddress)
        softMuteRestore = nil

        // Verified here: on a Bluetooth speaker with no main scalar element,
        // the 'vmvc' listener still fires for external changes.
        attach(Self.outputAddress(Self.virtualMainVolume))
        attach(Self.outputAddress(kAudioDevicePropertyVolumeScalar))
        for channel in [1, 2] {
            attach(Self.outputAddress(kAudioDevicePropertyVolumeScalar,
                                      element: AudioObjectPropertyElement(channel)))
        }
        if hasHardwareMute { attach(muteAddress) }

        refreshFromDevice()
        // A device switch should not flash a HUD by itself.
        lastReported = (level, isMuted)
    }

    private func attach(_ address: AudioObjectPropertyAddress) {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshFromDevice()
                self.emit(force: false)
            }
        }
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        deviceListeners.append((address, block))
    }

    private func detachDeviceListeners() {
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            deviceListeners.removeAll()
            return
        }
        for (address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
    }

    // MARK: Reading / writing

    private static func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var address = defaultOutputAddress
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    private func refreshFromDevice() {
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            canControl = false
            return
        }
        if let value = readVolume() {
            level = min(max(value, 0), 1)
            canControl = true
        } else {
            canControl = false
        }
        if hasHardwareMute {
            var address = Self.outputAddress(kAudioDevicePropertyMute)
            var flag: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &flag) == noErr {
                isMuted = flag != 0
            }
        } else {
            isMuted = softMuteRestore != nil
        }
    }

    private func readScalar(_ address: AudioObjectPropertyAddress) -> Float? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var needed: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &needed) == noErr,
              needed == UInt32(MemoryLayout<Float32>.size) else { return nil }
        var value: Float32 = 0
        var size = needed
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Float(value)
    }

    private func readVolume() -> Float? {
        if let value = readScalar(Self.outputAddress(Self.virtualMainVolume)) { return value }
        if let value = readScalar(Self.outputAddress(kAudioDevicePropertyVolumeScalar)) { return value }
        // Some devices (aggregates, many USB DACs) only expose per-channel volume.
        let channels = [1, 2].compactMap {
            readScalar(Self.outputAddress(kAudioDevicePropertyVolumeScalar, element: AudioObjectPropertyElement($0)))
        }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    private func writeScalar(_ address: AudioObjectPropertyAddress, _ value: Float) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = Float32(value)
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        ) == noErr
    }

    private func write(volume: Float) -> Bool {
        if writeScalar(Self.outputAddress(Self.virtualMainVolume), volume) { return true }
        if writeScalar(Self.outputAddress(kAudioDevicePropertyVolumeScalar), volume) { return true }
        var wrote = false
        for channel in [1, 2] {
            let address = Self.outputAddress(kAudioDevicePropertyVolumeScalar,
                                             element: AudioObjectPropertyElement(channel))
            if writeScalar(address, volume) { wrote = true }
        }
        return wrote
    }

    private func applyMute(_ muted: Bool) {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        if hasHardwareMute {
            var address = Self.outputAddress(kAudioDevicePropertyMute)
            var flag: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(
                device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag
            ) == noErr {
                isMuted = muted
            }
            return
        }
        // Software fallback for devices with no mute property.
        guard canControl else { return }
        if muted {
            if softMuteRestore == nil { softMuteRestore = level }
            if write(volume: 0) { level = 0; isMuted = true }
        } else {
            let restore = softMuteRestore ?? level
            softMuteRestore = nil
            if write(volume: restore) { level = restore }
            isMuted = false
        }
    }

    // MARK: Feedback click

    /// macOS stops playing its click once we swallow the key, so replay Apple's
    /// own sample. `com.apple.sound.beep.feedback` (System Settings ▸ Sound ▸
    /// "Play feedback when volume is changed", default on) XOR Shift.
    private func playFeedback(shiftHeld: Bool) {
        let stored = UserDefaults.standard.object(forKey: "com.apple.sound.beep.feedback")
        let preferenceOn = (stored as? NSNumber)?.intValue ?? 1
        guard (preferenceOn == 1) != shiftHeld, let feedbackSound else { return }
        feedbackSound.stop()   // restart on key repeats instead of dropping the click
        feedbackSound.play()
    }

    // MARK: Emitting

    private func emit(force: Bool) {
        if !force, let last = lastReported,
           abs(last.level - level) < 1e-4, last.muted == isMuted {
            return
        }
        lastReported = (level, isMuted)
        onChange?(level, isMuted)
    }
}
