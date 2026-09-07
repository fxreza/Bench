import AppKit
import CoreGraphics

/// Lets the user drag a rectangle on screen, then captures that area as an image.
/// Uses the Screen Recording permission (TCC), prompted for like the existing
/// Accessibility flow in AppDelegate.
@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    private var overlayWindows: [SelectionOverlayWindow] = []
    private var keyMonitor: Any?
    private var completion: ((NSImage?, NSPoint) -> Void)?

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system permission prompt if not yet determined.
    func requestPermissionIfNeeded() {
        if !hasPermission {
            NSLog("Screen Recording permission not yet granted; system prompt shown.")
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Shows a full-screen drag-to-select overlay; calls `completion` with the
    /// captured image and a screen point to anchor the popup near, or `nil` if
    /// the user cancelled (Esc) or made a degenerate selection.
    func beginSelection(completion: @escaping (NSImage?, NSPoint) -> Void) {
        guard overlayWindows.isEmpty else { return }
        self.completion = completion

        NSCursor.crosshair.push()
        overlayWindows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(
                screen: screen,
                onComplete: { [weak self] globalRect in
                    self?.finishSelection(rect: globalRect)
                },
                onCancel: { [weak self] in
                    self?.finishSelection(rect: nil)
                })
            window.orderFrontRegardless()
            return window
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Esc
                self?.finishSelection(rect: nil)
                return nil
            }
            return event
        }
    }

    private func finishSelection(rect: NSRect?) {
        guard !overlayWindows.isEmpty else { return }
        NSCursor.pop()
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        let done = completion
        completion = nil

        guard let rect, rect.width > 4, rect.height > 4 else {
            done?(nil, NSEvent.mouseLocation)
            return
        }

        // Give the overlay windows a moment to finish ordering out before capturing,
        // so they don't appear in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let image = Self.captureImage(globalRect: rect)
            let anchor = NSPoint(x: rect.midX, y: rect.minY)
            done?(image, anchor)
        }
    }

    /// `rect` is in AppKit global screen coordinates (origin bottom-left of the
    /// primary screen, y-up).
    private static func captureImage(globalRect: NSRect) -> NSImage? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let cgRect = CGRect(
            x: globalRect.minX,
            y: primaryHeight - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height)

        guard let cgImage = CGWindowListCreateImage(
            cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        else { return nil }

        return NSImage(cgImage: cgImage, size: globalRect.size)
    }
}

/// Borderless, click-through-capable window covering one screen while the user
/// drags out a selection rectangle.
final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, onComplete: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let origin = screen.frame.origin
        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { localRect in
            onComplete(localRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        view.onCancel = onCancel
        contentView = view
    }
}

/// Draws a dimmed overlay with a punched-out selection rectangle while the user drags.
final class SelectionOverlayView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentRect = NSRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = currentRect
        startPoint = nil
        currentRect = .zero
        needsDisplay = true
        onComplete?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setBlendMode(.clear)
        context.fill(currentRect)
        context.setBlendMode(.normal)

        NSColor.white.setStroke()
        let path = NSBezierPath(rect: currentRect)
        path.lineWidth = 1.5
        path.stroke()
    }
}
