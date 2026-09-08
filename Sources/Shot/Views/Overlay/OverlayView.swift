import AppKit
import SwiftUI
import BenchCore

/// The content view of one `OverlayPanel`: the frozen display bitmap, the dim,
/// the crosshair, the rubber-band selection with its 8 handles, and - once a
/// selection exists - an `AnnotationCanvasView` sitting exactly on top of it
/// plus the surrounding chrome (size pill, tool strip, options row, action
/// strip).
///
/// Coordinates: the view is **flipped** (origin top-left, y down) and 1pt =
/// 1 point of the display, so `bounds` == the screen in view coordinates and
/// the canvas frame == the selection rect.
final class OverlayView: NSView, AnnotationCanvasDelegate {

    enum State { case idle, selecting, selected }
    /// A normal capture overlay, the region picker used by scrolling capture,
    /// or the text grab, which crops on mouse-up and never shows chrome.
    enum Purpose { case capture, region, text }

    let frozen: FrozenScreen
    private(set) weak var controller: OverlayController?

    private(set) var purpose: Purpose = .capture
    private(set) var mode: OverlayController.Mode = .area
    /// File format the shortcut that started this capture saves as; stamped
    /// onto every document this overlay produces.
    private(set) var outputFormat: CaptureFileFormat = .png
    /// On-screen windows (global AppKit frames), front to back.
    var windows: [WindowInfo] = []
    /// Notch / safe-area bands this display's chrome must avoid (view coords).
    private var obstructions: [CGRect] = []

    private(set) var state: State = .idle
    /// The selection in view coordinates, `nil` while nothing is picked.
    private(set) var selection: CGRect?
    private(set) var document: AnnotationDocument?
    private(set) var captureResult: CaptureResult?
    /// The view rect the current `document.image` was cropped from. It only
    /// tracks `selection` between re-crops, so it is what a moved or resized
    /// selection has to be measured against.
    private var documentRect: CGRect?

    // MARK: chrome
    private let sizeLabel = OverlaySizeLabel()
    private let toolStrip = OverlayToolStrip()
    private let actionStrip = OverlayActionStrip()
    private let regionStrip = OverlayRegionStrip()
    private let propertiesModel = PropertiesPanelModel()
    private var properties: PropertiesPanelHost?

    private var canvas: AnnotationCanvasView?
    private var handles: SelectionHandlesView?

    // MARK: drag state
    private enum Drag {
        case none
        case rubberBand(origin: CGPoint)
        case move(original: CGRect, start: CGPoint)
        case resize(HandleKind, original: CGRect, start: CGPoint)
    }
    private var drag: Drag = .none
    private var hoveredWindow: WindowInfo?
    private var trackingArea: NSTrackingArea?
    /// Selection rect per undo depth, so undoing a re-crop restores the frame.
    private var selectionHistory: [Int: CGRect] = [:]
    private var relayoutScheduled = false

    private static let minSelection: CGFloat = 8
    private static let handleRadius: CGFloat = 5      // 10pt diameter, like the reference

    // MARK: - init

