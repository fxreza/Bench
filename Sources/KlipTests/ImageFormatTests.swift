import Foundation
import AppKit
import BenchTestKit
@testable import Klip

// Task 6C — preserve original image bytes and format.
//
// Before this task, any pasteboard/Finder image capture was decoded via
// `NSImage` and re-saved as PNG, so a JPEG (e.g. a compressed screenshot from
// a Raycast script) silently lost its original compression on every
// copy/paste round-trip. Coverage below pins:
//
//  - a JPEG on the pasteboard is stored byte-identical, as `.jpg`, with
//    `imageUTI == "public.jpeg"`;
//  - a PNG on the pasteboard still stores as `.png`;
//  - TIFF-only pasteboard content still falls back to the old NSImage -> PNG
//    conversion (no verbatim raster representation exists to preserve);
//  - a single image file copied in Finder keeps its bytes/extension exactly,
//    whatever the format;
//  - paste/copy write the stored bytes back under their real UTI as the
//    first pasteboard type, plus a TIFF fallback, without touching the
//    primary bytes;
//  - Save to Disk writes the original bytes under the original extension;
//  - a legacy item (`.png` filename, `imageUTI == nil`, from before this
//    field existed) still loads, renders and pastes correctly.
enum ImageFormatTests {
    static let tests: [(String, () throws -> Void)] = [
        ("capture_jpegOnPasteboard_storedByteIdenticalAsJpgWithRealUTI", testCaptureJPEGVerbatim),
        ("capture_pngOnPasteboard_stillStoredAsPng", testCapturePNGVerbatim),
        ("capture_screenshotDeclaresPngAndTiff_storesPngNeverTranslatedJpeg", testCaptureScreenshotStaysPNG),
        ("capture_tiffOnly_fallsBackToPngConversion", testCaptureTIFFOnlyFallsBack),
        ("capture_finderJpegFile_storedByteIdenticalWithRealUTI", testCaptureFinderJPEGFile),
        ("writeImage_jpegItem_publicJpegIsFirstTypeWithIdenticalBytes", testWriteImageJPEGVerbatim),
        ("writeImage_jpegItem_offersTiffFallbackWithoutAlteringPrimaryBytes", testWriteImageTIFFFallback),
        ("writeImage_pngItem_pngFirstPlusTiffFallback", testWriteImagePNG),
        ("saveToDisk_jpegItem_writesOriginalBytesAndExtension", testSaveToDiskKeepsJPEGBytes),
        ("legacyItem_pngFilenameNilUTI_stillLoadsRendersAndPastes", testLegacyPNGItemStillWorks),
    ]

