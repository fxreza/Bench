import Foundation
import CoreAudio
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.hid
import IOKit.ps

/// Watches for Bluetooth / audio device connect and disconnect events and
/// reports them as `DeviceEvent`s, filling in battery for AirPods-like
/// devices when it becomes available.
///
/// Three detection sources, deduplicated by name (see docs/research/glint-analysis.md
/// section 5 and docs/research/tech-reference.md sections 6.1/6.2 for the
/// underlying APIs):
///  1. `IOBluetoothDevice` connect notifications + a per-device disconnect
///     notification (re-armed on every connect).
///  2. `IOHIDManager` device-arrival, for BLE-only HID devices (keyboards /
///     mice / trackpads that never touch classic IOBluetooth).
///  3. CoreAudio's default output device switching to a Bluetooth transport
///     (catches AirPods-style audio routing with no Bluetooth permission at all).
///
/// IOBluetooth (source 1) crashes the process if `CBCentralManager.authorization`
/// is `.denied` / `.restricted` and Piko still calls into it, so that case
/// skips IOBluetooth and IOHIDManager entirely and relies only on CoreAudio.
@MainActor
final class BluetoothMonitor: NSObject {
    var onEvent: ((DeviceEvent) -> Void)?

    private var isRunning = false
    private var startupDeadline = Date.distantFuture

    // IOBluetooth
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    // IOHIDManager (BLE-only HID accessories)
    private var hidManager: IOHIDManager?

    // CoreAudio default-output listener
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    // Dedup: "name|connect" / "name|disconnect" -> last announce time.
    private var recentlyAnnounced: [String: Date] = [:]

    private static let dedupeWindow: TimeInterval = 5
    private static let startupGrace: TimeInterval = 5
    private static let batteryRetryCount = 5
    private static let batteryRetryDelay: UInt64 = 500_000_000 // 0.5 s

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startupDeadline = Date().addingTimeInterval(Self.startupGrace)
        recentlyAnnounced.removeAll()

        if Self.isBluetoothAuthorized() {
            startIOBluetooth()
            startHIDManager()
        } else {
            Log.devices.info("Bluetooth authorization denied/restricted; using CoreAudio route only")
        }
        startCoreAudioListener()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()

        if let hidManager {
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil

        stopCoreAudioListener()
        recentlyAnnounced.removeAll()
    }

    // MARK: - Authorization

