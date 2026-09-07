import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// UI-side view of a clipboard item's semantic kind.
///
/// `ClipboardItem.kind` is `nil` for everything captured before Phase 3C's
/// detector exists, so the whole UI reads `displayKind` instead: it falls back
/// to the storage `type`, plus the one classification the list has always been
/// able to make locally (a pure CSS colour literal). Once 3C backfills `kind`,
/// this simply starts returning the stored value.
extension ClipboardItem {
    var displayKind: ContentKind {
        if let kind = kind { return kind }
        switch type {
        case .image: return .image
        case .file:  return .file
        case .text:
            return ColorSwatchParser.swatch(for: self) != nil ? .color : .text
        }
    }

    /// The colour swatch to draw for a `.color` item, if it parses.
    var swatchColor: Color? {
        ColorSwatchParser.swatch(for: self)
    }

    /// Icon for a `.file` item. Prefers Launch Services' icon for the actual
    /// file when the payload is reachable on disk; if it went missing (moved
    /// or deleted) this falls back to the generic icon for its extension/UTI,
    /// so a missing "Report.pdf" still reads as a pdf rather than a blank
    /// `doc`. `nil` only when there is no file information at all.
    func fileIcon(store: ClipboardStore) -> NSImage? {
        guard type == .file || isFile else { return nil }

        if let url = store.fileURLs(for: self).first, FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        // Missing on disk — fall back to a generic icon from the UTI/extension.
        if let uti = fileAttachment?.uti, let type = UTType(uti) {
            return NSWorkspace.shared.icon(for: type)
        }
        let ext = (fileAttachment?.originalName as NSString?)?.pathExtension ?? ""
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return nil
    }
}

// MARK: - Format ("what kind of thing is this?")

/// The short, familiar name for a clip's file format — "PNG image", "Word
/// document", "Excel spreadsheet" — shown as **Kind** in the preview pane's
/// footer, matching what Finder calls the same line.
///
/// Named `ItemFormat` rather than `ItemKind` only to stay clear of
/// `ContentKind`, the broader Text / Image / File / Code classification that
/// the preview header and the filter chips use. The two answer different
/// questions: `ContentKind` says which chip a clip belongs under, this says
/// what the bytes are.
///
/// **Why a hand-written table rather than the system's own answer.**
/// `UTType.localizedDescription` is right there and is what Finder's Kind
/// column is built on, but read out loud it is often not what anyone calls
/// the thing: `.xlsx` comes back as "Office Open XML spreadsheet", `.docx` as
/// "Office Open XML word processing document", `.webp` as "Google's WebP",
/// and plain text as the bare lowercase word "text". Worse, the answer
/// depends on which apps are installed — `.numbers` and `.pages` resolve to
/// nothing at all on a Mac without iWork, so the row would be blank on one
/// machine and filled on another for the same clip.
///
/// So the formats people actually recognise are named here, and the system
/// description is the *fallback* for everything else (Sketch, Photoshop,
/// Xcode projects and so on), where it is both correct and the only source
/// that knows. Nothing here touches the disk: it reads the UTI Klip already
/// stored with the clip, or the file name's extension.
enum ItemFormat {
    /// A stored image's format, from the UTI captured with it (falling back to
    /// the stored file's extension via `resolvedImageUTI`).
    static func label(forImage item: ClipboardItem) -> String? {
        if let uti = item.resolvedImageUTI, let known = byUTI[uti] { return known }
        let ext = (item.imageFilename as NSString?)?.pathExtension ?? ""
        return label(extension: ext, uti: item.resolvedImageUTI)
    }

    /// A text clip's kind, so the **Kind** row is present on every clip
    /// rather than only the ones with a file format.
    ///
    /// Plain vs rich is the one thing here that is not already on screen, and
    /// it is worth a row: it says whether pasting this clip will carry its
    /// formatting. The rest name the detected `ContentKind` in the singular
    /// noun a person would use, which is a near-repeat of the header — the
    /// price of the row being in the same place on every clip instead of
    /// appearing and disappearing as the selection moves.
    static func label(forText item: ClipboardItem) -> String? {
        switch item.displayKind {
        case .link:     return "Link"
        case .email:    return "Email address"
        case .phone:    return "Phone number"
        case .color:    return "Color"
        case .code:     return "Code"
        case .richText: return "Rich text"
        case .text:     return item.rtfFilename == nil ? "Plain text" : "Rich text"
        // Reached only if a text-typed clip is somehow classified as image or
        // file; the caller routes those to the format lookups above.
        case .image, .file: return nil
        }
    }