    init(frozen: FrozenScreen, controller: OverlayController) {
        self.frozen = frozen
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: frozen.screenFrame.size))
        wantsLayer = true
        for view in [sizeLabel, toolStrip, actionStrip, regionStrip] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        sizeLabel.onToggleUnits = { [weak self] in
            SettingsManager.shared.dimensionsInPixels.toggle()
            self?.updateSizeLabel()
            self?.layoutChrome()
        }
        toolStrip.onSelect = { [weak self] in self?.setTool($0) }
        toolStrip.onUndo = { [weak self] in self?.canvas?.undo() }
        toolStrip.onRedo = { [weak self] in self?.canvas?.redo() }
        actionStrip.onMoveDrag = { [weak self] phase, event in
            guard let self else { return }
            switch phase {
            case 0:
                guard let sel = self.selection, self.selectionIsEditable else { return }
                self.drag = .move(original: sel, start: self.convert(event.locationInWindow, from: nil))
                self.beginGeometryDrag()
            case 1: self.mouseDragged(with: event)
            default: self.mouseUp(with: event)
            }
        }
        actionStrip.onAction = { [weak self] action in
            guard let self else { return }
            self.controller?.perform(action, from: self)
        }
        regionStrip.onCancel = { [weak self] in self?.escapePressed() }
        regionStrip.onStart = { [weak self] in self?.confirmRegion() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Called by the controller right after the panel is created.
    func prepare(mode: OverlayController.Mode,
                 purpose: Purpose,
                 windows: [WindowInfo],
                 screen: NSScreen?,
                 outputFormat: CaptureFileFormat = .png) {
        self.mode = mode
        self.purpose = purpose
        self.windows = windows
        self.outputFormat = outputFormat
        obstructions = Self.topObstructions(for: screen, height: bounds.height, width: bounds.width)
        let accent = Self.accentColor
        toolStrip.accent = accent
        actionStrip.accent = accent
        updateChromeVisibility()
        needsDisplay = true
    }

    /// The notch / safe-area band at the top of `screen`, in view coordinates.
    private static func topObstructions(for screen: NSScreen?, height: CGFloat, width: CGFloat) -> [CGRect] {
        guard let screen else { return [] }
        var band = screen.safeAreaInsets.top
        if let left = screen.auxiliaryTopLeftArea { band = max(band, left.height) }
        if let right = screen.auxiliaryTopRightArea { band = max(band, right.height) }
        guard band > 0 else { return [] }
        return [CGRect(x: 0, y: 0, width: width, height: band)]
    }

    static var accentColor: NSColor { Theme.accentNSColor }

    // MARK: - geometry helpers

    /// View rect -> AppKit rect local to this display (origin bottom-left).
    func localAppKitRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// View rect -> global AppKit rect.
    func globalRect(_ rect: CGRect) -> CGRect {
        let local = localAppKitRect(rect)
        return CGRect(x: frozen.screenFrame.minX + local.minX,
                      y: frozen.screenFrame.minY + local.minY,
                      width: local.width, height: local.height)
    }

    /// Global AppKit rect -> view rect.
    func viewRect(fromGlobal rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - frozen.screenFrame.minX,
               y: frozen.screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private func globalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frozen.screenFrame.minX + point.x, y: frozen.screenFrame.maxY - point.y)
    }

    /// The selection in global AppKit coordinates (what `onPin` wants).
    var globalSelectionRect: CGRect { selection.map { globalRect($0) } ?? frozen.screenFrame }

    private func clampToScreen(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        r.size.width = min(max(r.width, Self.minSelection), bounds.width)
        r.size.height = min(max(r.height, Self.minSelection), bounds.height)
        r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
        r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
        return r
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // frozen desktop
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .default
        ctx.draw(frozen.image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()

        // dim everything but the selection
        let hole = undimmedRect
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        if let hole {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(hole)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        let accent = Self.accentColor

        // window highlight while idle
        if state == .idle, let info = hoveredWindow {
            let r = viewRect(fromGlobal: info.frame).intersection(bounds)
            if !r.isNull, r.width > 1, r.height > 1 {
                ctx.saveGState()
                if mode == .window {
                    ctx.setFillColor(accent.withAlphaComponent(0.25).cgColor)
                    ctx.fill(r)
                }
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(r.insetBy(dx: 1, dy: 1))
                ctx.restoreGState()
            }
        }

        // selection border (the handles are drawn by SelectionHandlesView, above the canvas)
        if let sel = selection {
            ctx.saveGState()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))
            ctx.restoreGState()
            // While the frame is changing the canvas is hidden: draw the
            // annotations at the place on the frozen desktop they were drawn
            // on, which is where `recropDocument` leaves them on mouse-up.
            if let doc = document, canvas?.isHidden == true, !doc.annotations.isEmpty {
                let origin = (documentRect ?? sel).origin
                ctx.saveGState()
                ctx.clip(to: sel)
                ctx.translateBy(x: origin.x, y: origin.y)
                AnnotationRenderer.draw(doc.annotations, sourceImage: doc.image, pixelScale: doc.pixelScale, in: ctx)
                ctx.restoreGState()
            }
        }
    }

    /// The rect that shows the frozen desktop at full brightness. `nil` dims
    /// everything. Window captures keep the dim so the transparent shadow
    /// margin blends with the desktop behind it.
    private var undimmedRect: CGRect? {
        guard let sel = selection else { return nil }
        if state == .selected, mode == .window { return nil }
        return sel
    }

    // MARK: - state transitions

    /// Clears any selection on this screen (another display took over).
    func resetToIdle() {
        drag = .none
        selection = nil
        detachCanvas()
        state = .idle
        updateChromeVisibility()
        needsDisplay = true
    }

    private func setSelection(_ rect: CGRect, state newState: State) {
        selection = clampToScreen(rect)
        state = newState
        if newState == .selected, handles == nil { addHandles() }
        handles?.selection = selection ?? .zero
        handles?.syncFrame()
        updateSizeLabel()
        updateChromeVisibility()
        layoutChrome()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Stamps the app the pixels came from onto `result`.
    ///
    /// A whole-screen capture is credited to whoever was frontmost before the
    /// overlay appeared (by then it is us); anything rubber-banded is credited
    /// to the front-most window it overlaps the most. `windows` is empty for
    /// the region and text pickers, so those credit nothing.
    private func creditSourceApp(_ result: inout CaptureResult, globalRect: CGRect) {
        switch result.source {
        case .screen:
            result.sourceAppName = controller?.preOverlayApp?.name
            result.sourceBundleID = controller?.preOverlayApp?.bundleID
        case .area:
            let source = WindowEnumerator.source(for: globalRect, in: windows)
            result.sourceAppName = source?.name
            result.sourceBundleID = source?.bundleID
        case .window, .scrolling, .file:
            // Those already know exactly which app they came from.
            break
        }
    }

    /// Crops the frozen bitmap to `rect` and enters the selected state.
    private func commitSelection(_ rect: CGRect) {
        let source: CaptureSource = mode == .screen ? .screen : .area
        guard var result = ScreenCapturer.crop(frozen, localRect: localAppKitRect(rect), source: source),
              let global = result.screenRect else {
            resetToIdle()
            return
        }
        creditSourceApp(&result, globalRect: global)
        captureResult = result
        // No sound here: the shutter plays when the capture actually lands
        // somewhere - copied to the clipboard, or written to a file.
        let doc = AnnotationDocument(image: result.image,
                                     pixelScale: result.pixelScale,
                                     outputFormat: outputFormat,
                                     sourceAppName: result.sourceAppName,
                                     sourceBundleID: result.sourceBundleID)
        document = doc
        selectionHistory = [0: viewRect(fromGlobal: global)]
        documentRect = viewRect(fromGlobal: global)
        setSelection(viewRect(fromGlobal: global), state: .selected)
        attachCanvas()
        controller?.overlayViewDidSelect(self)
    }

    /// Window mode: shows the captured window (already includes its shadow
    /// margin when the setting is on) as the selection.
    func showWindowCapture(_ result: CaptureResult) {
        guard let global = result.screenRect else { return }
        captureResult = result
        // No sound here: the shutter plays when the capture actually lands
        // somewhere - copied to the clipboard, or written to a file.
        let doc = AnnotationDocument(image: result.image,
                                     pixelScale: result.pixelScale,
                                     outputFormat: outputFormat,
                                     sourceAppName: result.sourceAppName,
                                     sourceBundleID: result.sourceBundleID)
        document = doc
        let rect = viewRect(fromGlobal: global)
        selectionHistory = [0: rect]
        documentRect = rect
        setSelection(rect, state: .selected)
        attachCanvas()
        controller?.overlayViewDidSelect(self)
    }

    /// Screen mode: the whole display, no handles and no moving.
    func selectWholeScreen() {
        commitSelection(bounds)
    }

    // MARK: - canvas

    /// Area selections can be moved and resized; window/screen captures cannot.
    private var selectionIsEditable: Bool {
        purpose == .region || (purpose == .capture && mode == .area)
    }

    private func attachCanvas() {
        guard purpose == .capture, let doc = document, let sel = selection else { return }
        removeCanvasViews()
        let view = AnnotationCanvasView(document: doc)
        view.frame = sel
        view.delegate = self
        view.style = SettingsManager.shared.toolStyle
        view.accentColor = Self.accentColor
        // the overlay has no crop tool: the selection itself is the crop
        let remembered = SettingsManager.shared.rememberLastTool ? SettingsManager.shared.lastTool : .select
        view.tool = remembered == .crop ? .select : remembered
        addSubview(view)
        canvas = view

        let host = PropertiesPanelHost(model: propertiesModel)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.isHidden = true
        addSubview(host.view)
        properties = host
        propertiesModel.canvas = view
        propertiesModel.onStyleChanged = { style in SettingsManager.shared.toolStyle = style }

        addHandles()
        toolStrip.tool = view.tool
        toolStrip.setHistory(canUndo: doc.canUndo, canRedo: doc.canRedo)
        refreshProperties()
        window?.makeFirstResponder(view)
        // chrome must stay above the canvas
        for chrome in [sizeLabel, toolStrip, actionStrip, regionStrip, host.view] as [NSView] {
            chrome.removeFromSuperview()
            addSubview(chrome)
        }
        layoutChrome()
    }

    private func addHandles() {
        handles?.removeFromSuperview()
        let h = SelectionHandlesView(owner: self)
        h.accent = Self.accentColor
        h.showsHandles = selectionIsEditable
        h.interactive = selectionIsEditable
        h.selection = selection ?? .zero
        addSubview(h)
        h.syncFrame()
        handles = h
    }

    /// Tears down the canvas views only - the document survives.
    private func removeCanvasViews() {
        canvas?.removeFromSuperview()
        canvas = nil
        properties?.view.removeFromSuperview()
        properties = nil
        propertiesModel.canvas = nil
        handles?.removeFromSuperview()
        handles = nil
    }

    /// Throws the capture away as well (restarting the selection, teardown).
    private func detachCanvas() {
        removeCanvasViews()
        document = nil
        captureResult = nil
        documentRect = nil
        selectionHistory = [:]
    }

    private func setTool(_ tool: EditorTool) {
        guard let canvas else { return }
        canvas.tool = tool
        toolStrip.tool = tool
        SettingsManager.shared.lastTool = tool
        refreshProperties()
        window?.makeFirstResponder(canvas)
    }

    private func refreshProperties() {
        propertiesModel.refresh()
        guard let host = properties else { return }
        host.view.isHidden = !propertiesModel.isVisible
        relayoutSoon()
    }

    /// The SwiftUI capsule resizes a beat after its model changes.
    private func relayoutSoon() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            self.layoutChrome()
        }
    }

    // MARK: - chrome

    private func updateChromeVisibility() {
        let hasSelection = selection != nil
        sizeLabel.isHidden = !hasSelection
        switch purpose {
        case .capture:
            toolStrip.isHidden = state != .selected
            actionStrip.isHidden = state != .selected
            regionStrip.isHidden = true
        case .region:
            toolStrip.isHidden = true
            actionStrip.isHidden = true
            regionStrip.isHidden = !hasSelection
        case .text:
            // Nothing but the size pill: the drag itself is the whole flow.
            toolStrip.isHidden = true
            actionStrip.isHidden = true
            regionStrip.isHidden = true
        }
        if !hasSelection { properties?.view.isHidden = true }
    }

    /// True while the selection frame itself is being dragged or resized.
    private var isGeometryDragging: Bool {
        if case .none = drag { return false }
        return true
    }

    private func updateSizeLabel() {
        // While the frame is moving the document still holds the *old* crop, so
        // the live selection is the only thing that reflects what the user sees.
        if state == .selected, !isGeometryDragging, let doc = document {
            sizeLabel.text = EditorActions.dimensionString(pointSize: doc.size, pixelScale: doc.pixelScale)
        } else if let sel = selection {
            sizeLabel.text = EditorActions.dimensionString(pointSize: sel.size, pixelScale: frozen.pixelScale)
        }
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    private func layoutChrome() {
        guard let sel = selection else { return }
        let labelSize = sizeLabel.isHidden ? .zero : sizeLabel.chromeSize
        let stripView: OverlayChromeView? = purpose == .region ? regionStrip : toolStrip
        let stripSize = (stripView?.isHidden ?? true) ? CGSize.zero : (stripView?.chromeSize ?? .zero)
        var optionsSize = CGSize.zero
        if let host = properties, !host.view.isHidden {
            optionsSize = host.fittingSize
        }
        let actionSize = actionStrip.isHidden ? .zero : actionStrip.chromeSize

        let placement = SelectionLayout.place(screen: bounds,
                                              selection: sel,
                                              label: labelSize,
                                              toolStrip: stripSize,
                                              optionsRow: optionsSize,
                                              actionStrip: actionSize,
                                              obstructions: obstructions)
        if !sizeLabel.isHidden { sizeLabel.frame = placement.label }
        if let stripView, !stripView.isHidden { stripView.frame = placement.toolStrip }
        if let host = properties, !host.view.isHidden { host.view.frame = placement.optionsRow }
        if !actionStrip.isHidden { actionStrip.frame = placement.actionStrip }
        handles?.syncFrame()
    }

    // MARK: - tracking / cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if state == .idle {
            CaptureCursor.crosshair.set()
            updateHoveredWindow(at: p)
        } else if state == .selected {
            NSCursor.arrow.set()
        } else {
            CaptureCursor.crosshair.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredWindow != nil { hoveredWindow = nil; needsDisplay = true }
    }

    private func updateHoveredWindow(at point: CGPoint) {
        guard purpose == .capture, mode == .window else { return }
        let global = globalPoint(point)
        let found = WindowEnumerator.window(at: global, in: windows)
        if found?.id != hoveredWindow?.id {
            hoveredWindow = found
            needsDisplay = true
        }
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        if purpose == .capture, mode == .screen {
            if state != .selected { selectWholeScreen() }
            return
        }
        if purpose == .capture, mode == .window {
            if let info = hoveredWindow ?? WindowEnumerator.window(at: globalPoint(p), in: windows) {
                controller?.captureWindow(info, on: self)
            }
            return
        }
        // an existing selection: handles first, then the body
        if let sel = selection, selectionIsEditable {
            if let handle = RectGeometry.handle(at: p, in: sel, radius: Self.handleRadius * 2) {
                drag = .resize(handle, original: sel, start: p)
                beginGeometryDrag()
                return
            }
            if state != .selected, sel.contains(p) {
                drag = .move(original: sel, start: p)
                beginGeometryDrag()
                return
            }
        }
        // starting over throws the current capture away: never silently lose annotations
        if state == .selected { return }
        controller?.overlayViewDidSelect(self)
        hoveredWindow = nil
        drag = .rubberBand(origin: p)
        detachCanvas()
        setSelection(CGRect(origin: p, size: .zero), state: .selecting)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .rubberBand(let origin):
            let r = RectGeometry.rect(from: origin, to: p, square: shift).intersection(bounds)
            selection = r.isNull ? CGRect(origin: origin, size: .zero) : r
            handles?.selection = selection ?? .zero
            handles?.syncFrame()
            updateSizeLabel()
            layoutChrome()
            needsDisplay = true
        case .move(let original, let start):
            let moved = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            setSelection(moved, state: state)
        case .resize(let handle, let original, _):
            let resized = RectGeometry.resize(original, handle: handle, to: p, shift: shift, minSize: Self.minSelection)
            setSelection(resized.intersection(bounds), state: state)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let previous = drag
        drag = .none
        switch previous {
        case .none:
            return
        case .rubberBand(let origin):
            let p = convert(event.locationInWindow, from: nil)
            let dragged = hypot(p.x - origin.x, p.y - origin.y) >= 4
            if !dragged {
                // area mode is region-only: a click without a drag selects nothing
                resetToIdle()
                return
            }
            guard let sel = selection, sel.width >= Self.minSelection, sel.height >= Self.minSelection else {
                resetToIdle()
                return
            }
            switch purpose {
            case .region: setSelection(sel, state: .selected)
            case .text: finishText(sel)
            case .capture: commitSelection(sel)
            }
        case .move, .resize:
            endGeometryDrag()
        }
    }

    /// Hides the canvas while the frame is changing; `draw` keeps painting the
    /// annotations at their place on the frozen desktop, clipped by the moving
    /// selection - which is exactly where `recropDocument` leaves them.
    private func beginGeometryDrag() {
        canvas?.isHidden = true
        needsDisplay = true
    }

    private func endGeometryDrag() {
        guard let sel = selection else { return }
        if purpose == .region || document == nil {
            canvas?.isHidden = false
            updateSizeLabel()
            layoutChrome()
            needsDisplay = true
            return
        }
        recropDocument(to: sel)
        canvas?.isHidden = false
        window?.makeFirstResponder(canvas)
    }

    /// Re-crops the frozen bitmap after the selection moved or resized and
    /// translates the annotations by the same delta so they stay on the pixels
    /// they were drawn on. Same document object throughout.
    private func recropDocument(to newSelection: CGRect, coalesce: Bool = false) {
        // `selection` already holds the *new* frame by the time a drag ends, so
        // the delta has to be measured against the rect the current bitmap was
        // cropped from - otherwise it is always zero and the annotations drift
        // off the pixels they were drawn on.
        guard let doc = document, let old = documentRect ?? selection else { return }
        let source = captureResult?.source ?? .area
        guard var result = ScreenCapturer.crop(frozen, localRect: localAppKitRect(newSelection), source: source),
              let global = result.screenRect else { return }
        // The selection may have been dragged onto a different app's window.
        creditSourceApp(&result, globalRect: global)
        doc.sourceAppName = result.sourceAppName
        doc.sourceBundleID = result.sourceBundleID
        let snapped = viewRect(fromGlobal: global)
        var moved = doc.annotations
        let dx = old.minX - snapped.minX
        let dy = old.minY - snapped.minY
        if dx != 0 || dy != 0 {
            for i in moved.indices { moved[i].translate(dx: dx, dy: dy) }
        }
        captureResult = result
        selection = snapped
        documentRect = snapped
        canvas?.frame = snapped
        doc.replaceImage(result.image, annotations: moved, coalesce: coalesce)
        selectionHistory[doc.undoStack.count] = snapped
        setSelection(snapped, state: .selected)
    }

    // MARK: - keyboard

    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { escapePressed() }

    /// Returns true when the overlay consumed the key. Also the sink for keys
    /// the canvas did not use (`AnnotationCanvasDelegate`).
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // esc
            escapePressed()
            return true
        case 36, 76: // return / enter
            returnPressed()
            return true
        case 123, 124, 125, 126: // arrows nudge the selection
            guard selectionIsEditable, let sel = selection, canvas?.selectedAnnotation == nil else { return false }
            let step: CGFloat = mods.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            let moved = sel.offsetBy(dx: dx, dy: dy)
            if state == .selected, document != nil {
                // A run of key repeats is one gesture: one undo step, one
                // retained bitmap pair, not one per keystroke.
                recropDocument(to: clampToScreen(moved), coalesce: true)
            } else {
                setSelection(moved, state: state)
            }
            return true
        default: break
        }
        guard mods.isEmpty || mods == .shift, state == .selected, purpose == .capture else { return false }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return false }
        if let tool = EditorTool.tool(forKey: characters), tool != .crop {
            setTool(tool)
            return true
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = mods.contains(.shift)
        // The inline text editor keeps the standard editing shortcuts. There is
        // no main menu to route them, and NSTextView has no key equivalents of
        // its own, so they have to be sent down the responder chain by hand.
        if canvas?.isEditingText == true {
            switch key {
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "a" where !shift: return NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
            case "z":
                if shift { window?.undoManager?.redo() } else { window?.undoManager?.undo() }
                return true
            default: break
            }
        }
        guard state == .selected, purpose == .capture, document != nil else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c" where !shift: controller?.perform(.copy, from: self); return true
        case "s": controller?.perform(shift ? .saveAs : .save, from: self); return true
        case "e" where !shift: controller?.perform(.editor, from: self); return true
        case "z":
            if shift { canvas?.redo() } else { canvas?.undo() }
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    func escapePressed() {
        guard let controller else { return }
        if purpose == .region {
            controller.finishRegion(nil)
            return
        }
        if purpose == .text {
            controller.finishText(nil)
            return
        }
        switch state {
        case .idle, .selecting:
            controller.cancel()
        case .selected:
            guard let doc = document else { controller.cancel(); return }
            if documentIsDirty {
                EditorActions.confirmDiscard(for: window) { discard in
                    if discard { controller.cancel() }
                }
            } else {
                if SettingsManager.shared.copyOnClose { EditorActions.copy(doc) }
                controller.cancel()
            }
        }
    }

    private func returnPressed() {
        guard let controller else { return }
        if purpose == .region {
            confirmRegion()
            return
        }
        if purpose == .text {
            guard let sel = selection else { return }
            finishText(sel)
            return
        }
        guard state == .selected, let doc = document else { return }
        canvas?.endTextEditing(commit: true)
        EditorActions.performDefault(doc)
        controller.cancel()
    }

    private func confirmRegion() {
        guard let sel = selection, sel.width >= Self.minSelection, sel.height >= Self.minSelection else { return }
        controller?.finishRegion(globalRect(sel))
    }

    /// Text mode: crop straight out of the frozen bitmap and hand the pixels
    /// to the controller. Nothing is ever written to disk or the clipboard as
    /// an image; only the recognized text leaves this flow.
    private func finishText(_ rect: CGRect) {
        guard let controller else { return }
        guard rect.width >= Self.minSelection, rect.height >= Self.minSelection,
              let result = ScreenCapturer.crop(frozen, localRect: localAppKitRect(rect), source: .area) else {
            controller.finishText(nil)
            return
        }
        controller.finishText(result.image)
    }

    /// Annotations (or an undone annotation) make the document dirty. A moved
    /// or resized selection re-crops the bitmap but is not an edit.
    private var documentIsDirty: Bool {
        guard let doc = document else { return false }
        return !doc.annotations.isEmpty || doc.canRedo
    }

    // MARK: - AnnotationCanvasDelegate

    func canvasSelectionDidChange(_ canvas: AnnotationCanvasView) {
        refreshProperties()
    }

    func canvasDocumentDidChange(_ canvas: AnnotationCanvasView) {
        toolStrip.setHistory(canUndo: canvas.document.canUndo, canRedo: canvas.document.canRedo)
        syncSelectionWithDocument()
        updateSizeLabel()
        layoutChrome()
        refreshProperties()
        needsDisplay = true
    }

    /// Undoing a re-crop changes the document's size behind our back; restore
    /// the selection rect that produced that image.
    private func syncSelectionWithDocument() {
        guard let doc = document, let sel = selection else { return }
        let size = doc.size
        guard abs(size.width - sel.width) > 0.5 || abs(size.height - sel.height) > 0.5 else { return }
        let restored = selectionHistory[doc.undoStack.count] ?? CGRect(origin: sel.origin, size: size)
        selection = clampToScreen(restored)
        documentRect = selection
        canvas?.frame = selection ?? restored
        handles?.selection = selection ?? restored
        handles?.syncFrame()
    }

    func canvasDidPlaceAnnotation(_ canvas: AnnotationCanvasView, tool: EditorTool) {
        SettingsManager.shared.lastTool = tool
        SettingsManager.shared.toolStyle = canvas.style
        if !SettingsManager.shared.keepToolActive {
            canvas.tool = .select
        }
        toolStrip.tool = canvas.tool
        refreshProperties()
    }

    func canvasCropStateDidChange(_ canvas: AnnotationCanvasView) {
        // the overlay has no crop tool: the selection is the crop
    }

    func canvas(_ canvas: AnnotationCanvasView, didReceiveUnhandledKey event: NSEvent) -> Bool {
        handleKey(event)
    }

    // MARK: - teardown

    func teardown() {
        drag = .none
        detachCanvas()
        for view in subviews { view.removeFromSuperview() }
        selection = nil
        hoveredWindow = nil
        windows = []
        if let trackingArea { removeTrackingArea(trackingArea); self.trackingArea = nil }
    }
}

