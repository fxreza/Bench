import SwiftUI

/// Layout constants measured off Alcove 1.7.7 (docs/research/alcove-measurements.md,
/// "Volume / brightness HUD layout"). All numbers are points inside a wing of
/// `NotchMetrics.hudWingWidth` x notch height.
private enum HUDLayout {
    static let iconLeading: CGFloat = 10
    static let iconBoxWidth: CGFloat = 16
    static let iconFontSize: CGFloat = 14
    static let iconLabelGap: CGFloat = 11
    static let labelFontSize: CGFloat = 13

    static let barLength: CGFloat = 43.5
    static let barThickness: CGFloat = 5
    static let barLeading: CGFloat = 12.5
    static let barPercentGap: CGFloat = 9
    static let percentTrailing: CGFloat = 12.5
    static let percentFontSize: CGFloat = 13

    static let trackColor = Color(white: 0.36)
    /// Measured HUD bar response; the number cross-fades with `.numericText()`.
    static let fillAnimation = Animation.spring(response: 0.25, dampingFraction: 0.9)
}

/// Leading wing content of the volume/brightness HUD (icon + label).
/// Rendered inside a frame of `NotchMetrics.hudWingWidth` x notch height.
struct HUDLeadingView: View {
    let payload: HUDPayload

    var body: some View {
        HStack(spacing: HUDLayout.iconLabelGap) {
            Image(systemName: payload.symbolName)
                .font(.system(size: HUDLayout.iconFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: HUDLayout.iconBoxWidth)
            Text(payload.kind.label)
                .font(.system(size: HUDLayout.labelFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.leading, HUDLayout.iconLeading)
        .frame(width: NotchMetrics.hudWingWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color.clear)
        .animation(.easeOut(duration: 0.12), value: payload.symbolName)
    }
}

/// Trailing wing content of the HUD (bar + percentage).
struct HUDTrailingView: View {
    let payload: HUDPayload

    /// Muted reads as an empty bar and 0 %, matching the system bezel.
    private var displayLevel: Double { payload.isMuted ? 0 : min(max(payload.level, 0), 1) }
    private var displayPercent: Int { payload.isMuted ? 0 : payload.percent }

    var body: some View {
        HStack(spacing: 0) {
            // The number is trailing-anchored and the bar-to-number gap is
            // fixed at 9, so a three-digit "100" pushes the bar a few points
            // left instead of eating the gap; at one or two digits the bar
            // sits exactly 12.5 from the leading edge like Alcove.
            Spacer(minLength: 4)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(HUDLayout.trackColor)
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: HUDLayout.barLength * displayLevel)
            }
            .frame(width: HUDLayout.barLength, height: HUDLayout.barThickness)
            .animation(HUDLayout.fillAnimation, value: displayLevel)

            // Counts through the intermediate values on the same spring as
            // the bar (44, 46, 48, 50) instead of swapping digits, so the
            // number never blinks.
            CountingPercentText(value: Double(displayPercent))
                .animation(HUDLayout.fillAnimation, value: displayPercent)
                .fixedSize()
                .padding(.leading, 9)
        }
        .padding(.trailing, HUDLayout.percentTrailing)
        .frame(width: NotchMetrics.hudWingWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color.clear)
        .animation(.easeOut(duration: 0.12), value: payload.symbolName)
    }
}


/// Text whose integer value is animatable: SwiftUI interpolates `value`
/// frame by frame, and the label shows the rounded intermediate values.
private struct CountingPercentText: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .font(.system(size: HUDLayout.percentFontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
    }
}
