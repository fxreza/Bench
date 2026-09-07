import AppKit
import SwiftUI

/// A small equalizer-style bar row that animates while `isPlaying` is true
/// and settles to small static heights when paused. Used both at compact
/// size (now-playing trailing wing) and as the tiny glyph in the expanded
/// player header.
///
/// The bars are `CALayer`s driven by repeating `CABasicAnimation`s rather
/// than a SwiftUI `TimelineView` recomputing heights every frame. Any
/// per-frame change inside the notch's hosting view costs a full ViewGraph
/// render and `NSHostingView.layout()` over everything mounted in it - about
/// 20% CPU for as long as anything played. Layer animations are handed to the
/// render server once and then cost the app nothing per frame.
struct AudioWaveView: View {
    let isPlaying: Bool
    /// False while this view's content layer is faded out. The layers stay in
    /// the hierarchy (see `NotchContainerView.content`), so without this the
    /// hidden copies would keep animating.
    var isActive: Bool = true
    var barCount: Int = 5
    var barWidth: CGFloat = 2.5
    var pitch: CGFloat = 3.5
    var minHeight: CGFloat = 3
    var maxHeight: CGFloat = 9
    var color: Color = Color(white: 0.45)

    /// Width the old `HStack(spacing: pitch - barWidth)` resolved to.
    private var contentWidth: CGFloat {
        barWidth + CGFloat(barCount - 1) * pitch
    }

    var body: some View {
        WaveBarsLayerView(
            animating: isPlaying && isActive,
            barCount: barCount,
            barWidth: barWidth,
            pitch: pitch,
            minHeight: minHeight,
            maxHeight: maxHeight,
            color: NSColor(color)
        )
        .frame(width: contentWidth, height: maxHeight)
    }
}

/// The bars as plain layers. Each one animates `bounds.size.height` about a
/// fixed centre, so with `cornerRadius` pinned at half the bar width it stays
/// a true capsule at every height (a scale transform would squash the caps).
private struct WaveBarsLayerView: NSViewRepresentable {
    var animating: Bool
    var barCount: Int
    var barWidth: CGFloat
    var pitch: CGFloat
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var color: NSColor

    func makeNSView(context: Context) -> WaveBarsView {
        let view = WaveBarsView()
        view.configure(barCount: barCount, barWidth: barWidth, pitch: pitch,
                       minHeight: minHeight, maxHeight: maxHeight, color: color)
        view.setAnimating(animating)
        return view
    }

    func updateNSView(_ view: WaveBarsView, context: Context) {
        view.configure(barCount: barCount, barWidth: barWidth, pitch: pitch,
                       minHeight: minHeight, maxHeight: maxHeight, color: color)
        view.setAnimating(animating)
    }
}

final class WaveBarsView: NSView {
    private var bars: [CALayer] = []
    private var barWidth: CGFloat = 2.5
    private var pitch: CGFloat = 3.5
    private var minHeight: CGFloat = 3
    private var maxHeight: CGFloat = 9
    private var isAnimating = false

    /// Matches the old per-bar sine: period 2*pi/frequency, and an autoreversed
    /// animation completes a cycle in twice its duration.
    private static let frequencies: [Double] = [1.7, 2.3, 1.3, 2.6, 1.9]
    private static let phases: [Double] = [0.0, 1.1, 2.4, 0.6, 1.8]
    private static let animationKey = "wave"

    /// Height the bars settle to when paused, as a fraction of the range.
    private static let restFraction: CGFloat = 0.15
    /// The travel of an animating bar, as fractions of the range. Inset from
    /// 0...1 because the old wobble term rarely drove a bar fully to an end.
    private static let lowFraction: CGFloat = 0.1
    private static let highFraction: CGFloat = 0.9
    private static let settleDuration: CFTimeInterval = 0.25

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// A layer that leaves the tree loses its animations and does not get
    /// them back on its own, which would leave the bars frozen at rest with
    /// nothing to restart them until playback toggled.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, isAnimating else { return }
        startAnimations()
    }

    /// Layer-backed views do not redraw on their own when the backing scale
    /// changes, so the corner antialiasing has to be told about it.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        for bar in bars { bar.contentsScale = scale }
    }

    func configure(barCount: Int, barWidth: CGFloat, pitch: CGFloat,
                   minHeight: CGFloat, maxHeight: CGFloat, color: NSColor) {
        let geometryChanged = barWidth != self.barWidth || pitch != self.pitch
            || minHeight != self.minHeight || maxHeight != self.maxHeight
            || barCount != bars.count
        self.barWidth = barWidth
        self.pitch = pitch
        self.minHeight = minHeight
        self.maxHeight = maxHeight

        if barCount != bars.count {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<barCount).map { _ in
                let bar = CALayer()
                bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                bar.contentsScale = window?.backingScaleFactor ?? 2
                layer?.addSublayer(bar)
                return bar
            }
        }

        let cgColor = color.cgColor
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = cgColor
            bar.cornerRadius = barWidth / 2
            if geometryChanged {
                // Geometry is set outside any implicit animation: these are
                // static properties, only the height is ever animated.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bar.position = CGPoint(x: barWidth / 2 + CGFloat(index) * pitch,
                                       y: maxHeight / 2)
                bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: restHeight)
                CATransaction.commit()
            }
        }
        if geometryChanged && isAnimating {
            // Re-issue the animations against the new heights.
            isAnimating = false
            setAnimating(true)
        }
    }

    func setAnimating(_ animating: Bool) {
        guard animating != isAnimating else { return }
        isAnimating = animating
        animating ? startAnimations() : stopAnimations()
    }

    // MARK: - Private

    private var restHeight: CGFloat {
        minHeight + (maxHeight - minHeight) * Self.restFraction
    }

    private func startAnimations() {
        let low = minHeight + (maxHeight - minHeight) * Self.lowFraction
        let high = minHeight + (maxHeight - minHeight) * Self.highFraction
        let now = CACurrentMediaTime()

        for (index, bar) in bars.enumerated() {
            let frequency = Self.frequencies[index % Self.frequencies.count]
            let phase = Self.phases[index % Self.phases.count]
            // One autoreversed leg is half a sine period.
            let duration = Double.pi / frequency

            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = low
            animation.toValue = high
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Start each bar partway through its cycle so they don't move in
            // lockstep, the way the old per-bar phase offsets did.
            animation.timeOffset = (phase / frequency).truncatingRemainder(dividingBy: duration * 2)
            animation.beginTime = now
            animation.isRemovedOnCompletion = false

            bar.add(animation, forKey: Self.animationKey)
        }
    }

    private func stopAnimations() {
        for bar in bars {
            // Freeze at the height currently on screen, then ease down to the
            // resting height - the settle the old frame animation produced.
            let current = (bar.presentation() ?? bar).bounds.height
            bar.removeAnimation(forKey: Self.animationKey)

            let settle = CABasicAnimation(keyPath: "bounds.size.height")
            settle.fromValue = current
            settle.toValue = restHeight
            settle.duration = Self.settleDuration
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: restHeight)
            CATransaction.commit()
            bar.add(settle, forKey: Self.animationKey)
        }
    }
}
