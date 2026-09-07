import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel pinned over the notch.
///
/// The panel is always `NotchMetrics.windowSize` (624 x 320, as measured on
/// Alcove): its top edge is the top of the screen and it is centred on the
/// notch, and every visual growth happens inside SwiftUI. Animating
/// `setFrame:` instead would jitter.
final class NotchWindow: NSPanel {

    /// Just above the menu bar. Alcove sits at `kCGMaximumWindowLevel - 2`
    /// (2147483629) and that is what we match: anything lower (`.statusBar`,
    /// `.mainMenu + 3`) is covered by the Tahoe menu bar in some
    /// configurations, and the notch must never be half-drawn. The trade-off
    /// is that the panel also draws over Control Center popovers and
    /// notification banners that reach the top-centre strip; the panel is only
    /// 624 pt wide and centred, so in practice it does not overlap them.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 2)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // macOS 26 misbehaves when a style mask is mutated after creation;
            // set the final mask here and never touch it again.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The window is a big transparent rectangle: an AppKit shadow would
        // trace that rectangle, so the shadow is drawn in SwiftUI instead.
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // The panel is a 624 x 320 transparent rectangle over the menu bar; the
        // window server routes every click inside it to us (a nil hitTest only
        // drops the event, it does not forward it to the status items below).
        // So the panel ignores mouse events by default and the controller's
        // pointer timer switches them on only while the pointer is over the
        // drawn shape (see NotchWindowController.startPointerTracking).
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// Hosting view that makes the transparent part of the panel click-through.
final class NotchHostingView: NSHostingView<NotchContainerView> {
    /// Bounding box of the drawn shape, top-left origin inside the panel.
    var interactiveFrame: (() -> CGRect)?

    required init(rootView: NotchContainerView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A nil hit test lets the click fall through to whatever is below, with
    /// no lag and no global event monitor.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let region = interactiveFrame?() else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // `region` is expressed top-left origin; AppKit views are not flipped
        // unless SwiftUI says so.
        let fromTop = isFlipped ? local.y : bounds.maxY - local.y
        guard region.contains(CGPoint(x: local.x, y: fromTop)) else { return nil }
        return super.hitTest(point)
    }
}

/// Creates and places the panel, and owns the view model the rest of the app
/// talks to.
@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel

    private(set) var window: NotchWindow?
    private var hostingView: NotchHostingView?
    private var screenObserver: NSObjectProtocol?
    private let notchSpace = NotchSpace()
    private var pointerTimer: Timer?
    private var stateObserver: AnyCancellable?
    private var lastPointerInsideShape = false

    /// How often the pointer position is sampled to decide whether the panel
    /// should accept clicks (see `startPointerTracking`). 60 Hz reads as
    /// instant to a user reaching for the notch, and the check is a couple of
    /// rect comparisons, so the idle cost is negligible.
    private static let pointerPollInterval: TimeInterval = 1.0 / 60.0
    /// Hidden by `VisibilityMonitor` (fullscreen / Mission Control).
    private var isHiddenBySystem = false

