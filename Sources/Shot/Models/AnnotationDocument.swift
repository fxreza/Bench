import AppKit

/// One reversible mutation. `image` entries carry full snapshots because crop
/// changes every annotation's geometry at once.
nonisolated enum UndoEntry: Sendable {
    case add(Annotation)
    case remove(Annotation, index: Int)
    case change(before: Annotation, after: Annotation)
    case image(before: CGImage, after: CGImage, annotationsBefore: [Annotation], annotationsAfter: [Annotation])
    case batch([UndoEntry])
}

/// The editable state behind both the overlay and the editor window: the base
/// bitmap, the ordered annotations, and undo/redo. All coordinates are image
/// points with the origin at the top-left (y grows downward) and
/// 1pt = 1 logical pixel. `pixelScale` maps points to bitmap pixels.
@MainActor
final class AnnotationDocument {
    private(set) var image: CGImage
    /// Bitmap pixels per image point (2 on Retina captures, 1 otherwise).
    private(set) var pixelScale: CGFloat
    private(set) var annotations: [Annotation] = []
    private(set) var undoStack: [UndoEntry] = []
    private(set) var redoStack: [UndoEntry] = []
    /// Bumped on every change so views can invalidate caches cheaply.
    private(set) var version: Int = 0
    /// Called after every mutation (add/remove/change/undo/redo/image).
    var onChange: (() -> Void)?
    /// The file format the capture shortcut asked for, carried all the way to
    /// Save / Enter. `nil` for documents that did not come from a shortcut
    /// (a file opened from disk), which keep following the macOS screenshot
    /// `type` preference.
    var outputFormat: CaptureFileFormat?

    /// Identifies the current gesture. `update(coalesce:)` only ever merges into
    /// an entry that was created inside the same group, so two separate drags of
    /// the same annotation stay two undo steps.
    private var coalesceGroup: Int = 0
    /// The group that owns `undoStack.last`, or -1 when nothing is coalescing.
    private var openCoalesceGroup: Int = -1

    init(image: CGImage, pixelScale: CGFloat, outputFormat: CaptureFileFormat? = nil) {
        self.image = image
        self.pixelScale = max(1, pixelScale)
        self.outputFormat = outputFormat
    }

