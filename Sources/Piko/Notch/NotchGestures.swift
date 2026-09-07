import AppKit
import SwiftUI

/// Mouse handling for the notch, in AppKit because SwiftUI's `.onHover` and
/// tap gestures are unreliable in a non-activating panel that never becomes key.
///
/// It is installed as a `.background` of the drawn shape, so its bounds are
/// exactly the shape's bounding box (never the whole 624x320 panel):
/// - hover comes from an `NSTrackingArea` with `.activeAlways`, refined by
///   testing the point against the live `NotchShape` path;
/// - clicks and scroll come from *local* event monitors, because a background
///   view is a sibling of the SwiftUI content and therefore never gets those
///   events through the responder chain. Local monitors only see events already
///   routed to this app, so no Accessibility permission is involved.
struct NotchInteractionView: NSViewRepresentable {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// All input is ignored while the panel is hidden by the system.
    var isEnabled: Bool
    /// Clicks are only a "toggle open" gesture while the player is closed; a
    /// click inside the open panel belongs to the player's own controls.
    var acceptsClick: Bool
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    /// `true` = swipe down (open), `false` = swipe up (close).
    var onSwipe: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        context.coordinator.attach(to: view)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func apply(to view: TrackingView) {
        view.topRadius = topRadius
        view.bottomRadius = bottomRadius
        view.isEnabled = isEnabled
        view.acceptsClick = acceptsClick
        view.onHover = onHover
        view.onClick = onClick
        view.onSwipe = onSwipe
    }

    // MARK: - The view

    final class TrackingView: NSView {
        var topRadius: CGFloat = 0
        var bottomRadius: CGFloat = 0
        var isEnabled = true
        var acceptsClick = true
        var onHover: ((Bool) -> Void)?
        var onClick: (() -> Void)?
        var onSwipe: ((Bool) -> Void)?

        /// Scroll accumulation for the swipe gesture.
        private var scrollAccumulator: CGFloat = 0
        private var swipeFiredInGesture = false
        /// True between `.began` and `.ended` of a gesture that started on the notch.
        private var gestureStartedOnNotch = false
        private var isInside = false
        private var trackingArea: NSTrackingArea?

        /// Points of accumulated trackpad travel before a swipe fires.
        static let swipeThreshold: CGFloat = 30

        /// Match SwiftUI's coordinate space so the shape path lines up.
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
        override func mouseMoved(with event: NSEvent) { updateHover(with: event) }

        override func mouseExited(with event: NSEvent) {
            guard isInside else { return }
            isInside = false
            onHover?(false)
        }

        private func updateHover(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let inside = shapeContains(point)
            guard inside != isInside else { return }
            isInside = inside
            onHover?(inside)
        }

        /// Exact hit test against the drawn outline, not its bounding box.
        func shapeContains(_ point: CGPoint) -> Bool {
            guard bounds.contains(point) else { return false }
            return NotchShape
                .path(in: bounds, topRadius: topRadius, bottomRadius: bottomRadius)
                .contains(point)
        }

        // MARK: Events fed in by the local monitors

        func handleMouseDown(_ event: NSEvent) -> Bool {
            guard isEnabled, acceptsClick else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard shapeContains(point) else { return false }
            onClick?()
            return true
        }

        func handleScroll(_ event: NSEvent) {
            guard isEnabled else { return }
            switch event.phase {
            case .began:
                let point = convert(event.locationInWindow, from: nil)
                gestureStartedOnNotch = shapeContains(point)
                scrollAccumulator = 0
                swipeFiredInGesture = false
            case .changed:
                break
            case .ended, .cancelled:
                gestureStartedOnNotch = false
                scrollAccumulator = 0
                swipeFiredInGesture = false
                return
            default:
                // Plain wheel ticks (and momentum) carry no phase: ignore them,
                // a mouse wheel must not open the panel.
                return
            }
            guard gestureStartedOnNotch else { return }

            let delta = event.scrollingDeltaY
            // Off-axis noise: the vertical component has to dominate.
            guard abs(delta) >= abs(event.scrollingDeltaX) else { return }
            // A direction change restarts the count.
            if scrollAccumulator != 0, delta.sign != scrollAccumulator.sign { scrollAccumulator = 0 }
            scrollAccumulator += delta

            guard !swipeFiredInGesture, abs(scrollAccumulator) >= Self.swipeThreshold else { return }
            swipeFiredInGesture = true
            // Natural scrolling: fingers moving down give a positive delta.
            onSwipe?(scrollAccumulator > 0)
        }
    }

    // MARK: - Local event monitors

    final class Coordinator {
        private weak var view: TrackingView?
        private var scrollMonitor: Any?
        private var clickMonitor: Any?

        func attach(to view: TrackingView) {
            self.view = view
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let view = self?.view, event.window === view.window else { return event }
                view.handleScroll(event)
                return event
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let view = self?.view, event.window === view.window else { return event }
                // Never swallow: the window's hitTest already keeps clicks on
                // the shape away from the app below, and the expanded panel's
                // SwiftUI buttons need the event to continue to them.
                _ = view.handleMouseDown(event)
                return event
            }
        }

        func detach() {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            scrollMonitor = nil
            clickMonitor = nil
            view = nil
        }

        deinit { detach() }
    }
}