// MARK: - Handles

/// Draws the 8 round selection handles above the canvas and owns the drags
/// that start on them (and on the selection body when the select tool is
/// active), which the canvas underneath must not swallow.
final class SelectionHandlesView: NSView {

    private weak var owner: OverlayView?
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var showsHandles = true { didSet { needsDisplay = true } }
    var interactive = true
    var selection: CGRect = .zero { didSet { needsDisplay = true } }

    private static let radius: CGFloat = 5
    /// Slop around a handle centre that still counts as grabbing it.
    static let hitRadius: CGFloat = 9
    private static let margin: CGFloat = hitRadius

    init(owner: OverlayView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Keeps the view just big enough to paint the handles on the border.
    func syncFrame() {
        frame = selection.insetBy(dx: -Self.margin, dy: -Self.margin)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsHandles, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let local = CGRect(x: Self.margin, y: Self.margin, width: selection.width, height: selection.height)
        ctx.saveGState()
        ctx.setFillColor(accent.cgColor)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1)
        for (_, p) in RectGeometry.handlePositions(for: local) {
            let r = CGRect(x: p.x - Self.radius, y: p.y - Self.radius, width: Self.radius * 2, height: Self.radius * 2)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()
    }

    /// `point` is in the overlay view's coordinates. Claim handle drags always,
    /// and body drags only when the canvas would not use the click itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactive, let owner else { return nil }
        if showsHandles, RectGeometry.handle(at: point, in: selection, radius: Self.margin) != nil { return self }
        if owner.wantsBodyDrag(at: point) { return self }
        return nil
    }

