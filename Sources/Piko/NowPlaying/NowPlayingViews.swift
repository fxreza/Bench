import AppKit
import SwiftUI

// MARK: - Shared artwork tile

/// Rounded artwork square used by all now-playing surfaces; falls back to a
/// dark placeholder tile with a music-note glyph when there's no artwork.
private struct ArtworkTile: View {
    let image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat
    var iconSize: CGFloat
    var placeholderFill: Color = Color(white: 0.16)
    var iconColor: Color = .gray

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(placeholderFill)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: iconSize))
                        .foregroundColor(iconColor)
                )
        }
    }
}

/// Formats a duration as "0:02", "12:34" or "1:02:33".
private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

// MARK: - Compact now-playing wings

/// Leading wing of the compact now-playing state: 22x22 artwork.
struct NowPlayingLeadingView: View {
    let info: NowPlayingInfo

    private let artworkSize: CGFloat = 22
    private let cornerRadius: CGFloat = 5
    private let leadingPadding: CGFloat = 5

    var body: some View {
        HStack(spacing: 0) {
            ArtworkTile(image: info.artwork, size: artworkSize, cornerRadius: cornerRadius, iconSize: 10)
                .padding(.leading, leadingPadding)
            Spacer(minLength: 0)
        }
        .frame(width: NotchMetrics.nowPlayingWingWidth)
        .frame(maxHeight: .infinity)
    }
}

/// Trailing wing of the compact now-playing state: 5 animated wave bars.
struct NowPlayingTrailingView: View {
    let info: NowPlayingInfo
    /// False while this wing's content layer is faded out; stops the wave
    /// from driving the display link for a layer nobody can see.
    var isActive: Bool = true

    private let trailingPadding: CGFloat = 9

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            AudioWaveView(
                isPlaying: info.isPlaying,
                isActive: isActive,
                barCount: 5,
                barWidth: 2.5,
                pitch: 3.5,
                minHeight: 3,
                maxHeight: 9,
                color: Color(white: 0.45)
            )
            .padding(.trailing, trailingPadding)
        }
        .frame(width: NotchMetrics.nowPlayingWingWidth)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Track peek

/// Track peek content (artwork + title/artist) shown in the leading wing
/// when a track starts or changes.
struct TrackPeekLeadingView: View {
    let info: NowPlayingInfo

    private let wingWidth: CGFloat = NotchMetrics.hudWingWidth // 92
    private let artworkSize: CGFloat = 22
    private let cornerRadius: CGFloat = 5
    private let leadingPadding: CGFloat = 10
    private let gap: CGFloat = 8

