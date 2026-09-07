import AppKit
import CoreGraphics
@testable import Shot

/// Undo/redo semantics of `AnnotationDocument`, in particular the gesture
/// scoping of `update(coalesce:)` / `replaceImage(coalesce:)`.
enum AnnotationDocumentTests {

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func check(_ cond: Bool, _ msg: String) throws {
        if !cond { throw Failure(message: msg) }
    }

    /// Solid grey bitmap, `side` x `side` px.
    private static func image(_ side: Int = 8) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }

    private static func document() -> AnnotationDocument {
        AnnotationDocument(image: image(), pixelScale: 1)
    }

    private static func rect(_ doc: AnnotationDocument, _ id: UUID) -> CGRect {
        doc.annotation(id: id)?.rect ?? .null
    }

    static let suite: (String, [(String, () throws -> Void)]) = ("AnnotationDocument", [

        ("one drag of an annotation is one undo step", {
            let doc = document()
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 0, y: 0, width: 10, height: 10)
            doc.add(a)
            try check(doc.undoStack.count == 1, "add pushes one entry")

            doc.beginCoalescedGroup()
            for step in 1...5 {
                var moved = a
                moved.rect = CGRect(x: CGFloat(step), y: 0, width: 10, height: 10)
                doc.update(moved, coalesce: true)
            }
            try check(doc.undoStack.count == 2, "a whole drag adds exactly one entry, got \(doc.undoStack.count)")

            doc.undo()
            try check(rect(doc, a.id) == CGRect(x: 0, y: 0, width: 10, height: 10),
                      "undo restores the pre-drag geometry, got \(rect(doc, a.id))")
        }),

        ("two drags of the same annotation are two undo steps", {
            let doc = document()
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 0, y: 0, width: 10, height: 10)
            doc.add(a)

            for gesture in 1...2 {
                doc.beginCoalescedGroup()
                for step in 1...3 {
                    var moved = a
                    moved.rect = CGRect(x: CGFloat(gesture * 10 + step), y: 0, width: 10, height: 10)
                    doc.update(moved, coalesce: true)
                }
            }
            try check(doc.undoStack.count == 3, "add + two drags = three entries, got \(doc.undoStack.count)")

            doc.undo()
            try check(rect(doc, a.id).minX == 13, "undo rewinds only the second drag, got \(rect(doc, a.id).minX)")
            doc.undo()
            try check(rect(doc, a.id).minX == 0, "a second undo rewinds the first drag, got \(rect(doc, a.id).minX)")
        }),

        ("a coalescing run never merges into a non-coalesced entry", {
            let doc = document()
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 0, y: 0, width: 10, height: 10)
            doc.add(a)

            var edited = a
            edited.thickness = 9
            doc.update(edited)                       // e.g. a properties-panel edit
            try check(doc.undoStack.count == 2, "the panel edit is its own entry")

            var moved = edited
            moved.rect = CGRect(x: 4, y: 0, width: 10, height: 10)
            doc.update(moved, coalesce: true)
            try check(doc.undoStack.count == 3, "the drag does not swallow the panel edit, got \(doc.undoStack.count)")

            doc.undo()
            try check(doc.annotation(id: a.id)?.thickness == 9, "undoing the drag keeps the panel edit")
        }),

        ("a coalesced run of image replacements stays one undo step", {
            let doc = document()
            doc.beginCoalescedGroup()
            for side in [7, 6, 5] {
                doc.replaceImage(image(side), annotations: doc.annotations, coalesce: true)
            }
            try check(doc.undoStack.count == 1, "a held arrow key adds one entry, got \(doc.undoStack.count)")
            try check(doc.pixelSize == CGSize(width: 5, height: 5), "the last image wins, got \(doc.pixelSize)")

            doc.undo()
            try check(doc.pixelSize == CGSize(width: 8, height: 8),
                      "undo returns to the bitmap before the run, got \(doc.pixelSize)")
            doc.redo()
            try check(doc.pixelSize == CGSize(width: 5, height: 5), "redo replays the whole run")
        }),

        ("crop shifts annotations and is undoable", {
            let doc = document()
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 4, y: 4, width: 2, height: 2)
            doc.add(a)
            doc.crop(to: CGRect(x: 2, y: 2, width: 4, height: 4))

            try check(doc.pixelSize == CGSize(width: 4, height: 4), "cropped bitmap size, got \(doc.pixelSize)")
            try check(rect(doc, a.id) == CGRect(x: 2, y: 2, width: 2, height: 2),
                      "annotations move with the crop, got \(rect(doc, a.id))")

            doc.undo()
            try check(doc.pixelSize == CGSize(width: 8, height: 8), "undo restores the full bitmap")
            try check(rect(doc, a.id) == CGRect(x: 4, y: 4, width: 2, height: 2),
                      "undo restores the annotation geometry, got \(rect(doc, a.id))")
        }),
    ])
}
