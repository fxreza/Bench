import AppKit
import Vision

enum OCRError: LocalizedError {
    case noImage
    case noText
    case visionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noImage: return "Could not read the captured image."
        case .noText: return "No text found in the selected area."
        case .visionFailed(let err): return "Text recognition failed: \(err.localizedDescription)"
        }
    }
}

/// On-device text recognition via Vision's VNRecognizeTextRequest — free, no network.
enum OCRService {
    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.noImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.visionFailed(error))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.resume(throwing: OCRError.noText)
                    return
                }
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = recognitionLanguages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.visionFailed(error))
            }
        }
    }

    /// One recognized line and where it sits, in Vision's normalized,
    /// bottom-left-origin image space.
    struct Line: Sendable {
        let text: String
        let boundingBox: CGRect
    }

    /// Line-level recognition, for callers that need to know *which* line the
    /// text came from — point-translate picks the line under the pointer out
    /// of a region that deliberately contains several. `recognizeText` stays
    /// the whole-image path; this only exposes the geometry it throws away.
    static func recognizeLines(in cgImage: CGImage) async throws -> [Line] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.visionFailed(error))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [Line] = observations.compactMap { observation in
                    guard let text = observation.topCandidates(1).first?.string,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return nil }
                    return Line(
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        boundingBox: observation.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = recognitionLanguages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.visionFailed(error))
            }
        }
    }

    /// English always; add Persian (or failing that, generic Arabic-script) if this
    /// macOS's Vision build supports it — otherwise English-only is the safe fallback.
    private static let recognitionLanguages: [String] = {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        var langs = ["en-US"]
        guard let supported = try? probe.supportedRecognitionLanguages() else { return langs }
        if supported.contains(where: { $0.hasPrefix("fa") }) {
            langs.append("fa-IR")
        } else if supported.contains(where: { $0.hasPrefix("ar") }) {
            langs.append("ar-SA")
        }
        return langs
    }()
}