    var body: some View {
        HStack(spacing: gap) {
            ArtworkTile(image: info.artwork, size: artworkSize, cornerRadius: cornerRadius, iconSize: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title.isEmpty ? "No Title" : info.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(info.artist)
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, leadingPadding)
        .frame(width: wingWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Expanded player

/// Full player shown in the expanded panel (380 x 178 content area).
struct PlayerExpandedView: View {
    let info: NowPlayingInfo?
    let controller: MediaController?
    /// False while the notch is collapsed. This view stays in the hierarchy
    /// at opacity 0 (see `NotchContainerView.content`), so without this its
    /// wave and scrubber keep ticking behind a panel nobody can see.
    var isActive: Bool = true

    private enum Layout {
        static let width: CGFloat = NotchMetrics.expandedWidth   // 380
        static let height: CGFloat = NotchMetrics.expandedHeight // 178

        static let artworkSize: CGFloat = 56
        static let artworkRadius: CGFloat = 10
        static let artworkX: CGFloat = 18
        static let artworkY: CGFloat = 18

        // The physical notch covers the top 38 pt of this panel, x 80...300 of
        // 380, so the title has to start below it - at y 18 the whole first
        // line sat behind the bezel and was only visible in screenshots (which
        // capture the framebuffer behind it). 44 puts the title's centre at 53
        // and the artist's at 73, matching Alcove.
        static let titleBlockX: CGFloat = 85
        static let titleBlockY: CGFloat = 44
        static let titleBlockWidth: CGFloat = 231

        static let waveGlyphX: CGFloat = 330
        static let waveGlyphY: CGFloat = 48
        static let waveGlyphWidth: CGFloat = 25
        static let waveGlyphHeight: CGFloat = 10

        static let timeRowY: CGFloat = 87
        static let elapsedX: CGFloat = 20
        static let remainingRightEdge: CGFloat = 359

        static let scrubberX: CGFloat = 52
        static let scrubberWidth: CGFloat = 322 - 52
        static let scrubberCenterY: CGFloat = 104
        static let scrubberHitHeight: CGFloat = 20

        static let controlRowY: CGFloat = 128
        static let buttonWidth: CGFloat = 48
        static let buttonHeight: CGFloat = 46
        static let backwardX: CGFloat = 91
        static let playX: CGFloat = 165
        static let forwardX: CGFloat = 239
    }

    @State private var dragProgress: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let info {
                playingContent(info)
            } else {
                Text("Nothing playing")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .frame(width: Layout.width, height: Layout.height)
            }
        }
        .frame(width: Layout.width, height: Layout.height)
    }

    @ViewBuilder
    private func playingContent(_ info: NowPlayingInfo) -> some View {
        ArtworkTile(
            image: info.artwork,
            size: Layout.artworkSize,
            cornerRadius: Layout.artworkRadius,
            iconSize: 22
        )
        .offset(x: Layout.artworkX, y: Layout.artworkY)

        titleBlock(info)
            .frame(width: Layout.titleBlockWidth, alignment: .leading)
            .offset(x: Layout.titleBlockX, y: Layout.titleBlockY)

        AudioWaveView(
            isPlaying: info.isPlaying,
            isActive: isActive,
            barCount: 5,
            barWidth: 2,
            pitch: 5,
            minHeight: 3,
            maxHeight: Layout.waveGlyphHeight,
            color: Color(white: 0.45)
        )
        .frame(width: Layout.waveGlyphWidth, height: Layout.waveGlyphHeight)
        .offset(x: Layout.waveGlyphX, y: Layout.waveGlyphY)

        if let duration = info.duration {
            timeAndScrubber(info: info, duration: duration)
        }

        controlRow(info: info)
    }

    @ViewBuilder
    private func titleBlock(_ info: NowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title.isEmpty ? "No Title" : info.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(info.title.isEmpty ? Color(white: 0.5) : .white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(info.artist)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.6))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func timeAndScrubber(info: NowPlayingInfo, duration: TimeInterval) -> some View {
        // `.animation(minimumInterval:)` rather than `.periodic`: same ~2 Hz
        // tick, but it can be paused while the panel is collapsed. The first
        // tick after expanding recomputes the position from `info`, so the
        // scrubber is never stale.
        TimelineView(.animation(minimumInterval: 0.5, paused: !isActive)) { timeline in
            let livePosition = info.position(at: timeline.date)
            let shownSeconds = dragProgress.map { $0 * duration } ?? livePosition
            let shownProgress = duration > 0 ? shownSeconds / duration : 0
            // One row from x 20 to x 359 (Alcove: labels at the edges, the
            // scrubber fills what is left so long labels like 1:02:33 never
            // overlap the bar).
            HStack(spacing: 8) {
                Text(formatDuration(shownSeconds))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                    .frame(minWidth: 26, alignment: .leading)
                ScrubberView(
                    progress: shownProgress,
                    duration: duration,
                    dragProgress: $dragProgress,
                    onSeek: { seconds in controller?.send(.seek(seconds)) }
                )
                .frame(height: Layout.scrubberHitHeight)
                Text("-" + formatDuration(max(0, duration - shownSeconds)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                    .frame(minWidth: 30, alignment: .trailing)
            }
            .frame(width: Layout.remainingRightEdge - Layout.elapsedX, height: Layout.scrubberHitHeight)
            .offset(x: Layout.elapsedX, y: Layout.scrubberCenterY - Layout.scrubberHitHeight / 2)
            .frame(width: Layout.width, height: Layout.height, alignment: .topLeading)
        }
    }

    private func controlRow(info: NowPlayingInfo) -> some View {
        ZStack(alignment: .topLeading) {
        // `.end.fill` rather than plain `backward.fill`/`forward.fill`: these
        // send previous/next track, not seek, and the bar on the end of the
        // glyph is the platform's way of saying skip rather than scan.
        playerButton(systemName: "backward.end.fill", size: 20, color: Color(white: 0.85)) {
            controller?.send(.previous)
        }
        .offset(x: Layout.backwardX, y: Layout.controlRowY)

        playerButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", size: 26, color: .white) {
            controller?.send(.togglePlayPause)
        }
        .offset(x: Layout.playX, y: Layout.controlRowY)

        playerButton(systemName: "forward.end.fill", size: 20, color: Color(white: 0.85)) {
            controller?.send(.next)
        }
        .offset(x: Layout.forwardX, y: Layout.controlRowY)
        }
        .frame(width: Layout.width, height: Layout.height, alignment: .topLeading)
    }

    private func playerButton(systemName: String, size: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundColor(color)
                .frame(width: Layout.buttonWidth, height: Layout.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedOpacityButtonStyle())
    }
}

/// Plain button style (no chrome) that dims the label while pressed.
private struct PressedOpacityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.4 : 1.0)
    }
}
