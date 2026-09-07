import AppKit

/// Tools offered in the toolbars. Order = toolbar order (Shottr's).
nonisolated enum EditorTool: String, CaseIterable, Sendable {
    case select, arrow, text, counter, rectangle, oval, freehand, line, crop, blur, highlighter

    var annotationKind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .text: return .text
        case .counter: return .counter
        case .rectangle: return .rectangle
        case .oval: return .oval
        case .freehand: return .freehand
        case .line: return .line
        case .blur: return .blur
        case .highlighter: return .highlighter
        }
    }

    /// Shottr's single-key shortcuts.
    var shortcutKey: String {
        switch self {
        case .select: "v"; case .arrow: "a"; case .text: "t"; case .counter: "c"
        case .rectangle: "r"; case .oval: "o"; case .freehand: "d"; case .line: "l"
        case .crop: "k"; case .blur: "b"; case .highlighter: "h"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"; case .arrow: "Arrow"; case .text: "Text"; case .counter: "Counter"
        case .rectangle: "Rectangle"; case .oval: "Oval"; case .freehand: "Freehand"; case .line: "Line"
        case .crop: "Crop"; case .blur: "Blur"; case .highlighter: "Highlighter"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"; case .arrow: "arrow.up.right"; case .text: "textformat"
        case .counter: "1.circle"; case .rectangle: "rectangle"; case .oval: "oval"
        case .freehand: "pencil"; case .line: "line.diagonal"; case .crop: "crop"
        case .blur: "drop"; case .highlighter: "highlighter"
        }
    }

    var tooltip: String { "\(title) (\(shortcutKey.uppercased()))" }

    static func tool(forKey key: String) -> EditorTool? {
        allCases.first { $0.shortcutKey == key.lowercased() }
    }
}