    /// Size in image points.
    var size: CGSize { CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale) }
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// True once anything was changed since creation (drives the Escape confirmation).
    var isDirty: Bool { !undoStack.isEmpty || !redoStack.isEmpty || !annotations.isEmpty }

    func annotation(id: UUID) -> Annotation? { annotations.first { $0.id == id } }
    func index(of id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }

    /// The number a newly placed counter should get.
    var nextCounterNumber: Int { (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1 }

    // MARK: Mutations

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        push(.add(annotation))
    }

    @discardableResult
    func remove(id: UUID) -> Annotation? {
        guard let i = index(of: id) else { return nil }
        let a = annotations.remove(at: i)
        push(.remove(a, index: i))
        return a
    }

    func remove(ids: [UUID]) {
        var entries: [UndoEntry] = []
        // remove from the back so stored indices stay valid when replayed in reverse
        for id in ids.compactMap({ index(of: $0) }).sorted(by: >).map({ annotations[$0].id }) {
            if let i = index(of: id) {
                let a = annotations.remove(at: i)
                entries.append(.remove(a, index: i))
            }
        }
        guard !entries.isEmpty else { return }
        push(.batch(entries))
    }

    /// Opens a new coalescing scope. Hosts call this at every gesture boundary
    /// (mouse down, mouse up) so a coalesced run can never bleed into the
    /// previous gesture's undo entry.
    func beginCoalescedGroup() {
        coalesceGroup &+= 1
    }

    /// Replaces an annotation, recording the change. Pass `coalesce: true`
    /// during a live drag so the whole gesture becomes one undo step: the first
    /// call of the gesture records `before`, later calls only update `after`.
    func update(_ annotation: Annotation, coalesce: Bool = false) {
        guard let i = index(of: annotation.id) else { return }
        let before = annotations[i]
        guard before != annotation else { return }
        annotations[i] = annotation
        if coalesce, openCoalesceGroup == coalesceGroup,
           case .change(let b, let a)? = undoStack.last, a.id == annotation.id, redoStack.isEmpty {
            undoStack[undoStack.count - 1] = .change(before: b, after: annotation)
            bump()
        } else {
            push(.change(before: before, after: annotation))
            openCoalesceGroup = coalesce ? coalesceGroup : -1
        }
    }

    /// Moves an annotation to the end (front-most) or start (back-most).
    func bringToFront(id: UUID) {
        guard let i = index(of: id), i != annotations.count - 1 else { return }
        let a = annotations.remove(at: i)
        annotations.append(a)
        push(.batch([.remove(a, index: i), .add(a)]))
    }

    /// Replaces the bitmap (crop, scroll append, resize) with matching
    /// annotations. `coalesce` folds the change into the previous image entry of
    /// the same gesture, so a held-down arrow key re-cropping the overlay
    /// selection stays one undo step instead of one full snapshot per repeat.
    func replaceImage(_ newImage: CGImage,
                      pixelScale newScale: CGFloat? = nil,
                      annotations newAnnotations: [Annotation],
                      coalesce: Bool = false) {
        let entry = UndoEntry.image(before: image, after: newImage, annotationsBefore: annotations, annotationsAfter: newAnnotations)
        image = newImage
        if let s = newScale { pixelScale = max(1, s) }
        annotations = newAnnotations
        // Blur tiles are cached per source bitmap; the old ones no longer apply.
        AnnotationRenderer.invalidateBlurCache()
        if coalesce, openCoalesceGroup == coalesceGroup, redoStack.isEmpty,
           case .image(let before, _, let annBefore, _)? = undoStack.last {
            undoStack[undoStack.count - 1] = .image(before: before,
                                                    after: newImage,
                                                    annotationsBefore: annBefore,
                                                    annotationsAfter: newAnnotations)
            bump()
        } else {
            push(entry)
            openCoalesceGroup = coalesce ? coalesceGroup : -1
        }
    }

    /// Crops to `rect` (image points, top-left origin); annotations shift with it.
    func crop(to rect: CGRect) {
        let r = rect.standardized.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return }
        let px = CGRect(x: (r.origin.x * pixelScale).rounded(), y: (r.origin.y * pixelScale).rounded(),
                        width: (r.width * pixelScale).rounded(), height: (r.height * pixelScale).rounded())
        guard let cropped = image.cropping(to: px) else { return }
        var moved = annotations
        for i in moved.indices { moved[i].translate(dx: -px.origin.x / pixelScale, dy: -px.origin.y / pixelScale) }
        replaceImage(cropped, annotations: moved)
    }

    // MARK: Undo / redo

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        openCoalesceGroup = -1
        apply(entry, reverse: true)
        redoStack.append(entry)
        bump()
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        openCoalesceGroup = -1
        apply(entry, reverse: false)
        undoStack.append(entry)
        bump()
    }

    private func apply(_ entry: UndoEntry, reverse: Bool) {
        switch entry {
        case .add(let a):
            if reverse { annotations.removeAll { $0.id == a.id } } else { annotations.append(a) }
        case .remove(let a, let index):
            if reverse { annotations.insert(a, at: min(index, annotations.count)) } else { annotations.removeAll { $0.id == a.id } }
        case .change(let before, let after):
            let target = reverse ? before : after
            if let i = index(of: target.id) { annotations[i] = target }
        case .image(let before, let after, let annBefore, let annAfter):
            image = reverse ? before : after
            annotations = reverse ? annBefore : annAfter
            AnnotationRenderer.invalidateBlurCache()
        case .batch(let entries):
            for e in (reverse ? entries.reversed() : entries) { apply(e, reverse: reverse) }
        }
    }

    private func push(_ entry: UndoEntry) {
        undoStack.append(entry)
        redoStack.removeAll()
        // Any non-coalesced push ends the open run; `update` re-opens it when
        // it pushed the first entry of a coalescing gesture.
        openCoalesceGroup = -1
        bump()
    }

    private func bump() {
        version &+= 1
        onChange?()
    }
}