    /// A file clip's format.
    ///
    /// A multi-file copy gets one answer only when every file in it agrees;
    /// a mixed batch says so rather than describing it by whichever file
    /// happened to be first, which would be a quietly wrong label on the
    /// other files.
    static func label(forFile attachment: FileAttachment) -> String? {
        let names = [attachment.originalName] + attachment.additionalNames
        // `FileAttachment.uti` is derived from the *first* file's extension
        // (see `ClipboardStore.captureFiles`), so it only describes the whole
        // attachment when there is one file in it. Handing it to every name in
        // a multi-file copy would label a batch of mixed files after whichever
        // one happened to be first.
        guard names.count > 1 else {
            return label(extension: (names[0] as NSString).pathExtension, uti: attachment.uti)
        }
        let labels = names.map { label(extension: ($0 as NSString).pathExtension, uti: nil) }
        guard let first = labels.first else { return nil }
        return labels.contains(where: { $0 != first }) ? "Multiple types" : first
    }

    /// The whole resolution order for one file: the common-name table, then
    /// the system's description for the UTI Klip stored, then for the
    /// extension, then the extension itself.
    static func label(extension ext: String, uti: String?) -> String? {
        if let uti, let known = byUTI[uti] { return known }
        let key = ext.lowercased()
        if let known = byExtension[key] { return known }
        if let uti, let described = UTType(uti)?.localizedDescription {
            return sentenceCased(described)
        }
        guard !key.isEmpty else { return nil }
        if let described = UTType(filenameExtension: key)?.localizedDescription {
            return sentenceCased(described)
        }
        return "\(ext.uppercased()) file"
    }

    /// System descriptions arrive in mixed case ("PNG image", but also
    /// "rich text (RTF)" and "folder"). Only the first character is touched,
    /// so "PDF", "Microsoft Word" and the like keep their capitals.
    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Formats Klip stores images as, keyed by the UTI it stores them under
    /// (`ClipboardItem.uti(forExtension:)`), plus the handful of file UTIs
    /// that have no extension to look up.
    private static let byUTI: [String: String] = [
        "public.jpeg": "JPEG image",
        "public.png": "PNG image",
        "public.heic": "HEIC image",
        "com.compuserve.gif": "GIF image",
        "public.webp": "WebP image",
        "public.tiff": "TIFF image",
        "public.folder": "Folder",
    ]

    /// Common file formats under the name people use for them.
    private static let byExtension: [String: String] = [
        // Images
        "jpg": "JPEG image", "jpeg": "JPEG image", "png": "PNG image",
        "heic": "HEIC image", "heif": "HEIC image", "gif": "GIF image",
        "webp": "WebP image", "tiff": "TIFF image", "tif": "TIFF image",
        "bmp": "BMP image", "svg": "SVG image", "avif": "AVIF image",
        "ico": "Icon", "icns": "Icon",

        // Documents
        "pdf": "PDF document",
        "doc": "Word document", "docx": "Word document",
        "xls": "Excel spreadsheet", "xlsx": "Excel spreadsheet", "xlsm": "Excel spreadsheet",
        "ppt": "PowerPoint presentation", "pptx": "PowerPoint presentation",
        "pages": "Pages document", "numbers": "Numbers spreadsheet", "key": "Keynote presentation",
        "odt": "OpenDocument text", "ods": "OpenDocument spreadsheet", "odp": "OpenDocument presentation",
        "epub": "EPUB book",
        "txt": "Plain text", "text": "Plain text", "log": "Log file",
        "rtf": "Rich text", "rtfd": "Rich text",
        "md": "Markdown", "markdown": "Markdown",
        "csv": "CSV spreadsheet", "tsv": "TSV spreadsheet",

        // Archives and packages
        "zip": "ZIP archive", "rar": "RAR archive", "7z": "7-Zip archive",
        "tar": "TAR archive", "gz": "Gzip archive", "tgz": "Gzip archive",
        "bz2": "Bzip2 archive", "xz": "XZ archive",
        "dmg": "Disk image", "iso": "Disc image", "pkg": "Installer package",
        "app": "Application",

        // Audio and video
        "mp3": "MP3 audio", "m4a": "M4A audio", "wav": "WAV audio",
        "aac": "AAC audio", "flac": "FLAC audio", "aiff": "AIFF audio", "aif": "AIFF audio",
        "mp4": "MP4 video", "m4v": "MP4 video", "mov": "QuickTime video",
        "avi": "AVI video", "mkv": "MKV video", "webm": "WebM video",

        // Code and data
        "json": "JSON", "xml": "XML", "yml": "YAML", "yaml": "YAML",
        "html": "HTML", "htm": "HTML", "css": "CSS",
        "js": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript",
        "py": "Python", "rb": "Ruby", "go": "Go", "rs": "Rust", "php": "PHP",
        "swift": "Swift", "java": "Java", "kt": "Kotlin",
        "c": "C source", "h": "C header", "cpp": "C++ source", "cc": "C++ source",
        "m": "Objective-C source", "mm": "Objective-C++ source",
        "sh": "Shell script", "zsh": "Shell script", "bash": "Shell script",
        "sql": "SQL", "toml": "TOML", "ini": "Config file", "plist": "Property list",
    ]
}
