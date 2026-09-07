import Foundation

/// Semantic classification of a clipboard item's content.
///
/// Orthogonal to `ClipboardItemType` (which describes *how* the payload is
/// stored). `ClipboardItem.kind` stays `nil` for items captured before
/// detection existed — detection itself lands in Phase 3C.
enum ContentKind: String, Codable, CaseIterable {
    case text
    case richText
    case link
    case image
    case file
    case color
    case code
    case email
    case phone

    var label: String {
        switch self {
        case .text:     return "Text"
        case .richText: return "Rich Text"
        case .link:     return "Link"
        case .image:    return "Image"
        case .file:     return "File"
        case .color:    return "Color"
        case .code:     return "Code"
        case .email:    return "Email"
        case .phone:    return "Phone"
        }
    }

    var systemImage: String {
        switch self {
        case .text:     return "doc.text"
        case .richText: return "doc.richtext"
        case .link:     return "link"
        case .image:    return "photo"
        case .file:     return "doc"
        case .color:    return "paintpalette"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .email:    return "envelope"
        case .phone:    return "phone"
        }
    }
}
