// Adapted from Snapper's Services/PermissionsState.swift and Transi's
// PermissionsState.swift (MIT, Copyright 2026 Sam Reza), which trace back to
// Clipfield (MIT, Copyright 2026 Alex Jolley).

import AppKit
import ApplicationServices

/// Tracks the macOS permissions Bench's modules depend on, polling while a
/// Settings or onboarding window is up so a grant made in System Settings
/// shows without a relaunch.
///
/// - Accessibility: Klip's auto-paste, Lingo's selected-text capture, Snap's
///   window moves, and every global key/mouse monitor.
/// - Screen Recording: Shot's captures and Lingo's screenshot translate.
@MainActor
public final class PermissionsState: ObservableObject {
    public static let shared = PermissionsState()

    @Published public private(set) var accessibilityTrusted: Bool
    @Published public private(set) var screenRecordingGranted: Bool

    /// Called once when Accessibility transitions to trusted. Features that
    /// need to re-arm an event tap append to this list.
    public var onAccessibilityBecameTrusted: [() -> Void] = []
    /// Called once when Screen Recording transitions to granted.
    public var onScreenRecordingBecameGranted: [() -> Void] = []

    private var timer: Timer?
    private var pollers = 0

    /// `testAccessibilityTrusted`/`testScreenRecordingGranted` let a test
    /// construct a state without touching the real system calls.
    public init(testAccessibilityTrusted: Bool? = nil, testScreenRecordingGranted: Bool? = nil) {
        accessibilityTrusted = testAccessibilityTrusted ?? AXIsProcessTrusted()
        screenRecordingGranted = testScreenRecordingGranted ?? CGPreflightScreenCaptureAccess()
    }

    public func granted(_ permission: BenchPermission) -> Bool {
        switch permission {
        case .accessibility: return accessibilityTrusted
        case .screenRecording: return screenRecordingGranted
        case .automation: return true // per-target, no reliable preflight
        }
    }

    /// Starts a 1 s poll. Reference counted: every `startPolling` needs a
    /// matching `stopPolling`, driven by the window that shows the state,
    /// not by view `onAppear`, which also fires for offscreen renders.
    public func startPolling() {
        refresh()
        pollers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func stopPolling() {
        pollers = max(0, pollers - 1)
        guard pollers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        if ax != accessibilityTrusted {
            accessibilityTrusted = ax
            if ax { onAccessibilityBecameTrusted.forEach { $0() } }
        }
        if screen != screenRecordingGranted {
            screenRecordingGranted = screen
            if screen { onScreenRecordingBecameGranted.forEach { $0() } }
        }
    }

    /// Shows the system Accessibility prompt (once per app, macOS decides).
    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Shows the system Screen Recording prompt and lists the app in System
    /// Settings.
    public func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}

/// Deep links into the Privacy & Security panes, so a permission message can
/// put the user in the right place instead of describing where to click.
public enum SystemSettingsPane: String, Sendable {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"
    case automation = "Privacy_Automation"

    public var buttonTitle: String {
        switch self {
        case .accessibility: return "Open Accessibility Settings"
        case .screenRecording: return "Open Screen Recording Settings"
        case .automation: return "Open Automation Settings"
        }
    }

    public func open() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
