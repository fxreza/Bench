import AppKit
import ApplicationServices
import CoreGraphics
import NaturalLanguage

/// "Point-translate": reads whatever the mouse pointer is resting on when
/// nothing is selected.
///
/// Two strategies, cheapest first:
///
///  1. **Accessibility hit-test.** `AXUIElementCopyElementAtPosition` on the
///     system-wide element returns the UI element under the pointer in *any*
///     app — a button, a label, an alert's message, a menu item. This is exact
///     text, costs a couple of cross-process calls, and works on things that
///     can't be selected at all.
///  2. **OCR of a screen-wide strip around the pointer.** The fallback for anything
///     AX can't see: canvas-drawn UI, games, images, remote-desktop sessions.
///
/// Returning `nil` is a normal outcome — the caller then opens the type-text
/// input, so the hotkey always does *something*.
enum PointerTextCapture {

    /// Whole-cascade deadline. AX is bounded by the process AX messaging
    /// timeout (see `TextCapture.configureAccessibilityTimeout`) and OCR by
    /// whatever is left, so one wedged app can't leave the popup spinning.
    private static let totalBudget: TimeInterval = 2.0

    /// Height of the strip OCR'd around the pointer, in points. The strip
    /// spans the full screen width — anything narrower slices long lines
    /// mid-word at the region edges, leaving fragments no sentence boundary
    /// can be found in. The height only needs to hold the few neighboring
    /// lines the sentence around the pointer can wrap across.
    private static let ocrRegionHeight: CGFloat = 140

    /// Longest value we'll accept from a single element. A focused text area
    /// can hold a whole document; the user pointed at it, they didn't ask to
    /// translate all of it, and the engines charge by the character.
    private static let maxValueLength = 2000

    /// Text under the pointer: AX element first, OCR fallback. `location` is
    /// in Cocoa screen coordinates (NSEvent.mouseLocation, bottom-left origin).
    static func text(at location: NSPoint) async -> String? {
        let deadline = Date().addingTimeInterval(totalBudget)

        switch await MainActor.run(resultType: AXHit.self, body: { axText(at: location) }) {
        case .text(let text):
            return text
        case .ownProcess:
            // The pointer is over our own popup. OCR here would just read the
            // last translation back to itself, so give up and let the caller
            // fall through to the input field.
            return nil
        case .none:
            break
        }

        guard Date() < deadline else { return nil }
        guard let region = await MainActor.run(resultType: PointerRegion?.self, body: {
            ScreenCaptureManager.shared.hasPermission ? pointerRegion(around: location) : nil
        }) else {
            // No Screen Recording grant, or no screen to capture: skip OCR
            // silently. The hotkey's headline job is selection translation;
            // nagging about a permission here would be noise.
            return nil
        }

        return await withDeadline(deadline.timeIntervalSinceNow) {
            await ocrText(in: region)
        } ?? nil
    }

    // MARK: - Accessibility

    private enum AXHit {
        case text(String)
        /// The element belongs to Transi itself.
        case ownProcess
        case none
    }

    /// AX hit-test at the pointer. Runs on the main actor because AX element
    /// handles are not safe to pass across executors, and the calls are
    /// millisecond-scale with the tightened messaging timeout.
    @MainActor
    private static func axText(at location: NSPoint) -> AXHit {
        // AX global coordinates are top-left-origin; `NSEvent.mouseLocation`
        // is bottom-left-origin relative to the *primary* screen. Flip against
        // the primary screen's height — not the pointer's own screen, whose
        // frame is already expressed in the same primary-anchored space.
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return .none }
        let axPoint = CGPoint(x: location.x, y: primaryMaxY - location.y)

        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(
            system, Float(axPoint.x), Float(axPoint.y), &element) == .success,
            let hit = element
        else { return .none }

        var pid: pid_t = 0
        if AXUIElementGetPid(hit, &pid) == .success, pid == getpid() {
            return .ownProcess
        }