    init(viewModel: NotchViewModel? = nil) {
        self.viewModel = viewModel ?? NotchViewModel(geometry: NotchScreen.currentGeometry())
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// Builds the panel (once) and puts it on screen.
    func show() {
        if window == nil { build() }
        place()
        guard !isHiddenBySystem else { return }
        window?.alphaValue = 1
        window?.orderFrontRegardless()
        adoptIntoPrivateSpace()
    }

    /// The private space is what keeps the panel still during trackpad space
    /// swipes; AppKit re-adds the window to the current desktop on some
    /// ordering passes, so this runs after every orderFront.
    private func adoptIntoPrivateSpace() {
        guard let window, let notchSpace else { return }
        notchSpace.adopt(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            notchSpace.adopt(window)
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Removes everything the controller installed: pointer monitors, the
    /// screen-parameters observer, the private WindowServer space and the
    /// panel itself. Called from `PikoFeature.stop()`; after it the module
    /// leaves no window and no global event monitor behind.
    func teardown() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        stateObserver?.cancel()
        stateObserver = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        notchSpace?.tearDown()
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        hostingView = nil
        lastPointerInsideShape = false
    }

    /// Called by `VisibilityMonitor`. No animation: the notch must be gone
    /// before the fullscreen transition draws.
    func setVisible(_ visible: Bool) {
        isHiddenBySystem = !visible
        viewModel.isHiddenBySystem = !visible
        guard let window else { return }
        if visible {
            window.alphaValue = 1
            window.orderFrontRegardless()
            adoptIntoPrivateSpace()
        } else {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    // MARK: - Private

    private func build() {
        let geometry = NotchScreen.currentGeometry()
        viewModel.geometry = geometry

        let panel = NotchWindow(contentRect: Self.frame(for: geometry))
        let hosting = NotchHostingView(rootView: NotchContainerView(viewModel: viewModel))
        hosting.interactiveFrame = { [weak self] in
            self?.viewModel.shapeFrame() ?? .zero
        }
        panel.contentView = hosting

        window = panel
        hostingView = hosting

        startPointerTracking()
        // The shape can grow under a resting pointer (HUD, peek, expand).
        stateObserver = viewModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMousePassThrough() }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    /// Samples the pointer on a timer to drive the click pass-through.
    ///
    /// The panel is a 624 x 320 transparent rectangle over the menu bar, and a
    /// window with `ignoresMouseEvents = false` swallows clicks in its
    /// transparent areas rather than forwarding them to the status items
    /// underneath, so the panel has to ignore mouse events everywhere except
    /// over the drawn shape and flip that the instant the pointer arrives.
    ///
    /// An earlier version watched `NSEvent.addGlobalMonitorForEvents(.mouseMoved)`
    /// for this. That installs a system-wide mouse-moved event tap on the main
    /// run loop, and while any menu (including Bench's own status menu) is
    /// tracking, that tap throttled mouse-move delivery to the menu - the
    /// highlight visibly lagged and skipped items. A timer samples
    /// `NSEvent.mouseLocation` with no event tap at all, so menu tracking runs
    /// at full speed. `.common` keeps the timer live during menu/drag tracking.
    private func startPointerTracking() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pointerPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
        }
        timer.tolerance = Self.pointerPollInterval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    /// Accept mouse events only while the pointer is inside the drawn shape
    /// (with a small margin so the edge of the shape is not dead), otherwise
    /// let clicks fall through to the menu bar and windows below.
    func updateMousePassThrough() {
        guard let window, !isHiddenBySystem else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - window.frame.minX, y: window.frame.maxY - mouse.y)
        let frame = viewModel.shapeFrame()
        let inside = frame.insetBy(dx: -4, dy: -4).contains(local)
        if window.ignoresMouseEvents == inside {
            window.ignoresMouseEvents = !inside
        }
        // Drive hover from here as well: while the panel ignored mouse events
        // its tracking area saw nothing, so the first pointer event over the
        // shape would otherwise only flip the pass-through and not the hover.
        let radii = viewModel.radii
        let exact = frame.contains(local)
            && NotchShape.path(in: frame, topRadius: radii.top, bottomRadius: radii.bottom).contains(local)
        if exact != lastPointerInsideShape {
            lastPointerInsideShape = exact
            viewModel.hoverChanged(exact)
        }
    }

    /// Re-derives the notch geometry and re-places the panel. Safe to call at
    /// any time (screen parameter changes, display sleep, scaling changes).
    func place() {
        guard let window else { return }
        let geometry = NotchScreen.currentGeometry()
        viewModel.geometry = geometry
        window.setFrame(Self.frame(for: geometry), display: true)
        if !isHiddenBySystem {
            window.orderFrontRegardless()
            adoptIntoPrivateSpace()
        }
    }

    /// 624 x 320, top edge at the top of the screen, centred on the notch.
    private static func frame(for geometry: NotchGeometry) -> NSRect {
        let size = NotchMetrics.windowSize
        return NSRect(
            x: geometry.centerX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
