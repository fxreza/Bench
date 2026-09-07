import AppKit
import SwiftUI

/// What the notch is drawing right now.
enum NotchState: Equatable {
    case idle
    /// A HUD / device / low-battery / track-peek activity on a timer.
    case transient(NotchActivity)
    /// Persistent compact now-playing (wings + artwork + wave).
    case nowPlaying
    case expanded

    var isTransient: Bool {
        if case .transient = self { return true }
        return false
    }

    var activity: NotchActivity? {
        if case .transient(let activity) = self { return activity }
        return nil
    }

    /// Identity used to cross-fade content. It changes when the *kind* of
    /// content changes, not on every value update, so a volume HUD tracking a
    /// key repeat re-lays out without re-fading on every step.
    var contentKey: String {
        switch self {
        case .idle: return "idle"
        case .nowPlaying: return "nowPlaying"
        case .expanded: return "expanded"
        case .transient(let activity):
            switch activity {
            case .hud(let payload): return "hud.\(payload.kind.rawValue)"
            case .device: return "device"
            case .lowBattery: return "lowBattery"
            case .trackPeek: return "trackPeek"
            }
        }
    }
}

/// State machine, timers and geometry for the notch. Owns every rule about
/// what is visible; the views are a pure function of it.
///
/// Priority (docs/ARCHITECTURE.md):
/// - A HUD replaces any visible transient immediately.
/// - Device / low-battery / track-peek activities never interrupt a visible
///   HUD: the newest one is parked in a single-slot queue and shown when the
///   HUD's timer ends, or dropped if it went stale (`queuedActivityLifetime`).
/// - While the expanded player is open every transient activity is dropped,
///   HUDs included (Alcove behaves the same way).
/// - When the transient timer fires the notch falls back to expanded if the
///   player is open, else compact now-playing if something is playing, else idle.
@MainActor
final class NotchViewModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var state: NotchState = .idle
    /// Persistent now-playing info. Assigning it can move the notch in and out
    /// of the compact state.
    @Published var nowPlaying: NowPlayingInfo? {
        didSet { nowPlayingDidChange() }
    }
    @Published private(set) var isHovering = false
    @Published private(set) var isExpanded = false
    /// Set by `VisibilityMonitor` through the window controller: fullscreen or
    /// Mission Control is up and the panel is hidden.
    @Published var isHiddenBySystem = false
    /// Notch/screen geometry; re-assigned on screen parameter changes.
    @Published var geometry: NotchGeometry

    /// Set by AppDelegate so the expanded player can send transport commands.
    weak var mediaController: MediaController?

    /// Animation the container applies to the shape's size and radii for the
    /// change in flight. Content identity changes with the state (the wings
    /// cross-fade), which would otherwise let the frame jump; an explicit
    /// `.animation(_:value:)` keyed on the size keeps the spring.
    @Published private(set) var shapeAnimation: Animation = NotchViewModel.expandAnimation

    private func animate(_ animation: Animation, _ changes: () -> Void) {
        shapeAnimation = animation
        withAnimation(animation, changes)
    }

    // MARK: Animations (docs/research/alcove-measurements.md, "Animation timing")

    static let expandAnimation = Animation.spring(response: 0.38, dampingFraction: 0.85)
    /// Opening the player overshoots a little and settles (Alcove: 423 -> 409).
    static let openPanelAnimation = Animation.spring(response: 0.42, dampingFraction: 0.58)
    static let collapseAnimation = Animation.spring(response: 0.30, dampingFraction: 1.0)
    static let hoverAnimation = Animation.spring(response: 0.25, dampingFraction: 0.8)
    /// Same-size updates (HUD value changes) just track the new value.
    static let trackingAnimation = Animation.easeOut(duration: 0.12)

    /// Grace period before the expanded panel closes after the pointer leaves.
    static let expandedCloseDelay: TimeInterval = 0.5
    /// Short debounce on hover exit so grazing the edge does not flicker.
    static let hoverExitDelay: TimeInterval = 0.12
    /// A queued activity older than this is dropped instead of shown late.
    static let queuedActivityLifetime: TimeInterval = 4

    // MARK: Private

    private var transientWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var expandedCloseWork: DispatchWorkItem?
    private var queued: (activity: NotchActivity, date: Date)?

    init(geometry: NotchGeometry = NotchScreen.currentGeometry()) {
        self.geometry = geometry
    }

    // MARK: - API

    /// Show a transient activity: volume/display HUDs stay for
    /// `Settings.shared.hudDuration`, every other alert for
    /// `Settings.shared.alertDuration`. The timer restarts on every call that
    /// actually presents something.
    func show(_ activity: NotchActivity) {
        guard !isExpanded else {
            Log.notch.debug("activity dropped: expanded player is open")
            return
        }
        if case .hud = activity {
            present(activity)
            return
        }
        // Non-HUD activities wait behind a visible HUD.
        if case .hud = state.activity {
            queued = (activity, Date())
            return
        }
        present(activity)
    }

    /// Convenience for the now-playing service's "track changed" peek.
    func showTrackPeek(_ info: NowPlayingInfo) {
        show(.trackPeek(info))
    }

    func expand() {
        guard !isExpanded else { return }
        cancelTransient()
        queued = nil
        cancelExpandedClose()
        isExpanded = true
        animate(Self.openPanelAnimation) { state = .expanded }
    }

    func collapse() {
        guard isExpanded else { return }
        cancelExpandedClose()
        isExpanded = false
        animate(Self.collapseAnimation) { state = restingState() }
    }

    func toggleExpanded() {
        isExpanded ? collapse() : expand()
    }

    /// Pointer entered / left the notch shape.
    func hoverChanged(_ hovering: Bool) {
        hoverWork?.cancel()
        guard hovering != isHovering else {
            if hovering { cancelExpandedClose() }
            return
        }
        let apply = { [weak self] in
            guard let self else { return }
            self.animate(Self.hoverAnimation) { self.isHovering = hovering }
            if hovering {
                self.cancelExpandedClose()
            } else if self.isExpanded {
                self.scheduleExpandedClose()
            }
        }
        if hovering {
            apply()
        } else {
            let work = DispatchWorkItem(block: apply)
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExitDelay, execute: work)
        }
    }

    /// Trackpad swipe on the notch: down opens the player, up closes it.
    func handleSwipe(down: Bool) {
        if down { expand() } else { collapse() }
    }

    /// Click on the notch shape.
    func handleClick() {
        // Clicks inside the open panel belong to its own controls (Alcove does
        // not close on a click in the panel body either), so only opening is
        // driven from here.
        guard !isExpanded else { return }
        expand()
    }

    // MARK: - Derived geometry

    /// Extra width per side over the physical notch, for the current state.
    var wingWidth: CGFloat {
        switch state {
        case .idle:
            return hoverGrows ? NotchMetrics.hoverExtraWidthPerSide : 0
        case .transient:
            return NotchMetrics.hudWingWidth
        case .nowPlaying:
            return NotchMetrics.nowPlayingWingWidth + (hoverGrows ? NotchMetrics.hoverExtraWidthPerSide : 0)
        case .expanded:
            return max(0, (NotchMetrics.expandedWidth - geometry.notchWidth) / 2)
        }
    }

    /// Body size of the shape (without the top flares).
    var currentSize: CGSize {
        switch state {
        case .expanded:
            return CGSize(width: NotchMetrics.expandedWidth, height: NotchMetrics.expandedHeight)
        default:
            let height = geometry.notchHeight + (hoverGrows ? NotchMetrics.hoverExtraHeight : 0)
            return CGSize(width: geometry.notchWidth + wingWidth * 2, height: height)
        }
    }

    var radii: (top: CGFloat, bottom: CGFloat) {
        switch state {
        case .idle:
            return hoverGrows
                ? (NotchMetrics.hoverTopRadius, NotchMetrics.hoverBottomRadius)
                : (NotchMetrics.idleTopRadius, NotchMetrics.idleBottomRadius)
        case .transient, .nowPlaying:
            return (NotchMetrics.compactTopRadius, NotchMetrics.compactBottomRadius)
        case .expanded:
            return (NotchMetrics.expandedTopRadius, NotchMetrics.expandedBottomRadius)
        }
    }

    /// Bounding box of the drawn shape inside the panel, top-left origin.
    /// Used for hit testing and hover, so the transparent rest of the 624x320
    /// panel stays click-through.
    func shapeFrame(in windowSize: CGSize = NotchMetrics.windowSize) -> CGRect {
        let size = currentSize
        let width = NotchShape.flaredWidth(body: size.width, topRadius: radii.top)
        return CGRect(x: (windowSize.width - width) / 2, y: 0, width: width, height: size.height)
    }

    /// Hover only grows the resting states; HUD and expanded sizes are fixed.
    private var hoverGrows: Bool {
        guard isHovering else { return false }
        switch state {
        case .idle, .nowPlaying: return true
        case .transient, .expanded: return false
        }
    }

    // MARK: - Internals

    private func present(_ activity: NotchActivity) {
        // All transient states share the HUD wing width, so replacing one with
        // another (a key repeat stepping the volume) does not change the shape
        // and must not re-spring it.
        let sameShape = state.isTransient
        animate(sameShape ? Self.trackingAnimation : Self.expandAnimation) {
            state = .transient(activity)
        }
        scheduleTransientEnd(for: activity)
    }

    private func scheduleTransientEnd(for activity: NotchActivity) {
        cancelTransient()
        let configured: Double
        if case .hud = activity {
            configured = Settings.shared.hudDuration
        } else {
            configured = Settings.shared.alertDuration
        }
        let duration = max(0.2, configured)
        let work = DispatchWorkItem { [weak self] in self?.transientDidEnd() }
        transientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func cancelTransient() {
        transientWork?.cancel()
        transientWork = nil
    }

    private func transientDidEnd() {
        transientWork = nil
        if let pending = queued {
            queued = nil
            if Date().timeIntervalSince(pending.date) <= Self.queuedActivityLifetime, !isExpanded {
                present(pending.activity)
                return
            }
        }
        animate(Self.collapseAnimation) { state = restingState() }
    }

    /// Where the notch settles once nothing transient is up.
    private func restingState() -> NotchState {
        if isExpanded { return .expanded }
        if nowPlaying?.isPlaying == true { return .nowPlaying }
        return .idle
    }

    private func nowPlayingDidChange() {
        guard !isExpanded, !state.isTransient else { return }
        let target = restingState()
        guard target != state else { return }
        animate(target == .idle ? Self.collapseAnimation : Self.expandAnimation) {
            state = target
        }
    }

    private func scheduleExpandedClose() {
        cancelExpandedClose()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isExpanded, !self.isHovering else { return }
            self.collapse()
        }
        expandedCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandedCloseDelay, execute: work)
    }

    private func cancelExpandedClose() {
        expandedCloseWork?.cancel()
        expandedCloseWork = nil
    }
}

/// Screen selection for the notch panel: the built-in display with a physical
/// notch when there is one, else the main screen with the pseudo-notch from
/// `NotchGeometry`.
enum NotchScreen {
    static func currentGeometry() -> NotchGeometry {
        if let screen = NotchGeometry.preferredScreen() {
            return NotchGeometry.forScreen(screen)
        }
        // No screens at all (headless / during logout): a harmless placeholder.
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: frame.midX - 95, y: frame.maxY - 32, width: 190, height: 32)
        return NotchGeometry(screenFrame: frame, notchRect: notch, hasPhysicalNotch: false)
    }
}
