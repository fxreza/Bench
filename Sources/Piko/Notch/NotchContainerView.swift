import AppKit
import SwiftUI

/// Root SwiftUI view of the notch panel. The window never resizes: the shape
/// is drawn top-centre inside the fixed 624 x 320 panel and every size change
/// is a SwiftUI animation.
struct NotchContainerView: View {
    @ObservedObject var viewModel: NotchViewModel

    /// Content blurs and fades to black while the shape springs to its new
    /// size (Alcove: the player's artwork and buttons dim into the black and
    /// blur as the panel shrinks, and appear the same way in reverse).
    static let contentAnimation = Animation.easeInOut(duration: 0.28)

    var body: some View {
        let size = viewModel.currentSize
        let radii = viewModel.radii

        ZStack(alignment: .top) {
            Color.clear
            // The bezel physically blacks this rect out, so it changes nothing
            // on screen - but screenshots and recordings capture the
            // framebuffer behind the bezel, and without it they show the
            // desktop where the viewer sees black.
            physicalNotchFill
            notchBody(size: size, radii: radii)
        }
        .frame(width: NotchMetrics.windowSize.width,
               height: NotchMetrics.windowSize.height,
               alignment: .top)
        .opacity(viewModel.isHiddenBySystem ? 0 : 1)
    }

    // MARK: - Shape + content

    private func notchBody(size: CGSize, radii: (top: CGFloat, bottom: CGFloat)) -> some View {
        content(size: size)
            // Size, flares and radii are interpolated by an Animatable
            // modifier: the wings swap identity with the state, so plain
            // layout animation of the frame did not run (the shape jumped).
            .modifier(NotchGeometryModifier(width: size.width, height: size.height,
                                            topRadius: radii.top, bottomRadius: radii.bottom))
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowOffsetY)
            .background {
                NotchInteractionView(
                    topRadius: radii.top,
                    bottomRadius: radii.bottom,
                    isEnabled: !viewModel.isHiddenBySystem,
                    acceptsClick: !viewModel.isExpanded,
                    onHover: { viewModel.hoverChanged($0) },
                    onClick: { viewModel.handleClick() },
                    onSwipe: { viewModel.handleSwipe(down: $0) }
                )
            }
    }

    private var physicalNotchFill: some View {
        NotchShape(topRadius: NotchMetrics.idleTopRadius, bottomRadius: NotchMetrics.idleBottomRadius)
            .fill(Color.black)
            .frame(width: NotchShape.flaredWidth(body: viewModel.geometry.notchWidth,
                                                 topRadius: NotchMetrics.idleTopRadius),
                   height: viewModel.geometry.notchHeight)
            .allowsHitTesting(false)
    }

    /// Content layers. Every layer stays in the hierarchy and is faded and
    /// blurred in place (opacity 0 when not current) instead of being
    /// inserted/removed with a transition: AppKit renders a removed SwiftUI
    /// view as a detached layer that ignores the clip, which left a ghost of
    /// the player outside the shrinking shape.
    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let key = viewModel.state.contentKey
        ZStack(alignment: .top) {
            // Transient activity (HUD, device, low battery, peek). The last
            // one is kept so it can fade out after the state moved on.
            if let activity = viewModel.state.activity ?? lastActivity {
                let active = viewModel.state.activity != nil
                activityContent(activity, height: size.height, isActive: active)
                    .frame(width: NotchMetrics.hudWingWidth * 2 + viewModel.geometry.notchWidth, height: size.height)
                    .contentLayer(active: active, key: key)
            }
            if let info = viewModel.nowPlaying ?? lastNowPlaying {
                let active = viewModel.state == .nowPlaying
                wings(width: NotchMetrics.nowPlayingWingWidth, height: size.height) {
                    NowPlayingLeadingView(info: info)
                } trailing: {
                    NowPlayingTrailingView(info: info, isActive: active)
                }
                .contentLayer(active: active, key: key)
            }
            let expandedActive = viewModel.state == .expanded
            PlayerExpandedView(info: viewModel.nowPlaying,
                               controller: viewModel.mediaController,
                               isActive: expandedActive)
                .frame(width: NotchMetrics.expandedWidth, height: NotchMetrics.expandedHeight)
                .contentLayer(active: expandedActive, key: key)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onChange(of: viewModel.state) { _, newState in
            if let activity = newState.activity { lastActivity = activity }
        }
        .onChange(of: viewModel.nowPlaying) { _, info in
            if let info { lastNowPlaying = info }
        }
    }

    @State private var lastActivity: NotchActivity?
    @State private var lastNowPlaying: NowPlayingInfo?

    @ViewBuilder
    private func activityContent(_ activity: NotchActivity, height: CGFloat, isActive: Bool) -> some View {
        let wing = NotchMetrics.hudWingWidth
        switch activity {
        case .hud(let payload):
            wings(width: wing, height: height) {
                HUDLeadingView(payload: payload)
            } trailing: {
                HUDTrailingView(payload: payload)
            }
        case .device(let event):
            wings(width: wing, height: height) {
                DeviceLeadingView(event: event)
            } trailing: {
                DeviceTrailingView(event: event)
            }
        case .lowBattery(let status):
            wings(width: wing, height: height) {
                LowBatteryLeadingView(status: status)
            } trailing: {
                LowBatteryTrailingView(status: status)
            }
        case .trackPeek(let info):
            wings(width: wing, height: height) {
                TrackPeekLeadingView(info: info)
            } trailing: {
                NowPlayingTrailingView(info: info, isActive: isActive)
            }
        }
    }

    /// Wing layout: content only ever lives left and right of the physical
    /// notch; the notch rectangle itself stays empty black.
    private func wings<Leading: View, Trailing: View>(
        width wing: CGFloat,
        height: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        return HStack(spacing: 0) {
            leading().frame(width: wing, height: height)
            Color.clear.frame(width: viewModel.geometry.notchWidth, height: height)
            trailing().frame(width: wing, height: height)
        }
    }

    // MARK: - Shadow (measurements doc: only hover and the expanded panel)

    private var shadowOpacity: Double {
        if viewModel.isExpanded { return 0.45 }
        return viewModel.isHovering ? 0.35 : 0
    }

    private var shadowRadius: CGFloat { viewModel.isExpanded ? 20 : 12 }
    private var shadowOffsetY: CGFloat { viewModel.isExpanded ? 6 : 2 }

}