    private static func isBluetoothAuthorized() -> Bool {
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            return false
        case .allowedAlways, .notDetermined:
            return true
        @unknown default:
            return true
        }
    }

    // MARK: - IOBluetooth

    private func startIOBluetooth() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(handleConnectNotification(_:device:)))

        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
        where device.isConnected() {
            armDisconnectNotification(for: device)
        }
    }

    @objc private func handleConnectNotification(
        _ note: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        armDisconnectNotification(for: device)
        let name = device.name ?? "Bluetooth Device"
        let kind = Self.kind(forName: name, classMajor: device.deviceClassMajor, classMinor: device.deviceClassMinor)
        announceConnect(name: name, kind: kind)
    }

    @objc private func handleDisconnectNotification(
        _ note: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        note.unregister() // one-shot: must be re-armed on the next connect.
        if let addr = device.addressString {
            disconnectNotifications[addr] = nil
        }
        let name = device.name ?? "Bluetooth Device"
        let kind = Self.kind(forName: name, classMajor: device.deviceClassMajor, classMinor: device.deviceClassMinor)
        announceDisconnect(name: name, kind: kind)
    }

    private func armDisconnectNotification(for device: IOBluetoothDevice) {
        guard let addr = device.addressString else { return }
        disconnectNotifications[addr] = device.register(
            forDisconnectNotification: self,
            selector: #selector(handleDisconnectNotification(_:device:)))
    }

    // MARK: - IOHIDManager (BLE-only HID: keyboards / mice / trackpads / gamepads)

    private func startHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<BluetoothMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.handleHIDDeviceArrival(device)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    private func handleHIDDeviceArrival(_ device: IOHIDDevice) {
        guard let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
              transport.lowercased().contains("bluetooth")
        else { return }

        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Bluetooth Accessory"

        let kind: DeviceKind
        if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) {
            kind = .keyboard
        } else if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse))
            || IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) {
            kind = .mouse
        } else if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_GamePad)) {
            kind = .gamepad
        } else {
            kind = Self.kind(forName: name, classMajor: nil, classMinor: nil)
        }

        announceConnect(name: name, kind: kind)
    }

    // MARK: - CoreAudio (default output switching to Bluetooth)

    private func startCoreAudioListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDefaultOutputChanged() }
        }
        defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func stopCoreAudioListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        defaultOutputListenerBlock = nil
    }

    private func handleDefaultOutputChanged() {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0
        else { return }

        var transportType: UInt32 = 0
        var ttSize = UInt32(MemoryLayout<UInt32>.size)
        var ttAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &ttAddress, 0, nil, &ttSize, &transportType) == noErr,
              transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
        else { return }

        guard let name = Self.audioDeviceName(deviceID) else { return }
        let kind = Self.kind(forName: name, classMajor: nil, classMinor: nil)
        announceConnect(name: name, kind: kind)
    }

    private static func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    // MARK: - Announce + dedupe

    private func announceConnect(name: String, kind: DeviceKind) {
        guard isRunning, Date() >= startupDeadline else { return }
        guard shouldAnnounce(name: name, connected: true) else { return }

        let event = DeviceEvent(name: name, kind: kind, isConnected: true)
        onEvent?(event)

        if Self.expectsBattery(kind) {
            fetchBatteryWithRetry(for: event)
        }
    }

    private func announceDisconnect(name: String, kind: DeviceKind) {
        guard isRunning, Date() >= startupDeadline else { return }
        guard shouldAnnounce(name: name, connected: false) else { return }

        onEvent?(DeviceEvent(name: name, kind: kind, isConnected: false))
    }

    private func shouldAnnounce(name: String, connected: Bool) -> Bool {
        let now = Date()
        let key = "\(name)|\(connected ? "connect" : "disconnect")"
        if let last = recentlyAnnounced[key], now.timeIntervalSince(last) < Self.dedupeWindow {
            return false
        }
        recentlyAnnounced[key] = now
        return true
    }

    // MARK: - Battery (retry: values land late)

    private func fetchBatteryWithRetry(for event: DeviceEvent) {
        Task { [weak self] in
            var attempts = 0
            while attempts < Self.batteryRetryCount {
                try? await Task.sleep(nanoseconds: Self.batteryRetryDelay)
                guard let self, self.isRunning else { return }
                if let info = Self.batteryInfo(matching: event.name), info.hasAnyValue {
                    var updated = event
                    updated.battery = info.single
                    updated.batteryLeft = info.left
                    updated.batteryRight = info.right
                    updated.batteryCase = info.caseLevel
                    self.onEvent?(updated)
                    return
                }
                attempts += 1
            }
        }
    }

    // MARK: - Device kind mapping

    private static func expectsBattery(_ kind: DeviceKind) -> Bool {
        switch kind {
        case .airpods, .airpodsPro, .airpodsMax, .beats, .earbuds:
            return true
        default:
            return false
        }
    }

    private static func kind(forName name: String, classMajor: UInt32?, classMinor: UInt32?) -> DeviceKind {
        let lowered = name.lowercased()

        if lowered.contains("airpods max") { return .airpodsMax }
        if lowered.contains("airpods pro") { return .airpodsPro }
        if lowered.contains("airpods") { return .airpods }
        if lowered.contains("beats") { return .beats }
        if lowered.contains("magic trackpad") || lowered.contains("trackpad") { return .trackpad }
        if lowered.contains("magic keyboard") || lowered.contains("keyboard") { return .keyboard }
        if lowered.contains("magic mouse") || lowered.contains("mouse") { return .mouse }
        if lowered.contains("gamepad") || lowered.contains("controller") || lowered.contains("joy-con") {
            return .gamepad
        }
        if lowered.contains("watch") { return .watch }
        if lowered.contains("iphone") { return .phone }
        if lowered.contains("homepod") || lowered.contains("speaker") { return .speaker }
        if lowered.contains("earbuds") || lowered.contains("buds") { return .earbuds }
        if lowered.contains("headphone") || lowered.contains("headset") || lowered.contains("earphone")
            || lowered.contains("earpods") {
            return .headphones
        }

        if let classMajor {
            switch classMajor {
            case UInt32(kBluetoothDeviceClassMajorAudio):
                return .headphones
            case UInt32(kBluetoothDeviceClassMajorPeripheral):
                if let classMinor {
                    switch classMinor & 0x30 {
                    case UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard),
                        UInt32(kBluetoothDeviceClassMinorPeripheral1Combo):
                        return .keyboard
                    case UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing):
                        return .mouse
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        return .other
    }

    // MARK: - Battery lookup

    private struct BatteryInfo {
        var left: Double?
        var right: Double?
        var caseLevel: Double?
        var single: Double?

        var hasAnyValue: Bool { left != nil || right != nil || caseLevel != nil || single != nil }
    }

    /// Best single figure first: accessory power sources (in-process, no
    /// Bluetooth TCC, gives per-part levels), then the
    /// `AppleDeviceManagementHIDEventService` IORegistry fallback used by
    /// Magic accessories (and, on some OS versions, other paired devices).
    private static func batteryInfo(matching name: String) -> BatteryInfo? {
        if let info = accessoryPowerSourceBattery(matching: name), info.hasAnyValue {
            return info
        }
        return hidServiceBattery(matching: name)
    }

    private typealias CopyPowerSourcesByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let kIOPSSourceForAccessories: Int32 = 4
    private static let copyPowerSourcesByType: CopyPowerSourcesByType? = {
        guard
            let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
            let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType")
        else { return nil }
        return unsafeBitCast(symbol, to: CopyPowerSourcesByType.self)
    }()

    private static func accessoryPowerSourceBattery(matching name: String) -> BatteryInfo? {
        guard let copyPowerSourcesByType else { return nil }
        guard let blob = copyPowerSourcesByType(kIOPSSourceForAccessories)?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        let wanted = normalized(name)
        var info = BatteryInfo()
        var matched = false

        for ps in list {
            guard let dict = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let psName = dict["Name"] as? String
            else { continue }
            let normalizedName = normalized(psName)
            guard normalizedName == wanted || normalizedName.contains(wanted) || wanted.contains(normalizedName)
            else { continue }
            matched = true

            if let parts = dict["Combined Parts"] as? [[String: Any]] {
                for part in parts { apply(part, to: &info) }
            } else {
                apply(dict, to: &info)
            }
        }
        return matched ? info : nil
    }

    private static func apply(_ part: [String: Any], to info: inout BatteryInfo) {
        guard let capacityRaw = part["Current Capacity"] as? Int else { return }
        let capacity = Double(capacityRaw) / 100.0
        switch (part["Part Identifier"] as? String)?.lowercased() {
        case "left": info.left = capacity
        case "right": info.right = capacity
        case "case": info.caseLevel = capacity
        default: info.single = capacity
        }
    }

    private static func hidServiceBattery(matching name: String) -> BatteryInfo? {
        guard let matchingDict = IOServiceMatching("AppleDeviceManagementHIDEventService") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let wanted = normalized(name)
        var info = BatteryInfo()
        var matched = false

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let product = props["Product"] as? String
            else { continue }

            let normalizedProduct = normalized(product)
            guard normalizedProduct == wanted || normalizedProduct.contains(wanted) || wanted.contains(normalizedProduct)
            else { continue }
            matched = true

            if let percent = props["BatteryPercent"] as? Int { info.single = Double(percent) / 100.0 }
            if let left = props["BatteryPercentLeft"] as? Int { info.left = Double(left) / 100.0 }
            if let right = props["BatteryPercentRight"] as? Int { info.right = Double(right) / 100.0 }
            if let caseLevel = props["BatteryPercentCase"] as? Int { info.caseLevel = Double(caseLevel) / 100.0 }
        }
        return matched ? info : nil
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
