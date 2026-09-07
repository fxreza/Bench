import SwiftUI

/// Parses a CSS colour literal out of a clipboard item's text so the row can
/// show a swatch instead of a generic icon.
///
/// Moved verbatim out of the old `Views/ClipboardItemRow.swift` (Phase 2A) so
/// the row, the preview pane and any future consumer share one implementation.
/// Supports `#RGB`, `#RRGGBB`, `#RRGGBBAA`, `rgb()/rgba()` and `hsl()/hsla()`.
/// Returns `nil` unless the whole string is exactly one of those forms.
enum ColorSwatchParser {
    /// Longest string still considered "might be just a colour".
    static let maxLength = 100

    /// Swatch for an item, or `nil` when it is not a pure colour value.
    static func swatch(for item: ClipboardItem) -> Color? {
        guard item.type == .text,
              let text = item.textContent,
              text.count <= maxLength else { return nil }
        return parse(text.trimmingCharacters(in: .whitespaces))
    }

    /// Parse a CSS color value from a string.
    static func parse(_ string: String) -> Color? {
        let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Try hex formats
        if trimmed.hasPrefix("#") {
            let hexStr = String(trimmed.dropFirst())
            if let color = parseHex(hexStr) {
                return color
            }
        }

        // Try rgb/rgba formats
        if trimmed.hasPrefix("rgb") {
            if let color = parseRGB(trimmed) {
                return color
            }
        }

        // Try hsl/hsla formats
        if trimmed.hasPrefix("hsl") {
            if let color = parseHSL(trimmed) {
                return color
            }
        }

        return nil
    }

    /// Parse hex color (#RGB, #RRGGBB, or #RRGGBBAA)
    private static func parseHex(_ hexStr: String) -> Color? {
        let hex = hexStr.filter { $0.isHexDigit }

        if hex.count == 3 {
            // Expand #RGB to #RRGGBB
            let expanded = hex.map { "\($0)\($0)" }.joined()
            return parseHex6(expanded)
        } else if hex.count == 6 {
            return parseHex6(hex)
        } else if hex.count == 8 {
            return parseHex8(hex)
        }

        return nil
    }

    /// Parse 6-digit hex color to RGB
    private static func parseHex6(_ hex: String) -> Color? {
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    /// Parse 8-digit hex color to RGBA
    private static func parseHex8(_ hex: String) -> Color? {
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 24) & 0xFF) / 255.0
        let g = Double((value >> 16) & 0xFF) / 255.0
        let b = Double((value >> 8) & 0xFF) / 255.0
        let a = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    /// Parse rgb(...) or rgba(...) format
    private static func parseRGB(_ string: String) -> Color? {
        let isRGBA = string.hasPrefix("rgba")
        let startOffset = isRGBA ? 5 : 4

        guard string.count > startOffset + 1 else { return nil }
        guard string.hasSuffix(")") else { return nil }

        let startIdx = string.index(string.startIndex, offsetBy: startOffset)
        let endIdx = string.index(string.endIndex, offsetBy: -1)
        let content = String(string[startIdx..<endIdx]).trimmingCharacters(in: .whitespaces)

        let components = content.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        guard components.count >= 3 else { return nil }
        guard let r = Double(components[0]).map({ $0 / 255.0 }),
              let g = Double(components[1]).map({ $0 / 255.0 }),
              let b = Double(components[2]).map({ $0 / 255.0 }) else { return nil }

        let a = isRGBA && components.count >= 4 ? Double(components[3]) ?? 1.0 : 1.0

        return Color(red: r, green: g, blue: b, opacity: a)
    }

    /// Parse hsl(...) or hsla(...) format
    private static func parseHSL(_ string: String) -> Color? {
        let isHSLA = string.hasPrefix("hsla")
        let startOffset = isHSLA ? 5 : 4

        guard string.count > startOffset + 1 else { return nil }
        guard string.hasSuffix(")") else { return nil }

        let startIdx = string.index(string.startIndex, offsetBy: startOffset)
        let endIdx = string.index(string.endIndex, offsetBy: -1)
        let content = String(string[startIdx..<endIdx]).trimmingCharacters(in: .whitespaces)

        let components = content.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        guard components.count >= 3 else { return nil }

        // Parse H (0-360), S (0-100%), L (0-100%)
        guard let h = Double(components[0].filter { $0.isNumber || $0 == "-" || $0 == "." }),
              let s = Double(components[1].filter { $0.isNumber || $0 == "." }),
              let l = Double(components[2].filter { $0.isNumber || $0 == "." }) else { return nil }

        let a = isHSLA && components.count >= 4 ? Double(components[3]) ?? 1.0 : 1.0

        let (r, g, b) = hslToRGB(h: h, s: s / 100.0, l: l / 100.0)

        return Color(red: r, green: g, blue: b, opacity: a)
    }

    /// Convert HSL to RGB using standard algorithm
    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let h = h.truncatingRemainder(dividingBy: 360)
        let s = max(0, min(1, s))
        let l = max(0, min(1, l))

        if s == 0 {
            return (l, l, l)
        }

        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q

        func hueToRGB(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }

        let hNorm = h / 360
        let r = hueToRGB(p, q, hNorm + 1/3)
        let g = hueToRGB(p, q, hNorm)
        let b = hueToRGB(p, q, hNorm - 1/3)

        return (r, g, b)
    }
}
