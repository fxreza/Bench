import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A full-display bitmap grabbed before any overlay is shown, so the overlay can
/// draw a frozen picture of the desktop and crop out of it later.
nonisolated struct FrozenScreen: Sendable {
    /// `NSScreen.frame` - global AppKit points, origin bottom-left of the primary screen.
    var screenFrame: CGRect
    var displayID: CGDirectDisplayID
    /// The whole display at native pixels.
    var image: CGImage
    /// Bitmap pixels per point (`image.width / screenFrame.width`).
    var pixelScale: CGFloat
}

/// Sendable edge insets (points) - `NSEdgeInsets` is not `Sendable`.
nonisolated struct ShotEdgeInsets: Sendable, Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat
}

nonisolated enum CaptureError: Error {
    case noPermission
    case noDisplay
    case noWindow
    case failed(String)
}

extension CaptureError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noPermission: return "Screen Recording permission is not granted."
        case .noDisplay: return "No matching display was found."
        case .noWindow: return "The window is no longer available."
        case .failed(let m): return "Capture failed: \(m)"
        }
    }
}

@MainActor
final class ScreenCapturer {

    static let shared = ScreenCapturer()

    /// Shadow margin, in points, added around a window when `includeShadow` is
    /// on - matches the room macOS's own ⌘⇧4 + space screenshot leaves.
    nonisolated static let shadowInsets = ShotEdgeInsets(top: 28, left: 34, bottom: 48, right: 34)
    nonisolated private static let shadowBlur: CGFloat = 30
    nonisolated private static let shadowOffsetY: CGFloat = -10
    nonisolated private static let shadowAlpha: CGFloat = 0.5

    private var cachedContent: SCShareableContent?
    private var cachedContentDate: Date = .distantPast
    private let contentCacheLifetime: TimeInterval = 2

    init() {}

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: - Shareable content

