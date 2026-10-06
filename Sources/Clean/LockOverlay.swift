import AppKit
import QuartzCore

/// What is on screen during a lock: a black cover over every screen, as
/// dark as the setting says, and the unlock square in the middle of the
/// screen the pointer was on.
///
/// The square copies KeyboardCleanTool's: 140 pt, dark grey, rounded, a grey
/// ring with a lock and "Hold to unlock", and a blue arc that runs clockwise
/// from the top while a button is held.
@MainActor
final class LockOverlay {
    private var covers: [NSWindow] = []
    private var indicatorWindow: NSWindow?
    private var indicator: UnlockIndicatorView?
    private var alwaysShowIndicator = true

    /// Above everything, the menu bar and notifications included.
    private static let coverLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    func show(darkness: Double, showIndicator: Bool) {
        hide()
        alwaysShowIndicator = showIndicator

        for screen in NSScreen.screens {
            let window = makeWindow(frame: screen.frame, level: Self.coverLevel)
            window.backgroundColor = NSColor.black.withAlphaComponent(darkness)
            window.orderFrontRegardless()
            covers.append(window)
        }

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = UnlockIndicatorView.size
        let frame = NSRect(
            x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2,
            width: size, height: size)
        let window = makeWindow(frame: frame, level: NSWindow.Level(rawValue: Self.coverLevel.rawValue + 1))
        window.backgroundColor = .clear
        let view = UnlockIndicatorView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        indicatorWindow = window
        indicator = view
        if showIndicator {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        covers.forEach { $0.orderOut(nil) }
        covers.removeAll()
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
        indicator = nil
    }

    func beginHold(duration: TimeInterval) {
        guard let indicatorWindow, let indicator else { return }
        if !alwaysShowIndicator {
            indicatorWindow.alphaValue = 0
            indicatorWindow.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                indicatorWindow.animator().alphaValue = 1
            }
        }
        indicator.beginHold(duration: duration)
    }

    func cancelHold() {
        guard let indicatorWindow, let indicator else { return }
        indicator.cancelHold()
        if !alwaysShowIndicator {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                indicatorWindow.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // A new hold may have started during the fade.
                    guard let self, self.indicatorWindow === indicatorWindow,
                          indicatorWindow.alphaValue == 0 else { return }
                    indicatorWindow.orderOut(nil)
                }
            }
        }
    }

    private func makeWindow(frame: NSRect, level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = level
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return window
    }
}

/// The 140 pt unlock square.
final class UnlockIndicatorView: NSView {
    static let size: CGFloat = 140
    private static let ringRadius: CGFloat = 54
    private static let ringWidth: CGFloat = 4.5

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Hold to unlock")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }

        // The square is its own sublayer: AppKit owns the content view's
        // backing layer and resets its background once the view is a
        // window's content view.
        let square = CALayer()
        square.frame = bounds
        square.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        square.cornerRadius = 16
        square.cornerCurve = .continuous
        layer.addSublayer(square)

        // From 12 o'clock, clockwise (the layer is not flipped, so y is up).
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(
            center: center, radius: Self.ringRadius,
            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)

        for ring in [track, progress] {
            ring.path = path
            ring.fillColor = nil
            ring.lineWidth = Self.ringWidth
            ring.frame = bounds
            layer.addSublayer(ring)
        }
        track.strokeColor = NSColor(white: 0.25, alpha: 1).cgColor
        progress.strokeColor = NSColor.systemBlue.cgColor
        progress.lineCap = .round
        progress.strokeEnd = 0

        icon.contentTintColor = .white
        icon.imageScaling = .scaleNone
        setIcon(open: false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -7),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 13),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func beginHold(duration: TimeInterval) {
        setIcon(open: true)
        progress.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        progress.strokeEnd = 1
        progress.add(animation, forKey: "hold")
    }

    func cancelHold() {
        setIcon(open: false)
        let current = progress.presentation()?.strokeEnd ?? progress.strokeEnd
        progress.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = current
        animation.toValue = 0
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        progress.strokeEnd = 0
        progress.add(animation, forKey: "release")
    }

    private func setIcon(open: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let name = open ? "lock.open.fill" : "lock.fill"
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