    private func overlayPoint(_ event: NSEvent) -> CGPoint {
        (superview ?? self).convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) { owner?.beginHandleDrag(at: overlayPoint(event)) }
    override func mouseDragged(with event: NSEvent) { owner?.continueHandleDrag(at: overlayPoint(event), shift: event.modifierFlags.contains(.shift)) }
    override func mouseUp(with event: NSEvent) { owner?.endHandleDrag() }

    override func resetCursorRects() {
        guard showsHandles else { return }
        for (kind, p) in RectGeometry.handlePositions(for: CGRect(x: Self.margin, y: Self.margin, width: selection.width, height: selection.height)) {
            let r = CGRect(x: p.x - Self.margin, y: p.y - Self.margin, width: Self.margin * 2, height: Self.margin * 2)
            addCursorRect(r, cursor: RectGeometry.cursor(for: kind))
        }
    }
}

// MARK: - drags forwarded from the handles view

extension OverlayView {

    /// True when a click inside the selection should move it instead of
    /// reaching the canvas (select tool, nothing under the pointer).
    func wantsBodyDrag(at point: CGPoint) -> Bool {
        guard selectionIsEditableForBody, let sel = selection, sel.contains(point) else { return false }
        guard let canvas else { return true }
        if canvas.isEditingText { return false }
        guard canvas.tool == .select else { return false }
        let local = CGPoint(x: point.x - sel.minX, y: point.y - sel.minY)
        return HitTesting.topmost(in: canvas.document.annotations, at: local, tolerance: 6) == nil
    }

    private var selectionIsEditableForBody: Bool {
        purpose == .region || mode == .area
    }

    func beginHandleDrag(at point: CGPoint) {
        guard let sel = selection else { return }
        if let handle = RectGeometry.handle(at: point, in: sel, radius: SelectionHandlesView.hitRadius) {
            drag = .resize(handle, original: sel, start: point)
        } else {
            drag = .move(original: sel, start: point)
        }
        beginGeometryDrag()
    }

    func continueHandleDrag(at point: CGPoint, shift: Bool) {
        switch drag {
        case .move(let original, let start):
            setSelection(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y), state: state)
        case .resize(let handle, let original, _):
            let resized = RectGeometry.resize(original, handle: handle, to: point, shift: shift, minSize: Self.minSelection)
            setSelection(resized.intersection(bounds), state: state)
        default:
            break
        }
    }

    func endHandleDrag() {
        if case .none = drag { return }
        drag = .none
        endGeometryDrag()
    }
}
