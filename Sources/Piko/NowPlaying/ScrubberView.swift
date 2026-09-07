import SwiftUI

/// A thin draggable progress bar for the expanded player. Draws a rounded
/// track + fill at `barHeight`, but hit-tests over a taller invisible area
/// so the bar is easy to grab. While dragging, `dragProgress` is kept
/// up to date (0...1) so a caller can mirror the scrub position in nearby
/// time labels; on release, `onSeek` fires once with the seek target in
/// seconds.
struct ScrubberView: View {
    /// Authoritative progress (0...1) used whenever the user isn't dragging.
    var progress: Double
    var duration: TimeInterval
    var trackColor: Color = Color(white: 0.23)
    var fillColor: Color = Color(white: 0.56)
    var barHeight: CGFloat = 4
    @Binding var dragProgress: Double?
    var onSeek: (TimeInterval) -> Void

    private func clamped(_ value: Double) -> Double {
        min(max(0, value), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let shown = dragProgress ?? clamped(progress)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackColor)
                    .frame(width: width, height: barHeight)
                Capsule(style: .continuous)
                    .fill(fillColor)
                    .frame(width: max(barHeight, width * CGFloat(shown)), height: barHeight)
            }
            .frame(width: width, height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        dragProgress = clamped(Double(value.location.x / width))
                    }
                    .onEnded { value in
                        guard width > 0 else { dragProgress = nil; return }
                        let p = clamped(Double(value.location.x / width))
                        dragProgress = nil
                        onSeek(duration * p)
                    }
            )
        }
    }
}