    /// Fresh shareable content, bypassing the cache.
    private func shareableContent() async throws -> SCShareableContent {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedContent = content
            cachedContentDate = Date()
            return content
        } catch {
            throw CaptureError.failed(String(describing: error))
        }
    }

    /// Shareable content, reused for `contentCacheLifetime` seconds. The
    /// scrolling capture calls `captureRegion` ~8x/sec and re-querying the
    /// window server every frame is far too slow.
    private func cachedShareableContent() async throws -> SCShareableContent {
        if let content = cachedContent, Date().timeIntervalSince(cachedContentDate) < contentCacheLifetime {
            return content
        }
        return try await shareableContent()
    }

    /// Windows belonging to this process - always excluded from captures.
    private nonisolated static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == pid }
    }

    private nonisolated static func display(_ content: SCShareableContent, id: CGDirectDisplayID) -> SCDisplay? {
        content.displays.first { $0.displayID == id }
    }

    private nonisolated static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    // MARK: - Freeze

    /// Captures every `NSScreen` concurrently, before any overlay is shown.
    /// Windows owned by this process are excluded, the cursor is hidden.
    func freezeAllScreens() async throws -> [FrozenScreen] {
        guard hasPermission else { throw CaptureError.noPermission }
        let content = try await shareableContent()
        let excluded = Self.ownWindows(in: content)

        // NSScreen is main-actor bound and not Sendable: snapshot what the task
        // group needs (id + frame) here, then fan out.
        let targets: [(CGDirectDisplayID, CGRect)] = NSScreen.screens.compactMap { screen in
            guard let id = Self.displayID(of: screen) else { return nil }
            return (id, screen.frame)
        }
        guard !targets.isEmpty else { throw CaptureError.noDisplay }

        let displays = content.displays

        return try await withThrowingTaskGroup(of: (Int, FrozenScreen).self) { group in
            for (index, target) in targets.enumerated() {
                let (id, frame) = target
                guard let display = displays.first(where: { $0.displayID == id }) else { continue }
                group.addTask {
                    let filter = SCContentFilter(display: display, excludingWindows: excluded)
                    let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1
                    let config = SCStreamConfiguration()
                    config.width = Int((filter.contentRect.width * scale).rounded())
                    config.height = Int((filter.contentRect.height * scale).rounded())
                    config.captureResolution = .best
                    config.showsCursor = false
                    config.scalesToFit = false
                    let image = try await Self.captureImage(filter: filter, configuration: config)
                    let pixelScale = frame.width > 0 ? CGFloat(image.width) / frame.width : scale
                    return (index, FrozenScreen(screenFrame: frame,
                                                displayID: id,
                                                image: image,
                                                pixelScale: pixelScale))
                }
            }
            var collected: [(Int, FrozenScreen)] = []
            for try await value in group { collected.append(value) }
            guard !collected.isEmpty else { throw CaptureError.noDisplay }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private nonisolated static func captureImage(filter: SCContentFilter,
                                                 configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw CaptureError.failed(String(describing: error))
        }
    }

    // MARK: - Crop

    /// Crops a frozen screen to `localRect`, given in that screen's **local**
    /// AppKit coordinates (points, origin bottom-left of that screen).
    /// The rect is snapped to whole bitmap pixels; the returned `screenRect` is
    /// the snapped rect back in global AppKit coordinates.
    nonisolated static func crop(_ frozen: FrozenScreen, localRect: CGRect, source: CaptureSource) -> CaptureResult? {
        let scale = max(frozen.pixelScale, 0.01)
        let r = localRect.standardized
        guard r.width > 0, r.height > 0 else { return nil }

        // AppKit local (bottom-left) -> bitmap pixels (top-left origin).
        let topDown = CGRect(x: r.origin.x,
                             y: frozen.screenFrame.height - r.maxY,
                             width: r.width,
                             height: r.height)
        var px = CGRect(x: (topDown.origin.x * scale).rounded(),
                        y: (topDown.origin.y * scale).rounded(),
                        width: (topDown.width * scale).rounded(),
                        height: (topDown.height * scale).rounded())
        px = px.intersection(CGRect(x: 0, y: 0, width: CGFloat(frozen.image.width), height: CGFloat(frozen.image.height)))
        guard px.width >= 1, px.height >= 1, let cropped = frozen.image.cropping(to: px) else { return nil }

        // Snapped pixels -> global AppKit points.
        let snappedLocalX = px.origin.x / scale
        let snappedWidth = px.width / scale
        let snappedHeight = px.height / scale
        let snappedLocalY = frozen.screenFrame.height - (px.origin.y / scale) - snappedHeight
        let global = CGRect(x: frozen.screenFrame.origin.x + snappedLocalX,
                            y: frozen.screenFrame.origin.y + snappedLocalY,
                            width: snappedWidth,
                            height: snappedHeight)

        return CaptureResult(image: cropped, pixelScale: scale, source: source, screenRect: global)
    }

    // MARK: - Region (live)

    /// Live capture of a global AppKit rect. Used by the scrolling capture,
    /// which calls this repeatedly (~8x/sec), so the shareable content is
    /// cached for a couple of seconds.
    ///
    /// The result's `source` is `.area`; callers that need another source
    /// (scrolling frames) overwrite it.
    func captureRegion(_ globalRect: CGRect, excludingWindowIDs: [CGWindowID]) async throws -> CaptureResult {
        guard hasPermission else { throw CaptureError.noPermission }
        let rect = globalRect.standardized
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.failed("empty region") }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) })
                ?? NSScreen.main,
              let displayID = Self.displayID(of: screen) else { throw CaptureError.noDisplay }
        let screenFrame = screen.frame

        let content = try await cachedShareableContent()
        guard let display = Self.display(content, id: displayID) else { throw CaptureError.noDisplay }

        let excludeSet = Set(excludingWindowIDs)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter {
            $0.owningApplication?.processID == ownPID || excludeSet.contains($0.windowID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1

        // SCStreamConfiguration.sourceRect is display-local, top-left origin, points.
        let source = CGRect(x: rect.origin.x - screenFrame.origin.x,
                            y: screenFrame.maxY - rect.maxY,
                            width: rect.width,
                            height: rect.height)

        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        let image = try await Self.captureImage(filter: filter, configuration: config)
        return CaptureResult(image: image, pixelScale: scale, source: .area, screenRect: rect)
    }

    // MARK: - Window

    /// Captures one window. ScreenCaptureKit returns the window content without
    /// its shadow, so when `includeShadow` is on the bitmap is redrawn onto a
    /// transparent canvas padded by `shadowInsets` with a soft drop shadow
    /// beneath it - the macOS ⌘⇧4 + space look.
    func captureWindow(_ window: WindowInfo, includeShadow: Bool) async throws -> CaptureResult {
        guard hasPermission else { throw CaptureError.noPermission }
        let content = try await shareableContent()
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            throw CaptureError.noWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1
        let config = SCStreamConfiguration()
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        let image = try await Self.captureImage(filter: filter, configuration: config)

        guard includeShadow else {
            return CaptureResult(image: image, pixelScale: scale, source: .window, screenRect: window.frame)
        }

        let insets = Self.shadowInsets
        guard let shadowed = Self.drawShadow(image, pixelScale: scale) else {
            return CaptureResult(image: image, pixelScale: scale, source: .window, screenRect: window.frame)
        }
        let expanded = CGRect(x: window.frame.origin.x - insets.left,
                              y: window.frame.origin.y - insets.bottom,
                              width: window.frame.width + insets.left + insets.right,
                              height: window.frame.height + insets.top + insets.bottom)
        return CaptureResult(image: shadowed, pixelScale: scale, source: .window, screenRect: expanded)
    }

    /// Draws `image` onto a transparent canvas padded by `shadowInsets` with a
    /// macOS-like drop shadow underneath.
    nonisolated static func drawShadow(_ image: CGImage, pixelScale: CGFloat) -> CGImage? {
        let scale = max(pixelScale, 0.01)
        let insets = shadowInsets
        let left = Int((insets.left * scale).rounded())
        let right = Int((insets.right * scale).rounded())
        let top = Int((insets.top * scale).rounded())
        let bottom = Int((insets.bottom * scale).rounded())
        let width = image.width + left + right
        let height = image.height + top + bottom

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        ctx.interpolationQuality = .high
        ctx.setShadow(offset: CGSize(width: 0, height: shadowOffsetY * scale),
                      blur: shadowBlur * scale,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: shadowAlpha))
        // Bitmap context origin is bottom-left; the window sits `bottom` px up.
        ctx.draw(image, in: CGRect(x: CGFloat(left), y: CGFloat(bottom),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    // MARK: - Screen

    /// Whole display, our own windows excluded.
    func captureScreen(_ screen: NSScreen) async throws -> CaptureResult {
        guard hasPermission else { throw CaptureError.noPermission }
        guard let displayID = Self.displayID(of: screen) else { throw CaptureError.noDisplay }
        let frame = screen.frame
        let content = try await shareableContent()
        guard let display = Self.display(content, id: displayID) else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: Self.ownWindows(in: content))
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1
        let config = SCStreamConfiguration()
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        let image = try await Self.captureImage(filter: filter, configuration: config)
        let pixelScale = frame.width > 0 ? CGFloat(image.width) / frame.width : scale
        return CaptureResult(image: image, pixelScale: pixelScale, source: .screen, screenRect: frame)
    }
}
