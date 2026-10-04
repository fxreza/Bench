import AppKit

@MainActor
protocol AnnotationCanvasDelegate: AnyObject {
    func canvasSelectionDidChange(_ canvas: AnnotationCanvasView)
    func canvasDocumentDidChange(_ canvas: AnnotationCanvasView)
    /// A shape was placed with `tool` (hosts may keep the tool active or switch back to select).
    func canvasDidPlaceAnnotation(_ canvas: AnnotationCanvasView, tool: EditorTool)
    func canvasCropStateDidChange(_ canvas: AnnotationCanvasView)
    /// Unhandled key press (tool letters, Enter, Esc when nothing to cancel).
    func canvas(_ canvas: AnnotationCanvasView, didReceiveUnhandledKey event: NSEvent) -> Bool
}

/// The shared drawing surface used by the capture overlay and the editor
/// window. View coordinates == image points (flipped, origin top-left); the
/// host scales it (NSScrollView magnification) and sets `viewScale` so
/// handles and hover strokes keep a constant on-screen size.
@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let document: AnnotationDocument
    weak var delegate: AnnotationCanvasDelegate?

    var tool: EditorTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .crop { cancelCrop() }
            if tool != .select { endTextEditing(commit: true) }
            if tool == .crop, cropRect == nil { cropRect = document.bounds.insetBy(dx: 0, dy: 0) ; delegate?.canvasCropStateDidChange(self) }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    /// Style applied to newly created annotations.
    var style = ToolStyle()
    var accentColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    /// Host magnification (1 = 100%). Used to keep chrome a constant screen size.
    var viewScale: CGFloat = 1 { didSet { needsDisplay = true } }

    private(set) var selectedID: UUID? { didSet { if selectedID != oldValue { delegate?.canvasSelectionDidChange(self); needsDisplay = true } } }
    private(set) var hoveredID: UUID? { didSet { if hoveredID != oldValue { needsDisplay = true } } }
    var selectedAnnotation: Annotation? {
        if let p = pendingText { return p }
        return selectedID.flatMap { document.annotation(id: $0) }
    }

    private(set) var cropRect: CGRect? { didSet { needsDisplay = true } }
    var isCropping: Bool { tool == .crop && cropRect != nil }

    // MARK: drag state
    private enum Drag {
        case none
        case drawing(Annotation)
        case moving(original: Annotation, start: CGPoint, moved: Bool)
        case handle(HandleKind, original: Annotation)
        case cropDrawing(start: CGPoint)
        case cropMoving(original: CGRect, start: CGPoint)
        case cropHandle(HandleKind, original: CGRect)
    }
    private var drag: Drag = .none
    private var trackingArea: NSTrackingArea?

    // MARK: text editing
    private var textView: NSTextView?
    private var editingID: UUID?
    private var pendingText: Annotation?          // new label not yet in the document
    private var textOriginal: Annotation?         // existing label as it was before editing
    var isEditingText: Bool { textView != nil }

    // MARK: init

    init(document: AnnotationDocument) {
        self.document = document
        super.init(frame: CGRect(origin: .zero, size: document.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        document.onChange = { [weak self] in
            guard let self else { return }
            self.syncFrame()
            if let id = self.selectedID, self.document.annotation(id: id) == nil { self.selectedID = nil }
            if let id = self.hoveredID, self.document.annotation(id: id) == nil { self.hoveredID = nil }
            self.needsDisplay = true
            self.delegate?.canvasDocumentDidChange(self)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func syncFrame() {
        let s = document.size
        if frame.size != s { setFrameSize(s) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: chrome sizes (screen-constant)
    private var handleRadius: CGFloat { 4.5 / viewScale }
    private var hitTolerance: CGFloat { 6 / viewScale }
    private var chromeLine: CGFloat { 1 / viewScale }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = document.size
        // base image (flip back for CGImage drawing)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(document.image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()

        // committed annotations (the one being text-edited is drawn too; the text view covers its text)
        var toDraw = document.annotations
        if case .drawing(let a) = drag { toDraw.append(a) }
        else if case .moving(_, _, _) = drag {} // live updates are already in the document (coalesced)
        if let p = pendingText { toDraw.append(p) }
        AnnotationRenderer.draw(toDraw, sourceImage: document.image, pixelScale: document.pixelScale, in: ctx)

        // hover + selection emphasis
        let accent = accentColor.cgColor
        if let hid = hoveredID, hid != selectedID, let a = document.annotation(id: hid), !isDrawingDrag {
            AnnotationRenderer.drawEmphasis(for: a, hovered: true, selected: false, accent: accent, in: ctx)
        }
        if let sel = selectedAnnotation, !isEditingText {
            drawHandles(HitTesting.handles(for: sel).map(\.position), in: ctx)
        }

        // crop overlay
        if tool == .crop, let c = cropRect {
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
            let outside = CGMutablePath()
            outside.addRect(bounds)
            outside.addRect(c)
            ctx.addPath(outside)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(chromeLine)
            ctx.stroke(c.insetBy(dx: chromeLine / 2, dy: chromeLine / 2))
            // rule of thirds
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
            for i in 1...2 {
                let x = c.minX + c.width * CGFloat(i) / 3, y = c.minY + c.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: c.minY)); ctx.addLine(to: CGPoint(x: x, y: c.maxY))
                ctx.move(to: CGPoint(x: c.minX, y: y)); ctx.addLine(to: CGPoint(x: c.maxX, y: y))
            }
            ctx.strokePath()
            ctx.restoreGState()
            drawHandles(Array(RectGeometry.handlePositions(for: c).values), in: ctx)
        }
    }

    private var isDrawingDrag: Bool { if case .drawing = drag { return true }; return false }

    private func drawHandles(_ points: [CGPoint], in ctx: CGContext) {
        let r = handleRadius
        ctx.saveGState()
        ctx.setLineWidth(chromeLine)
        for p in points {
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let path = CGPath(roundedRect: rect, cornerWidth: r * 0.35, cornerHeight: r * 0.35, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 0.9))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: selection API

    func select(_ id: UUID?) {
        if id != selectedID { endTextEditing(commit: true) }
        selectedID = id
    }

    func deleteSelection() {
        guard let id = selectedID else { return }
        endTextEditing(commit: false)
        document.remove(id: id)
        selectedID = nil
    }

    /// Mutates the selected annotation as one undo step (used by the properties panel).
    func updateSelected(_ mutate: (inout Annotation) -> Void) {
        if var p = pendingText {
            mutate(&p)
            p.rect = AnnotationRenderer.measureTextRect(for: p)
            pendingText = p
            styleTextView(); layoutTextView(); needsDisplay = true
            return
        }
        guard var a = selectedAnnotation else { return }
        mutate(&a)
        if a.kind == .text { a.rect = AnnotationRenderer.measureTextRect(for: a) }
        document.update(a)
        if isEditingText { styleTextView(); layoutTextView() }
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard var a = selectedAnnotation else { return }
        a.translate(dx: dx, dy: dy)
        document.update(a, coalesce: true)
    }

    func undo() { endTextEditing(commit: true); document.undo() }
    func redo() { endTextEditing(commit: true); document.redo() }

    // MARK: crop API

    func beginCrop() { tool = .crop }

    func applyCrop() {
        guard let c = cropRect?.standardized.intersection(document.bounds), c.width >= 1, c.height >= 1 else { cancelCrop(); return }
        let full = document.bounds
        cropRect = nil
        if c != full { document.crop(to: c) }
        tool = .select
        delegate?.canvasCropStateDidChange(self)
    }

    func cancelCrop() {
        guard cropRect != nil else { return }
        cropRect = nil
        if tool == .crop { tool = .select }
        delegate?.canvasCropStateDidChange(self)
    }

    // MARK: mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        if isEditingText {
            // click outside the text box commits
            if let tv = textView, tv.frame.insetBy(dx: -4, dy: -4).contains(p) { return }
            // commit first: its final `update(coalesce:)` still belongs to the
            // text-editing gesture, not to the click that ends it.
            endTextEditing(commit: true)
        }
        // A new gesture starts here: nothing it coalesces may merge into the
        // undo entry of the previous drag.
        document.beginCoalescedGroup()

        // crop mode
        if tool == .crop {
            if let c = cropRect {
                if let h = RectGeometry.handle(at: p, in: c, radius: handleRadius * 1.6) { drag = .cropHandle(h, original: c); return }
                if c.contains(p) { drag = .cropMoving(original: c, start: p); return }
            }
            drag = .cropDrawing(start: p)
            cropRect = CGRect(origin: p, size: .zero)
            return
        }

        // handles of the selection win
        if let sel = selectedAnnotation, let h = HitTesting.handle(at: p, for: sel, radius: handleRadius * 1.6) {
            drag = .handle(h, original: sel)
            return
        }

        // double-click on a text label edits it
        if event.clickCount == 2, let hit = HitTesting.topmost(in: document.annotations, at: p, tolerance: hitTolerance), hit.kind == .text {
            selectedID = hit.id
            beginTextEditing(for: hit.id)
            return
        }

        // any tool: clicking an existing object selects it (Shottr behaviour)
        if let hit = HitTesting.topmost(in: document.annotations, at: p, tolerance: hitTolerance) {
            selectedID = hit.id
            drag = .moving(original: hit, start: p, moved: false)
            updateCursor(at: p)
            return
        }

        selectedID = nil
        guard let kind = tool.annotationKind else { drag = .none; return }
        var a = Annotation(kind: kind, style: style)
        switch kind {
        case .arrow, .line:
            a.start = p; a.end = p
        case .rectangle, .oval, .blur:
            a.start = p
            a.rect = CGRect(origin: p, size: .zero)
        case .freehand, .highlighter:
            a.points = [p]
        case .counter:
            a.start = p
            a.number = document.nextCounterNumber
            document.add(a)
            selectedID = a.id
            delegate?.canvasDidPlaceAnnotation(self, tool: tool)
            drag = .none
            return
        case .text:
            a.rect = CGRect(origin: p, size: .zero)
            a.rect = AnnotationRenderer.measureTextRect(for: a)
            // bubble is placed so the click is at its top-left; pointer tip defaults below-left
            a.pointerTip = a.textPointer ? AnnotationRenderer.defaultPointerTip(forBubble: a.rect) : nil
            pendingText = a
            beginTextEditing(for: a.id)
            drag = .none
            return
        }
        drag = .drawing(a)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none: break
        case .drawing(var a):
            switch a.kind {
            case .arrow, .line: a.end = shift ? RectGeometry.snapped45(from: a.start, to: p) : p
            case .rectangle, .oval, .blur: a.rect = RectGeometry.rect(from: a.start, to: p, square: shift)
            case .freehand, .highlighter:
                if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { break }
                a.points.append(p)
            default: break
            }
            drag = .drawing(a)
            needsDisplay = true
        case .moving(let original, let start, _):
            var a = original
            a.translate(dx: p.x - start.x, dy: p.y - start.y)
            document.update(a, coalesce: true)
            drag = .moving(original: original, start: start, moved: true)
        case .handle(let h, let original):
            let a = HitTesting.drag(handle: h, original: original, to: p, shift: shift)
            document.update(a, coalesce: true)
        case .cropDrawing(let start):
            cropRect = RectGeometry.rect(from: start, to: p, square: shift).intersection(document.bounds)
        case .cropMoving(let original, let start):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = max(0, min(r.origin.x, document.size.width - r.width))
            r.origin.y = max(0, min(r.origin.y, document.size.height - r.height))
            cropRect = r
        case .cropHandle(let h, let original):
            cropRect = RectGeometry.resize(original, handle: h, to: p, shift: shift, minSize: 4).intersection(document.bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .drawing(let a):
            if !a.isDegenerate {
                document.add(a)
                selectedID = a.id
                delegate?.canvasDidPlaceAnnotation(self, tool: tool)
            }
        case .moving(_, _, let moved):
            if !moved, selectedAnnotation?.kind == .text, event.clickCount == 1 { /* single click just selects */ }
        case .cropDrawing:
            if let c = cropRect, c.width < 4 || c.height < 4 { cropRect = document.bounds }
            delegate?.canvasCropStateDidChange(self)
        case .cropMoving, .cropHandle:
            delegate?.canvasCropStateDidChange(self)
        default: break
        }
        drag = .none
        // Close the gesture so a following run of arrow-key nudges becomes its
        // own undo step instead of merging into the drag that just ended.
        document.beginCoalescedGroup()
        needsDisplay = true
        updateCursor(at: imagePoint(event))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = imagePoint(event)
        // As first responder we also get moves outside our bounds; those belong
        // to the chrome (toolbars set their own cursor).
        guard bounds.contains(p) else {
            if hoveredID != nil { hoveredID = nil }
            return
        }
        if case .none = drag {
            hoveredID = tool == .crop ? nil : HitTesting.topmost(in: document.annotations, at: p, tolerance: hitTolerance)?.id
        }
        updateCursor(at: p)
    }

    override func mouseExited(with event: NSEvent) { hoveredID = nil; NSCursor.arrow.set() }

    /// AppKit's own cursor updates (entering the view, the window turning
    /// key) would otherwise put the arrow back over the canvas cursor.
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: imagePoint(event)) }

    /// True when a click at `p` would reach the canvas. In the overlay the
    /// selection handles sit on top and set the cursor where they take the
    /// click; two views setting it on every move made it flicker.
    private func ownsPointer(at p: CGPoint) -> Bool {
        guard let root = window?.contentView else { return true }
        let inWindow = convert(p, to: nil)
        let hit = root.hitTest(root.superview?.convert(inWindow, from: nil) ?? inWindow)
        return hit.map { $0 === self || $0.isDescendant(of: self) } ?? false
    }

    private func updateCursor(at p: CGPoint) {
        if isEditingText || !ownsPointer(at: p) { return }
        if tool == .crop, let c = cropRect {
            if let h = RectGeometry.handle(at: p, in: c, radius: handleRadius * 1.6) { RectGeometry.cursor(for: h).set() }
            else if c.contains(p) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
            return
        }
        if let sel = selectedAnnotation, HitTesting.handle(at: p, for: sel, radius: handleRadius * 1.6) != nil { NSCursor.crosshair.set(); return }
        // The selected object drags (hand); any other object is picked by a click first (arrow).
        if let id = hoveredID { (id == selectedID ? NSCursor.openHand : NSCursor.arrow).set(); return }
        ToolCursors.cursor(for: tool, style: style, scale: viewScale).set()
    }


    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch key {
        case 51, 117: // delete, forward delete
            if selectedID != nil, !isEditingText { deleteSelection(); return }
        case 53: // esc
            if isEditingText { endTextEditing(commit: true); return }
            if tool == .crop { cancelCrop(); return }
            if selectedID != nil { selectedID = nil; return }
        case 36, 76: // return
            if tool == .crop { applyCrop(); return }
        case 123, 124, 125, 126: // arrows
            if selectedID != nil, !isEditingText {
                let step: CGFloat = mods.contains(.shift) ? 10 : 1
                let dx: CGFloat = key == 123 ? -step : key == 124 ? step : 0
                let dy: CGFloat = key == 126 ? -step : key == 125 ? step : 0
                nudgeSelection(dx: dx, dy: dy)
                return
            }
        default: break
        }
        if delegate?.canvas(self, didReceiveUnhandledKey: event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: text editing

    func beginTextEditing(for id: UUID) {
        endTextEditing(commit: true)
        guard let a = pendingText?.id == id ? pendingText : document.annotation(id: id), a.kind == .text else { return }
        editingID = id
        if pendingText?.id != id { textOriginal = a; selectedID = id }
        let tv = NSTextView(frame: .zero)
        tv.delegate = self
        tv.isRichText = false
        tv.isFieldEditor = false
        tv.allowsUndo = true
        tv.drawsBackground = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 4000, height: 4000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.string = a.text
        addSubview(tv)
        textView = tv
        styleTextView()
        layoutTextView()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
        delegate?.canvasSelectionDidChange(self)
    }

    private var editingAnnotation: Annotation? {
        guard let id = editingID else { return nil }
        return pendingText?.id == id ? pendingText : document.annotation(id: id)
    }

    private func styleTextView() {
        guard let tv = textView, let a = editingAnnotation else { return }
        tv.font = AnnotationRenderer.textFont(for: a)
        switch a.textStyle {
        case .label:
            tv.textColor = .white
            tv.backgroundColor = a.color.nsColor
            tv.insertionPointColor = .white
        case .plain:
            tv.textColor = a.color.nsColor
            tv.backgroundColor = NSColor.black.withAlphaComponent(0.001)
            tv.insertionPointColor = a.color.nsColor
        }
    }

    private func layoutTextView() {
        guard let tv = textView, let a = editingAnnotation else { return }
        // renderer pads the bubble h8 v4 around the text
        let inset = a.textStyle == .label ? CGSize(width: 8, height: 4) : CGSize(width: 0, height: 0)
        let r = a.rect
        tv.frame = CGRect(x: r.minX + inset.width, y: r.minY + inset.height,
                          width: max(8, r.width - inset.width * 2), height: max(8, r.height - inset.height * 2))
        tv.textContainer?.containerSize = CGSize(width: max(8, r.width - inset.width * 2 + 1), height: 4000)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, var a = editingAnnotation else { return }
        a.text = tv.string
        a.rect = AnnotationRenderer.measureTextRect(for: a)
        if pendingText?.id == a.id { pendingText = a } else { document.update(a, coalesce: true) }
        layoutTextView()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endTextEditing(commit: true); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true { endTextEditing(commit: true); return true }
        return false
    }

    /// Ends inline editing. Empty text removes the label.
    func endTextEditing(commit: Bool) {
        guard let tv = textView, let id = editingID else { return }
        let text = tv.string
        // `removeFromSuperview` resigns first responder to the window, so the
        // check has to happen before it - otherwise the canvas silently loses
        // the keyboard and tool letters / Esc stop working after every edit.
        let hadFocus = window?.firstResponder === tv
        tv.removeFromSuperview()
        textView = nil
        editingID = nil
        if hadFocus { window?.makeFirstResponder(self) }
        defer { needsDisplay = true; textOriginal = nil; pendingText = nil; delegate?.canvasSelectionDidChange(self) }

        if var p = pendingText, p.id == id {
            guard commit else { return }
            p.text = text
            p.rect = AnnotationRenderer.measureTextRect(for: p)
            if !p.isDegenerate {
                document.add(p)
                selectedID = p.id
                delegate?.canvasDidPlaceAnnotation(self, tool: .text)
            }
            return
        }
        guard var a = document.annotation(id: id), let original = textOriginal else { return }
        if !commit { document.update(original); return }
        a.text = text
        a.rect = AnnotationRenderer.measureTextRect(for: a)
        if a.isDegenerate {
            document.update(original, coalesce: true)
            document.remove(id: id)
            selectedID = nil
        } else {
            // merges into the coalesced live-edit entry: one undo step from `original` to `a`
            document.update(a, coalesce: true)
        }
    }
}


