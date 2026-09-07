import Foundation
import IOKit.ps

/// Watches the internal (Mac) battery via the IOPS APIs and reports level /
/// charge state, firing a dedicated low-battery callback with re-arm rules
/// (see docs/research/glint-analysis.md section 5 and
/// docs/research/tech-reference.md section 6 for the underlying API shapes).
///
/// On a desktop Mac with no internal battery `readBatteryStatus()` always
/// returns nil, so `current` stays nil and neither callback ever fires.
@MainActor
final class BatteryMonitor {
    var onStatus: ((BatteryStatus) -> Void)?
    var onLowBattery: ((BatteryStatus) -> Void)?
    private(set) var current: BatteryStatus?

    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var isRunning = false

    /// Percent thresholds (0-100) that have already fired `onLowBattery` for
    /// the current discharge cycle. Cleared on plug-in, so the next
    /// discharge fires again.
    private var firedThresholds: Set<Int> = []

    private static let fallbackPollInterval: TimeInterval = 60
    /// A level must climb back above threshold + this margin (or start
    /// charging) before that threshold can fire again.
    private static let rearmMargin: Double = 0.05
    /// Extra checkpoints below the user threshold, per product spec #15.
    private static let extraThresholds: [Double] = [0.10, 0.05]

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // Belt-and-suspenders: IOPS notifications are reliable but a slow
        // poll costs nothing and covers any missed callback.
        let timer = Timer(timeInterval: Self.fallbackPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil

        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        guard let status = Self.readBatteryStatus() else {
            current = nil
            return
        }
        current = status
        onStatus?(status)
        evaluateLowBattery(status)
    }

    private func evaluateLowBattery(_ status: BatteryStatus) {
        if status.isCharging || status.isPluggedIn {
            // Re-arm every threshold for the next discharge.
            firedThresholds.removeAll()
            return
        }

        let userThreshold = Settings.shared.lowBatteryThreshold
        var checkpoints = Self.extraThresholds.filter { $0 < userThreshold }
        checkpoints.append(userThreshold)
        checkpoints.sort(by: >) // highest first, so the least-alarming fires first if several are crossed at once

        for threshold in checkpoints {
            let key = Int((threshold * 100).rounded())
            if status.level <= threshold {
                if !firedThresholds.contains(key) {
                    firedThresholds.insert(key)
                    onLowBattery?(status)
                }
            } else if status.level > threshold + Self.rearmMargin {
                firedThresholds.remove(key)
            }
        }
    }

    private static func readBatteryStatus() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for powerSource in list {
            guard let description = IOPSGetPowerSourceDescription(blob, powerSource)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0
            else { continue }

            let level = Double(currentCapacity) / Double(maxCapacity)
            let isPluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false

            return BatteryStatus(
                level: min(max(level, 0), 1),
                isCharging: isCharging,
                isPluggedIn: isPluggedIn)
        }
        return nil // no internal battery, e.g. a desktop Mac.
    }
}