    // MARK: - Harness (mirrors ClipboardWatcherTests' private-pasteboard pattern)

    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.fxreza.klip.tests.imageformat.\(UUID().uuidString)"))
    }

    @discardableResult
    private static func pump(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func require<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value else { throw TestFailure(message: message, file: file, line: line) }
        return value
    }

    /// A tiny solid-color bitmap, used as the seed for the JPEG/PNG/TIFF
    /// fixtures below.
    private static func makeBitmap(width: Int = 8, height: Int = 8) throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw TestFailure(message: "failed to allocate the bitmap fixture", file: #file, line: #line)
        }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A JPEG at 70% quality — the exact recipe the task brief calls for
    /// (matching a Raycast screenshot script's output).
    private static func makeJPEGData(compression: Double = 0.7) throws -> Data {
        let rep = try makeBitmap()
        return try require(
            rep.representation(using: .jpeg, properties: [.compressionFactor: compression]),
            "failed to build the JPEG fixture"
        )
    }

    private static func makePNGData() throws -> Data {
        let rep = try makeBitmap()
        return try require(rep.representation(using: .png, properties: [:]), "failed to build the PNG fixture")
    }

    private static func makeTIFFData() throws -> Data {
        let rep = try makeBitmap()
        return try require(rep.representation(using: .tiff, properties: [:]), "failed to build the TIFF fixture")
    }

    /// Primes a fresh `ClipboardWatcher`/private-pasteboard pair the same way
    /// `ClipboardWatcherTests.withWatcher` does, so the first real write below
    /// is unambiguously a change.
    private static func withWatcher(
        _ body: (ClipboardWatcher, ClipboardStore, URL, NSPasteboard) throws -> Void
    ) throws {
        try ClipboardStoreTests.withStore { store, dir in
            let watcher = ClipboardWatcher(store: store)
            let pasteboard = makePasteboard()
            pasteboard.clearContents()
            watcher.capture(from: pasteboard)
            try body(watcher, store, dir, pasteboard)
        }
    }

    private static func storedImageData(_ dir: URL, filename: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("images").appendingPathComponent(filename))
    }

    // MARK: - Capture: pasteboard verbatim paths

    /// A macOS screenshot (⌃⇧⌘4 / `screencapture -c`) declares only
    /// `public.png` + `public.tiff`. The pasteboard server can still hand out a
    /// translated JPEG for an undeclared `public.jpeg` request, which is exactly
    /// the silent re-encoding this feature exists to prevent. Only declared
    /// formats may win, in the order the source declared them.
    static func testCaptureScreenshotStaysPNG() throws {
        try withWatcher { watcher, store, dir, pasteboard in
            let png = try makePNGData()
            let tiff = try makeTIFFData()
            pasteboard.clearContents()
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(png, forType: .png)
            pasteboard.setData(tiff, forType: .tiff)
            watcher.capture(from: pasteboard)

            try expect(pump { store.items.count == 1 }, "the screenshot clip should reach the store")
            let item = store.items[0]
            try expectEqual(item.imageUTI, "public.png", "a PNG screenshot must stay PNG, never a translated JPEG")
            let filename = try require(item.imageFilename, "the item should carry an image filename")
            try expect(filename.hasSuffix(".png"), "expected a .png file, got \(filename)")
            let stored = try storedImageData(dir, filename: filename)
            try expectEqual(stored, png, "the stored bytes must be the declared PNG, byte for byte")
        }
    }

    static func testCaptureJPEGVerbatim() throws {
        try withWatcher { watcher, store, dir, pasteboard in
            let jpeg = try makeJPEGData(compression: 0.7)
            pasteboard.clearContents()
            pasteboard.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
            watcher.capture(from: pasteboard)

            try expect(pump { store.items.count == 1 }, "the JPEG clip should reach the store")
            let item = store.items[0]
            try expectEqual(item.imageUTI, "public.jpeg", "a captured JPEG should record its real UTI")
            let filename = try require(item.imageFilename, "the item should carry an image filename")
            try expect(filename.hasSuffix(".jpg"), "a captured JPEG should be stored with a .jpg extension, got \(filename)")

            let stored = try storedImageData(dir, filename: filename)
            try expectEqual(stored, jpeg, "the stored bytes must be byte-identical to the captured JPEG — never re-encoded")
        }
    }

    static func testCapturePNGVerbatim() throws {
        try withWatcher { watcher, store, dir, pasteboard in
            let png = try makePNGData()
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            watcher.capture(from: pasteboard)

            try expect(pump { store.items.count == 1 }, "the PNG clip should reach the store")
            let item = store.items[0]
            try expectEqual(item.imageUTI, "public.png", "a captured PNG should record public.png")
            let filename = try require(item.imageFilename, "the item should carry an image filename")
            try expect(filename.hasSuffix(".png"), "a captured PNG should keep its .png extension, got \(filename)")

            let stored = try storedImageData(dir, filename: filename)
            try expectEqual(stored, png, "PNG bytes should still round-trip byte-identical")
        }
    }

    static func testCaptureTIFFOnlyFallsBack() throws {
        try withWatcher { watcher, store, dir, pasteboard in
            let tiff = try makeTIFFData()
            pasteboard.clearContents()
            // Only TIFF on the pasteboard — none of the five verbatim raster
            // types are present, so this must take the fallback path.
            pasteboard.setData(tiff, forType: .tiff)
            watcher.capture(from: pasteboard)

            try expect(pump { store.items.count == 1 }, "TIFF-only content should still be captured")
            let item = store.items[0]
            try expectEqual(item.imageUTI, "public.png", "the fallback path always re-encodes to PNG")
            let filename = try require(item.imageFilename, "the item should carry an image filename")
            try expect(filename.hasSuffix(".png"), "the fallback path stores a .png file, got \(filename)")

            let stored = try storedImageData(dir, filename: filename)
            try expect(NSImage(data: stored) != nil, "the fallback output should still be a valid, decodable image")
        }
    }

    // MARK: - Capture: single image file copied in Finder

    static func testCaptureFinderJPEGFile() throws {
        try withTempDir { sourceDir in
            try withWatcher { watcher, store, dir, pasteboard in
                let jpeg = try makeJPEGData(compression: 0.7)
                let sourceFile = sourceDir.appendingPathComponent("Screenshot.jpg")
                try jpeg.write(to: sourceFile)

                pasteboard.clearContents()
                pasteboard.setPropertyList([sourceFile.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
                watcher.capture(from: pasteboard)

                try expect(pump { store.items.count == 1 }, "the Finder-copied JPEG file should reach the store")
                let item = store.items[0]
                try expectEqual(item.imageUTI, "public.jpeg", "a Finder-copied .jpg should record public.jpeg")
                let filename = try require(item.imageFilename, "the item should carry an image filename")
                try expect(filename.hasSuffix(".jpg"), "a Finder-copied .jpg should keep its .jpg extension, got \(filename)")

                let stored = try storedImageData(dir, filename: filename)
                try expectEqual(stored, jpeg, "a Finder-copied image file's bytes must never be re-encoded")
            }
        }
    }

    // MARK: - Paste/copy: PasteController.writeImage

    static func testWriteImageJPEGVerbatim() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let jpeg = try makeJPEGData(compression: 0.7)
            let filename = try require(store.saveImage(jpeg, fileExtension: "jpg"), "should save the JPEG fixture")
            let item = ClipboardItem.image(filename: filename, uti: "public.jpeg")

            let pasteboard = makePasteboard()
            PasteController.writeImage(item, store: store, to: pasteboard)

            let types = pasteboard.types ?? []
            try expectEqual(
                types.first, NSPasteboard.PasteboardType("public.jpeg"),
                "public.jpeg must be written as the first/primary pasteboard type"
            )
            let written = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg"))
            try expectEqual(written, jpeg, "the pasted/copied bytes must be identical to the stored JPEG")
        }
    }

    static func testWriteImageTIFFFallback() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let jpeg = try makeJPEGData(compression: 0.7)
            let filename = try require(store.saveImage(jpeg, fileExtension: "jpg"), "should save the JPEG fixture")
            let item = ClipboardItem.image(filename: filename, uti: "public.jpeg")

            let pasteboard = makePasteboard()
            PasteController.writeImage(item, store: store, to: pasteboard)

            try expectNotNil(
                pasteboard.data(forType: .tiff),
                "a TIFF representation should be offered alongside the primary JPEG bytes"
            )
            let primaryAfterFallback = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg"))
            try expectEqual(primaryAfterFallback, jpeg, "offering the TIFF fallback must not alter the primary bytes")
        }
    }

    static func testWriteImagePNG() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let png = try makePNGData()
            let filename = try require(store.saveImage(png, fileExtension: "png"), "should save the PNG fixture")
            let item = ClipboardItem.image(filename: filename, uti: "public.png")

            let pasteboard = makePasteboard()
            PasteController.writeImage(item, store: store, to: pasteboard)

            let types = pasteboard.types ?? []
            try expectEqual(types.first, .png, "PNG's primary type should be .png, exactly as before")
            try expectEqual(pasteboard.data(forType: .png), png, "PNG bytes should round-trip identical")
            try expectNotNil(pasteboard.data(forType: .tiff), "PNG should still offer its TIFF fallback, as today")
        }
    }

    // MARK: - Save to Disk

    static func testSaveToDiskKeepsJPEGBytes() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let jpeg = try makeJPEGData(compression: 0.7)
            let filename = try require(store.saveImage(jpeg, fileExtension: "jpg"), "should save the JPEG fixture")
            let item = ClipboardItem.image(filename: filename, uti: "public.jpeg")

            try expectEqual(
                PasteController.imageFileExtension(for: item), "jpg",
                "Save to Disk should default to the item's original extension"
            )

            try withTempDir { destDir in
                let destination = destDir.appendingPathComponent("Saved.jpg")
                let wrote = PasteController.writeImageData(for: item, store: store, to: destination)
                try expect(wrote, "the save-to-disk write should succeed")

                let saved = try Data(contentsOf: destination)
                try expectEqual(saved, jpeg, "Save to Disk must write the original bytes, never re-encoded")
            }
        }
    }

    // MARK: - Legacy items (pre-6C: `.png` filename, `imageUTI == nil`)

    static func testLegacyPNGItemStillWorks() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let png = try makePNGData()
            // `saveImage` defaults to a `.png` filename with no UTI recorded,
            // exactly like every capture before this task.
            let filename = try require(store.saveImage(png), "should save the legacy PNG fixture")
            let item = ClipboardItem.image(filename: filename)

            try expectNil(item.imageUTI, "a legacy item has no recorded imageUTI")
            try expectEqual(item.resolvedImageUTI, "public.png", "the UTI should be derived from the .png extension")

            // Loads/renders.
            try expectNotNil(store.image(for: item), "a legacy .png item should still decode as an NSImage")

            // Pastes.
            let pasteboard = makePasteboard()
            PasteController.writeImage(item, store: store, to: pasteboard)
            try expectEqual(pasteboard.types?.first, .png, "a legacy item should still paste as .png first")
            try expectEqual(pasteboard.data(forType: .png), png, "a legacy item's bytes should still round-trip")
        }
    }
}
