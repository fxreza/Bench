import AppKit
import Foundation
import BenchTestKit
@testable import Klip

// "Show QR Code" (`Services/QRCodeService.swift`).
//
// Two things are worth pinning down: what a clip *encodes to* — a link goes
// verbatim, an email and a phone number get the scheme that makes a phone
// offer to write or call, and text goes byte-for-byte — and the three ways a
// clip has no code at all, since those are what the disabled icon's tooltip
// and the card's explanation are built from.

enum QRCodeTests {
    static let tests: [(String, () throws -> Void)] = [
        ("payload_textIsEncodedVerbatim", testTextVerbatim),
        ("payload_linkGoesThroughUntouched", testLink),
        ("payload_emailGetsMailtoOnceOnly", testEmail),
        ("payload_phoneKeepsOnlyDialableCharacters", testPhone),
        ("payload_imageAndFileClipsHaveNoCode", testUnsupportedKinds),
        ("payload_whitespaceOnlyClipHasNoCode", testEmptyClip),
        ("payload_overTheByteCapHasNoCode", testTooLong),
        ("payload_atTheByteCapStillHasOne", testAtTheCap),
        ("byteCount_countsUTF8BytesNotCharacters", testByteCount),
        ("image_rendersAtLeastTheRequestedSizeAndIsSquare", testRender),
        ("image_isPNGEncodable", testPNGData),
        ("image_capIsExactlyWhatTheEncoderAccepts", testCapMatchesEncoder),
    ]

    // MARK: - Helpers

    /// A store rooted in a throwaway directory, so `fullText(for:)` has
    /// somewhere real to look. Mirrors `ClipboardStoreTests.withStore`.
    static func withStore<R>(_ body: (ClipboardStore) throws -> R) rethrows -> R {
        try withTempDir { dir in
            let store = ClipboardStore(directory: dir)
            defer { store.flushPendingSave() }
            return try body(store)
        }
    }

    static func item(_ text: String, kind: ContentKind) -> ClipboardItem {
        var item = ClipboardItem.text(text)
        item.kind = kind
        return item
    }

    static func payload(_ text: String, kind: ContentKind) throws -> String {
        try withStore { store in
            let result = QRCodeService.payload(for: item(text, kind: kind), store: store)
            switch result {
            case .success(let payload): return payload
            case .failure(let reason):
                throw TestFailure(message: "expected a payload, got \(reason)", file: #file, line: #line)
            }
        }
    }

    static func failure(_ item: ClipboardItem) throws -> QRCodeService.Unavailable {
        try withStore { store in
            let result = QRCodeService.payload(for: item, store: store)
            switch result {
            case .success(let payload):
                throw TestFailure(message: "expected no code, got \(payload.count) chars", file: #file, line: #line)
            case .failure(let reason): return reason
            }
        }
    }

    // MARK: - What a clip encodes to

    static func testTextVerbatim() throws {
        // Byte-for-byte, inner newlines and all: what the phone reads has to
        // be what the clip holds, not a tidied copy of it.
        let text = "first line\n  second line  \n"
        try expectEqual(try payload(text, kind: .text), text)
        try expectEqual(try payload("let x = 1\n\tlet y = 2", kind: .code), "let x = 1\n\tlet y = 2")
        try expectEqual(try payload("#FF8800", kind: .color), "#FF8800")
    }

    static func testLink() throws {
        try expectEqual(try payload("  https://example.com/a?b=c  ", kind: .link),
                        "https://example.com/a?b=c",
                        "surrounding whitespace is not part of the URL")
    }

    static func testEmail() throws {
        try expectEqual(try payload("someone@example.com", kind: .email), "mailto:someone@example.com")
        try expectEqual(try payload("mailto:someone@example.com", kind: .email),
                        "mailto:someone@example.com",
                        "a clip that already carries the scheme is not given a second one")
        try expectEqual(try payload("MAILTO:Someone@Example.com", kind: .email),
                        "MAILTO:Someone@Example.com",
                        "the check is case-insensitive, but the address keeps its own case")
    }

    static func testPhone() throws {
        try expectEqual(try payload("+1 (555) 010-9999", kind: .phone), "tel:+15550109999",
                        "spaces, brackets and dashes are how a number is written, not part of it")
        try expectEqual(try payload("555 010 9999", kind: .phone), "tel:5550109999")
        try expectEqual(try payload("tel:+15550109999", kind: .phone), "tel:+15550109999")
    }

    // MARK: - When there is no code

    static func testUnsupportedKinds() throws {
        try expectEqual(try failure(ClipboardItem.image(filename: "shot.png", uti: "public.png")),
                        .unsupportedKind(.image))

        var fileClip = ClipboardItem.text("Report.pdf")
        fileClip.kind = .file
        try expectEqual(try failure(fileClip), .unsupportedKind(.file))

        // And the reason is a sentence the tooltip can show as-is.
        try expect(QRCodeService.Unavailable.unsupportedKind(.image).reason.contains("image"),
                   "the reason names the kind it is refusing")
    }

    static func testEmptyClip() throws {
        try expectEqual(try failure(item("   \n\t ", kind: .text)), .empty)
    }

    static func testTooLong() throws {
        let long = String(repeating: "a", count: QRCodeService.maxPayloadBytes + 1)
        try expectEqual(try failure(item(long, kind: .text)),
                        .tooLong(bytes: QRCodeService.maxPayloadBytes + 1))
    }

    static func testAtTheCap() throws {
        let exact = String(repeating: "a", count: QRCodeService.maxPayloadBytes)
        try expectEqual(try payload(exact, kind: .text).count, QRCodeService.maxPayloadBytes,
                        "the cap is inclusive")
    }

    static func testByteCount() throws {
        // A QR measures bytes, so a short string of multi-byte characters can
        // still be over the cap.
        try expectEqual(QRCodeService.byteCount("héllo"), 6)
        try expectEqual(QRCodeService.byteCount("日本語"), 9)
        try expectEqual(QRCodeService.byteCount(""), 0)
    }

    // MARK: - Rendering

    static func testRender() throws {
        let image = QRCodeService.image(for: "https://example.com", pixelSize: 440)
        try expectNotNil(image, "CIQRCodeGenerator produced nothing")
        guard let image else { return }
        try expect(image.size.width >= 200, "scaled up from one pixel per module, got \(image.size.width)")
        try expectEqual(image.size.width, image.size.height, "a QR code is square")
    }

    /// The cap is the format's ceiling now, not a comfort margin, so it has to
    /// track what `CIQRCodeGenerator` will actually encode: one byte over and
    /// the generator returns nothing, which would put an empty white square on
    /// the card instead of a code.
    static func testCapMatchesEncoder() throws {
        let atCap = String(repeating: "a", count: QRCodeService.maxPayloadBytes)
        try expectNotNil(QRCodeService.image(for: atCap),
                         "the cap must be a payload the encoder still accepts")

        let overCap = String(repeating: "a", count: QRCodeService.maxPayloadBytes + 1)
        try expectNil(QRCodeService.image(for: overCap),
                      "the cap must not be lower than the encoder's own ceiling")
    }

    static func testPNGData() throws {
        guard let image = QRCodeService.image(for: "klip", pixelSize: 220) else {
            throw TestFailure(message: "no image to encode", file: #file, line: #line)
        }
        let data = QRCodeService.pngData(for: image)
        try expectNotNil(data, "the card's Save PNG… has nothing to write")
        // PNG magic number, so this is a real PNG and not a TIFF passed through.
        try expectEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