/// Per-tool mouse cursors: arrow for select, a brush-size ring for freehand,
/// an I-beam over a highlight mark for the highlighter, I-beam for text,
/// crosshair for shapes.
@MainActor
enum ToolCursors {
    private static var cache: [EditorTool: NSCursor] = [:]
    private static var rings: [Int: NSCursor] = [:]
    private static var highlightBeams: [HighlightBeamKey: NSCursor] = [:]
    private struct HighlightBeamKey: Hashable { let color: AnnotationColor; let height: Int }

    /// `scale` is the host magnification, so the freehand ring matches the
    /// stroke as it will appear on screen.
    static func cursor(for tool: EditorTool, style: ToolStyle, scale: CGFloat) -> NSCursor {
        switch tool {
        case .select: return .arrow
        case .text: return .iBeam
        case .freehand: return ring(diameter: style.thickness * scale)
        case .highlighter: return highlightBeam(color: style.highlighterColor, height: style.highlighterThickness * scale)
        case .counter: return symbolCursor(tool, "1.circle", hotSpot: CGPoint(x: 11, y: 11))
        default: return .crosshair
        }
    }

    /// Photoshop-style brush outline: a ring as wide as the stroke with a
    /// centre dot (a thin stroke's ring alone is hard to see), black with a
    /// white halo so it reads on any content.
    private static func ring(diameter: CGFloat) -> NSCursor {
        let d = Int(min(max(diameter, 5), 128).rounded())
        if let c = rings[d] { return c }
        let side = CGFloat(d) + 4
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: CGFloat(d), height: CGFloat(d)))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = 3
            circle.stroke()
            NSColor.black.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            let c = side / 2
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: CGRect(x: c - 1.75, y: c - 1.75, width: 3.5, height: 3.5)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: c - 0.9, y: c - 0.9, width: 1.8, height: 1.8)).fill()
            return true
        }
        let c = NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
        rings[d] = c
        return c
    }

    /// A text I-beam over a block of the highlighter colour as tall as the
    /// stroke (on screen), so the pointer shows how thick the mark will be.
    private static func highlightBeam(color: AnnotationColor, height: CGFloat) -> NSCursor {
        // Thin settings keep a readable minimum.
        let h = Int(min(max(height, 8), 128).rounded())
        let key = HighlightBeamKey(color: color, height: h)
        if let c = highlightBeams[key] { return c }
        let size = CGSize(width: 12, height: CGFloat(h) + 6)
        let image = NSImage(size: size, flipped: true) { _ in
            color.withAlpha(0.6).nsColor.setFill()
            CGRect(x: 2, y: 3, width: 8, height: CGFloat(h)).fill()
            let top: CGFloat = 1.5, bottom = size.height - 1.5
            let beam = NSBezierPath()
            beam.move(to: CGPoint(x: 3, y: top)); beam.line(to: CGPoint(x: 9, y: top))
            beam.move(to: CGPoint(x: 6, y: top)); beam.line(to: CGPoint(x: 6, y: bottom))
            beam.move(to: CGPoint(x: 3, y: bottom)); beam.line(to: CGPoint(x: 9, y: bottom))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            beam.lineWidth = 3
            beam.stroke()
            NSColor.black.setStroke()
            beam.lineWidth = 1
            beam.stroke()
            return true
        }
        let c = NSCursor(image: image, hotSpot: CGPoint(x: 6, y: size.height / 2))
        highlightBeams[key] = c
        return c
    }

    private static func symbolCursor(_ tool: EditorTool, _ name: String, hotSpot: CGPoint) -> NSCursor {
        if let c = cache[tool] { return c }
        let size = CGSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .medium)) else { return false }
            // white halo so the cursor reads on dark and light content
            let halo = symbol.copy() as! NSImage
            halo.isTemplate = true
            NSColor.white.set()
            for d in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)] {
                halo.draw(in: rect.offsetBy(dx: d.x, dy: d.y), from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSColor.black.set()
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        let c = NSCursor(image: image, hotSpot: hotSpot)
        cache[tool] = c
        return c
    }
}
