import CoreGraphics
import Foundation
import Vision

/// Vision text recognition on a captured bitmap. Used by the text capture
/// shortcut, which never produces an image file: the recognized string goes
/// straight to the clipboard.
nonisolated enum TextRecognizer {

    enum RecognitionError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let m): return "Text recognition failed: \(m)"
            }
        }
    }

    /// Recognizes every line of text in `image` and returns them in reading
    /// order, one line per source line. An image with no readable text yields
    /// an empty string.
    ///
    /// Runs off the main actor: `VNImageRequestHandler.perform` blocks, and a
    /// full-resolution Retina crop takes long enough to stall the overlay.
    static func recognize(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) { try recognizeNow(in: image) }.value
    }

    /// The synchronous core, so it can be exercised directly by the tests.
    /// Blocks the calling thread; the app always goes through `recognize`.
    static func recognizeNow(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw RecognitionError.failed(error.localizedDescription)
        }
        return lines(from: request.results ?? [])
    }

    /// Groups observations that sit on the same baseline band into one line,
    /// top to bottom and left to right. Vision's own order is close to this
    /// but not guaranteed, and side-by-side fragments of one line come back as
    /// separate observations.
    ///
    /// Bounding boxes are normalized with the origin at the bottom-left, so a
    /// larger `midY` is higher on the image.
    private static func lines(from observations: [VNRecognizedTextObservation]) -> String {
        var rows: [(midY: CGFloat, height: CGFloat, items: [(minX: CGFloat, text: String)])] = []

        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let box = observation.boundingBox
            // Same line when the centres are within half a line height of each
            // other - tolerant of the slight baseline jitter Vision reports.
            if let index = rows.firstIndex(where: { abs($0.midY - box.midY) < max($0.height, box.height) * 0.5 }) {
                rows[index].items.append((box.minX, text))
                rows[index].height = max(rows[index].height, box.height)
            } else {
                rows.append((box.midY, box.height, [(box.minX, text)]))
            }
        }

        return rows
            .sorted { $0.midY > $1.midY }
            .map { $0.items.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