        // Menus, toolbar items and table cells routinely put the label on a
        // wrapper rather than on the deepest element under the pointer, so
        // walk a couple of parents before giving up.
        var current: AXUIElement? = hit
        for _ in 0...2 {
            guard let element = current else { break }
            if let text = extractText(from: element) { return .text(text) }
            current = axElement(copyAttribute(element, kAXParentAttribute as String))
        }
        return .none
    }

    /// First non-empty attribute wins, in the order the user most likely means.
    private static func extractText(from element: AXUIElement) -> String? {
        let role = copyAttribute(element, kAXRoleAttribute as String) as? String

        // A window's or application's AXTitle is the document/app name, never
        // what the pointer is resting on — pointing at empty window chrome
        // must fall through to OCR instead of translating "Untitled 2".
        if role == kAXWindowRole as String || role == kAXApplicationRole as String { return nil }

        if let text = string(copyAttribute(element, kAXSelectedTextAttribute as String)) {
            return text
        }
        // Value only when it's genuinely a string: sliders, checkboxes and
        // progress indicators all answer AXValue with a number.
        if let text = string(copyAttribute(element, kAXValueAttribute as String)) {
            return String(text.prefix(maxValueLength))
        }
        if let text = string(copyAttribute(element, kAXTitleAttribute as String)) {
            return text
        }
        if let text = string(copyAttribute(element, kAXDescriptionAttribute as String)) {
            return text
        }
        return string(copyAttribute(element, kAXPlaceholderValueAttribute as String))
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// Type-checked unwrap: a conditional cast from `CFTypeRef` to a CF type
    /// is unchecked in Swift and would trap on a surprising attribute value,
    /// so ask CoreFoundation what it actually is.
    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Accepts a CF value only if it is a usable string. Single characters and
    /// whitespace are dropped: AX is full of "", " " and "1" placeholders that
    /// would send a pointless translation request.
    private static func string(_ value: CFTypeRef?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 ? trimmed : nil
    }

    // MARK: - OCR fallback

    /// A screen region in CoreGraphics global coordinates (top-left origin)
    /// plus the pointer's position inside it, so the closest recognized line
    /// can be picked out of the result.
    private struct PointerRegion: Sendable {
        let rect: CGRect
        let pointer: CGPoint
    }

    @MainActor
    private static func pointerRegion(around location: NSPoint) -> PointerRegion? {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return nil }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) })
            ?? NSScreen.main
        else { return nil }

        // Full screen width, vertically centered on the pointer, then slid
        // (not cropped) back onto the pointer's screen so a pointer near the
        // top or bottom edge still gets a full-height strip of context.
        var rect = NSRect(
            x: screen.frame.minX,
            y: location.y - ocrRegionHeight / 2,
            width: screen.frame.width,
            height: ocrRegionHeight)
        rect.origin.y = min(max(rect.minY, screen.frame.minY), screen.frame.maxY - rect.height)
        rect = rect.intersection(screen.frame)
        guard rect.width > 8, rect.height > 8 else { return nil }

        return PointerRegion(
            rect: CGRect(
                x: rect.minX, y: primaryMaxY - rect.maxY,
                width: rect.width, height: rect.height),
            pointer: CGPoint(x: location.x, y: primaryMaxY - location.y))
    }

    private static func ocrText(in region: PointerRegion) async -> String? {
        // CGWindowListCreateImage is deprecated as of macOS 14 but still
        // present and functional, and it is the only screenshot API available
        // on our macOS 13 floor. ScreenCaptureKit's SCScreenshotManager is the
        // macOS 14+ replacement to migrate to once the floor moves. This is
        // the same call ScreenCaptureManager uses for drag-select capture.
        guard let cgImage = CGWindowListCreateImage(
            region.rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        else { return nil }

        guard let lines = try? await OCRService.recognizeLines(in: cgImage), !lines.isEmpty else {
            return nil
        }

        // Vision reports normalized, bottom-left-origin boxes; convert the
        // pointer into the same space so "the line I'm pointing at" is a
        // simple containment test.
        let normalized = CGPoint(
            x: (region.pointer.x - region.rect.minX) / region.rect.width,
            y: 1 - (region.pointer.y - region.rect.minY) / region.rect.height)

        // The line under the pointer; failing that, the nearest line, but only
        // if it is close. A match at the far edge of the region is text the
        // user never aimed at, and a wrong translation is worse than the
        // input field opening.
        let hit = lines.first(where: { $0.boundingBox.contains(normalized) })
            ?? lines
                .map { ($0, distance(from: normalized, to: $0.boundingBox)) }
                .min { $0.1 < $1.1 }
                .flatMap { $0.1 <= 0.25 ? $0.0 : nil }
        guard let hit else { return nil }

        return sentence(around: hit, pointer: normalized, in: lines)
    }

    /// Expands the pointed-at line to the *sentence* around the pointer: the
    /// hit line is merged with the neighboring lines of its paragraph (small
    /// vertical gap, horizontal overlap), the block is joined into one string,
    /// and the sentence containing the pointer's position is cut out of it.
    /// A bare line is a fragment cut at the wrap point; the sentence is what
    /// the user actually means to translate.
    private static func sentence(
        around hit: OCRService.Line, pointer: CGPoint, in lines: [OCRService.Line]
    ) -> String {
        // Top-to-bottom reading order (Vision boxes are bottom-left-origin).
        let ordered = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        guard let hitPos = ordered.firstIndex(where: {
            $0.boundingBox == hit.boundingBox && $0.text == hit.text
        }) else { return hit.text }

        // Grow the paragraph block line by line in both directions.
        var first = hitPos
        var last = hitPos
        while first > 0, sameParagraph(above: ordered[first - 1], below: ordered[first]) {
            first -= 1
        }
        while last < ordered.count - 1, sameParagraph(above: ordered[last], below: ordered[last + 1]) {
            last += 1
        }

        // Join the block into one string, remembering where the hit line sits.
        var joined = ""
        var hitRange: Range<String.Index>?
        for index in first...last {
            if !joined.isEmpty { joined.append(" ") }
            let start = joined.endIndex
            joined.append(ordered[index].text)
            if index == hitPos { hitRange = start..<joined.endIndex }
        }
        guard let hitRange, !joined.isEmpty else { return hit.text }

        // Approximate the character the pointer rests on from its horizontal
        // position within the hit line's box; RTL scripts read right-to-left,
        // so the proportion mirrors. Only matters when a sentence boundary
        // falls mid-line, so an estimate is plenty.
        let box = hit.boundingBox
        var relX = box.width > 0 ? (pointer.x - box.minX) / box.width : 0.5
        relX = min(max(relX, 0), 1)
        let bucket = ScriptDetector.detectScriptBucket(hit.text)
        if bucket == .arabic || bucket == .hebrew { relX = 1 - relX }
        let hitCount = joined.distance(from: hitRange.lowerBound, to: hitRange.upperBound)
        let offset = min(Int(relX * CGFloat(hitCount)), max(hitCount - 1, 0))
        let target = joined.index(hitRange.lowerBound, offsetBy: offset)

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = joined
        let sentence = joined[tokenizer.tokenRange(at: target)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? hit.text : sentence
    }

    /// Whether two vertically adjacent lines belong to the same paragraph:
    /// the gap between them is under a line-height and they overlap
    /// horizontally. Column gutters and unrelated UI text fail both.
    private static func sameParagraph(above: OCRService.Line, below: OCRService.Line) -> Bool {
        let a = above.boundingBox
        let b = below.boundingBox
        let gap = a.minY - b.maxY
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return gap < max(a.height, b.height) * 0.9 && overlap > 0
    }

    private static func distance(from point: CGPoint, to box: CGRect) -> CGFloat {
        let dx = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = max(box.minY - point.y, 0, point.y - box.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Deadline

    /// Returns `body`'s result, or `nil` if it doesn't finish in time. Mirrors
    /// `TextCapture.withDeadline`: the abandoned work isn't interrupted, we
    /// just stop waiting on it.
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        guard seconds > 0 else { return nil }
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
