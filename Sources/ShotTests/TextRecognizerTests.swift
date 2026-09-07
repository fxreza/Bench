import AppKit
import CoreGraphics
import Foundation
@testable import Shot

/// Local failure type and helpers, private to this file (same convention as
/// CaptureFormatTests).
nonisolated private struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

nonisolated private func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw CheckFailure(message: message()) }
}

/// Renders `lines` as black text on white, at the size a Retina screenshot of
/// normal UI text would have, so Vision has something realistic to read.
nonisolated private func makeTextImage(_ lines: [String], width: Int = 900, lineHeight: Int = 90) -> CGImage? {
    let height = lineHeight * lines.count + 40
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 56),
        .foregroundColor: NSColor.black,
    ]
    // CoreGraphics origin is bottom-left, so the first line is drawn highest.
    for (index, line) in lines.enumerated() {
        let y = height - 40 - lineHeight * (index + 1)
        (line as NSString).draw(at: CGPoint(x: 30, y: CGFloat(y)), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

enum TextRecognizerTests {

    static let suite: (String, [(String, () throws -> Void)]) = ("Text recognition", [

        ("reads a single line of rendered text", {
            guard let image = makeTextImage(["Snapper reads text"]) else {
                throw CheckFailure(message: "could not render the test bitmap")
            }
            let text = try TextRecognizer.recognizeNow(in: image)
            try check(text.contains("Snapper"), "expected 'Snapper' in: \(text)")
            try check(text.contains("reads text"), "expected 'reads text' in: \(text)")
        }),

        ("keeps separate lines in reading order", {
            guard let image = makeTextImage(["First line here", "Second line here", "Third line here"]) else {
                throw CheckFailure(message: "could not render the test bitmap")
            }
            let text = try TextRecognizer.recognizeNow(in: image)
            let lines = text.split(separator: "\n").map(String.init)
            try check(lines.count == 3, "expected 3 lines, got \(lines.count): \(text)")
            try check(lines[0].contains("First"), "line 1: \(lines[0])")
            try check(lines[1].contains("Second"), "line 2: \(lines[1])")
            try check(lines[2].contains("Third"), "line 3: \(lines[2])")
        }),

        ("a blank image yields an empty string, not an error", {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
                  let blank = { () -> CGImage? in
                      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                      ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
                      return ctx.makeImage()
                  }() else {
                throw CheckFailure(message: "could not build the blank bitmap")
            }
            try check(TextRecognizer.recognizeNow(in: blank).isEmpty, "a blank image should recognize nothing")
        }),
    ])
}
