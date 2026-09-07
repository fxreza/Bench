import AppKit

/// RGBA color that is Codable and Equatable, independent of NSColor identity.
nonisolated struct AnnotationColor: Codable, Equatable, Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    /// "#RRGGBB" or "#RRGGBBAA"
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255)
        } else {
            self.init(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                      blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        }
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
    func withAlpha(_ a: CGFloat) -> AnnotationColor { var c = self; c.alpha = a; return c }

    var hexString: String {
        String(format: "#%02X%02X%02X", Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }

    /// Shottr's default annotation red (#FF0C01).
    static let shottrRed = AnnotationColor(red: 1.0, green: 0.047, blue: 0.004)
    static let highlighterYellow = AnnotationColor(red: 1.0, green: 0.93, blue: 0.0)
    static let white = AnnotationColor(red: 1, green: 1, blue: 1)
    static let black = AnnotationColor(red: 0, green: 0, blue: 0)

    /// Swatches offered in the color picker (Shottr-like palette).
    static let palette: [AnnotationColor] = [
        .shottrRed,
        AnnotationColor(red: 1.0, green: 0.58, blue: 0.0),   // orange
        AnnotationColor(red: 1.0, green: 0.84, blue: 0.0),   // yellow
        AnnotationColor(red: 0.20, green: 0.78, blue: 0.35), // green
        AnnotationColor(red: 0.0, green: 0.48, blue: 1.0),   // blue
        AnnotationColor(red: 0.69, green: 0.32, blue: 0.87), // purple
        AnnotationColor(red: 1.0, green: 0.18, blue: 0.57),  // pink
        .white,
        AnnotationColor(red: 0.5, green: 0.5, blue: 0.5),
        .black,
    ]
}

nonisolated enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case arrow, line, rectangle, oval, text, freehand, highlighter, blur, counter
}

/// Only two arrow types (per spec): Shottr's tapered arrow and thin line arrow.
nonisolated enum ArrowType: String, Codable, CaseIterable, Sendable {
    case tapered, thin
}

nonisolated enum ShapeStyle: String, Codable, CaseIterable, Sendable {
    case outline, translucent, solid
}

nonisolated enum BlurMode: String, Codable, CaseIterable, Sendable {
    case mosaic, gaussian
}

/// Shottr text styles: `label` = white text on a colored rounded bubble with an
/// optional pointer tail; `plain` = colored text with a thin contrasting outline.
nonisolated enum TextStyle: String, Codable, CaseIterable, Sendable {
    case label, plain
}

/// Discrete size steps used by text and counter sliders (Shottr uses 1...5).
nonisolated enum SizeStep: Int, Codable, CaseIterable, Sendable {
    case xs = 1, s, m, l, xl
    var textPointSize: CGFloat {
        switch self { case .xs: 12; case .s: 16; case .m: 22; case .l: 30; case .xl: 42 }
    }
    var counterDiameter: CGFloat {
        switch self { case .xs: 18; case .s: 24; case .m: 30; case .l: 40; case .xl: 52 }
    }
}

/// The user's current per-tool style choices (persisted in UserDefaults; new
/// annotations copy these, and editing a selected annotation writes back).
nonisolated struct ToolStyle: Codable, Equatable, Sendable {
    var color: AnnotationColor = .shottrRed
    var thickness: CGFloat = 4          // 1...20, strokes
    var arrowType: ArrowType = .tapered
    var shapeStyle: ShapeStyle = .outline
    var blurMode: BlurMode = .mosaic
    var blurStrength: CGFloat = 0.5     // 0...1
    var textStyle: TextStyle = .label
    var textPointer: Bool = true        // label bubble has a pointer tail
    var size: SizeStep = .m             // counter
    var fontSize: CGFloat = 22          // text, points 10...72
    var highlighterColor: AnnotationColor = .highlighterYellow
    var highlighterThickness: CGFloat = 18
}