/// Equatable key for the shape's animated geometry.
private struct ShapeToken: Equatable {
    var width: CGFloat, height: CGFloat, top: CGFloat, bottom: CGFloat
    init(size: CGSize, radii: (top: CGFloat, bottom: CGFloat)) {
        width = size.width; height = size.height; top = radii.top; bottom = radii.bottom
    }
}

/// Frames the content at the notch body size, adds the flare padding and
/// draws/clips the black shape. Animatable so every intermediate size is
/// rendered regardless of what happens to the content's identity.
private struct NotchGeometryModifier: ViewModifier, Animatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(topRadius, bottomRadius)) }
        set {
            width = newValue.first.first; height = newValue.first.second
            topRadius = newValue.second.first; bottomRadius = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        // The flares live outside the body, so the drawn frame is wider than
        // the content by one top radius per side. The black fill is a sibling
        // layer, not a background of the content, so content transitions can
        // never blur or fade the shape itself.
        let drawnWidth = width + topRadius * 2
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            content
                .frame(width: width, height: height, alignment: .top)
                .padding(.horizontal, topRadius)
                // Flatten first: the blur in the content transition is
                // rendered as a layer effect that escapes a plain clip, which
                // left a ghost of the player outside the shrinking shape.
                .clipShape(shape)
        }
        .frame(width: drawnWidth, height: height, alignment: .top)
    }
}

/// Fades and blurs a content layer in place. Inactive layers are invisible
/// and ignore hits; the change animates with `NotchContainerView.contentAnimation`.
private struct ContentLayerModifier: ViewModifier {
    var active: Bool
    var key: String
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .blur(radius: active ? 0 : 6)
            .allowsHitTesting(active)
            .animation(NotchContainerView.contentAnimation, value: active)
    }
}

private extension View {
    func contentLayer(active: Bool, key: String) -> some View {
        modifier(ContentLayerModifier(active: active, key: key))
    }
}
