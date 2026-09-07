import AppKit
import CoreImage

/// Turns a clip into a QR code you can scan off the screen with a phone.
///
/// Two halves, both pure enough to test without a window: `payload(for:store:)`
/// decides *what string* a clip encodes to (and says why it cannot), and
/// `image(for:pixelSize:)` renders that string with CoreImage's built-in
/// `CIQRCodeGenerator` — no third-party encoder, nothing to vendor.
///
/// **What a QR can hold.** 2,331 bytes, which is the format's own ceiling at
/// the "M" error-correction level used here — `CIQRCodeGenerator` returns
/// nothing at all past it. What makes a code readable off a screen is not the
/// byte count but how big each module is drawn: 2,331 bytes is a 179×179 grid,
/// and at the card's 320pt that is 1.79pt per module, the same density a
/// 1,000-byte code had at the old 220pt size (both were scan-tested on a phone
/// before the cap was raised). Card size and cap therefore move together — see
/// `QRCodePrompt.codeSize`. Past the cap the action is offered but disabled,
/// with the byte count in the tooltip, rather than producing nothing.
enum QRCodeService {
    /// The largest payload a QR code can carry at level "M" — the format's
    /// ceiling, not a policy of ours. `imageIsRenderable` pins it to what the
    /// encoder actually accepts.
    static let maxPayloadBytes = 2_331

    /// Why a clip has no QR code.
    enum Unavailable: Error, Equatable {
        /// Images and files: the bytes do not fit and a local path means
        /// nothing on the phone that scans it.
        case unsupportedKind(ContentKind)
        /// Nothing but whitespace to encode.
        case empty
        /// Longer than `maxPayloadBytes`.
        case tooLong(bytes: Int)

        /// Tooltip / card text. Written to finish the sentence "no QR code
        /// because…", but reads on its own.
        var reason: String {
            switch self {
            case .unsupportedKind(let kind):
                return "A QR code can only carry text - \(kind.label.lowercased()) clips are too big for one"
            case .empty:
                return "This clip has no text to put in a QR code"
            case .tooLong(let bytes):
                return "Too long for a QR code - the format holds \(maxPayloadBytes) bytes and this clip is \(bytes)"
            }
        }
    }

    /// The string `item` encodes to, or why it has none.
    ///
    /// Link, email and phone clips get their URL scheme so the phone offers to
    /// open, compose or call straight from the camera banner; every other text
    /// kind is encoded verbatim, so what the phone shows is what the clip
    /// holds, whitespace included.
    static func payload(for item: ClipboardItem, store: ClipboardStore) -> Result<String, Unavailable> {
        let kind = item.displayKind
        switch kind {
        case .image, .file:
            return .failure(.unsupportedKind(kind))
        case .text, .richText, .code, .color, .link, .email, .phone:
            break
        }

        let text = store.fullText(for: item) ?? item.textContent ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        let payload: String
        switch kind {
        case .link:
            payload = trimmed
        case .email:
            payload = trimmed.lowercased().hasPrefix("mailto:") ? trimmed : "mailto:\(trimmed)"
        case .phone:
            payload = trimmed.lowercased().hasPrefix("tel:") ? trimmed : "tel:\(dialableDigits(of: trimmed))"
        default:
            // Verbatim, not the trimmed copy: a text clip's QR should hand the
            // phone exactly what the clip holds.
            payload = text
        }

        let bytes = byteCount(payload)
        guard bytes <= maxPayloadBytes else { return .failure(.tooLong(bytes: bytes)) }
        return .success(payload)
    }

    /// UTF-8 length, the unit a QR code actually measures.
    static func byteCount(_ payload: String) -> Int {
        payload.utf8.count
    }

    /// Everything a phone can dial: digits, and a leading `+` for a country
    /// code. Spaces, dashes and brackets are how people write a number, not
    /// part of it, and a `tel:` URL carrying them is not reliably dialable.
    static func dialableDigits(of number: String) -> String {
        let plus = number.hasPrefix("+") ? "+" : ""
        return plus + number.filter { $0.isNumber }
    }

    /// Renders `payload` as a QR code at least `pixelSize` points square.
    ///
    /// The generator emits one pixel per module, so the image is scaled up by
    /// a whole-number factor with a plain affine transform — nearest-neighbour,
    /// no interpolation — which keeps the module edges hard. A smoothed QR is
    /// a slower scan.
    static func image(for payload: String, pixelSize: CGFloat = 512) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        // "M" recovers from ~15% damage. "L" would fit more data, but this is
        // read off a glossy screen, sometimes at an angle.
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, (pixelSize / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
    }

    /// PNG bytes for the rendered code, for "Save PNG…".
    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
