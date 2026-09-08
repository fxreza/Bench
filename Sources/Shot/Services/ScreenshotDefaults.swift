import Foundation

/// Mirrors macOS's own screenshot preferences (`defaults read com.apple.screencapture`)
/// so Snapper saves where, how and under the name the user already configured
/// for ⌘⇧3/⌘⇧4.
nonisolated enum ScreenshotDefaults {

    /// What Enter does: write a file, or put the image on the clipboard.
    enum Target: String {
        case file
        case clipboard
    }

    static let domain = "com.apple.screencapture"

    /// File extensions macOS accepts for the `type` key, normalised to the
    /// extension we actually write.
    static let supportedTypes: [String: String] = [
        "png": "png",
        "jpg": "jpg",
        "jpeg": "jpg",
        "heic": "heic",
        "tiff": "tiff",
        "tif": "tiff",
        "pdf": "pdf",
    ]

    static let defaultBaseName = "Screenshot"
    static let defaultExtension = "png"

    /// Longest app name we are willing to put in a file name.
    static let maxSourceNameLength = 40

    /// macOS's own screenshot timestamp format. Deliberately locale-independent.
    static let dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: domain) }

    private static func rawString(_ key: String) -> String? {
        guard let value = defaults?.object(forKey: key) else { return nil }
        if let s = value as? String { return s }
        return String(describing: value)
    }

    private static func rawBool(_ key: String, default fallback: Bool) -> Bool {
        guard let d = defaults, d.object(forKey: key) != nil else { return fallback }
        return d.bool(forKey: key)
    }

    // MARK: - Values

    /// `target`: "clipboard" -> `.clipboard`, anything else (or unset) -> `.file`.
    static var target: Target { parse(target: rawString("target")) }

    /// `location`, tilde-expanded. Falls back to ~/Desktop when unset or not a directory.
    static var saveDirectory: URL { expand(location: rawString("location")) }

    /// `type`, lowercased and normalised; unsupported values fall back to png.
    static var fileType: String { parse(fileType: rawString("type")) }

    /// `include-date` (default true).
    static var includeDate: Bool { rawBool("include-date", default: true) }

    /// `name` (default "Screenshot").
    static var baseName: String {
        let raw = rawString("name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultBaseName : raw
    }

    /// `disable-shadow` (default false).
    static var disableShadow: Bool { rawBool("disable-shadow", default: false) }

    /// `show-thumbnail` (default true). Not used yet.
    static var showThumbnail: Bool { rawBool("show-thumbnail", default: true) }

    // MARK: - Pure helpers (testable)

    /// "clipboard" -> `.clipboard`, everything else -> `.file`.
    static func parse(target raw: String?) -> Target {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == Target.clipboard.rawValue ? .clipboard : .file
    }

    /// Normalises the `type` key to an extension we can actually write.
    static func parse(fileType raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedTypes[value] ?? defaultExtension
    }

    /// Tilde-expands `location` and validates it is a directory; otherwise ~/Desktop.
    static func expand(location raw: String?) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)

        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return desktop }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return desktop }
        let url = URL(fileURLWithPath: expanded, isDirectory: true)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return desktop
        }
        return url
    }

    /// e.g. "Screenshot 2026-09-03 at 10.45.47.png", or "Screenshot.png" when
    /// `include-date` is off.
    static func filename(date: Date, ext: String, includeDate: Bool, baseName: String) -> String {
        let name = baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultBaseName : baseName
        let suffix = ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultExtension : ext
        guard includeDate else { return "\(name).\(suffix)" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = dateFormat
        return "\(name) \(formatter.string(from: date)).\(suffix)"
    }

    /// Turns an app's display name into something safe to use as the base of a
    /// file name: no path separators, no ":" (Finder shows it as "/"), no
    /// leading dots (that would hide the file), trimmed, and capped at
    /// `maxSourceNameLength` characters. `nil` when nothing usable is left, so
    /// the caller falls back to the macOS base name.
    static func sanitized(sourceAppName raw: String?) -> String? {
        guard let raw else { return nil }
        var name = raw
        for bad in ["/", ":"] { name = name.replacingOccurrences(of: bad, with: " ") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > maxSourceNameLength {
            name = String(name.prefix(maxSourceNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    // MARK: - Destination

    /// The next free file URL in `directory` (default: the user's screenshot
    /// folder). Existing names get " (2)", " (3)"... appended, exactly like macOS.
    ///
    /// `sourceAppName` replaces the macOS base name when it is known and
    /// usable, so a capture of IINA is saved as
    /// "IINA 2026-09-07 at 14.03.10.png". Callers pass nil when the
    /// "Name files after the captured app" setting is off.
    static func nextFileURL(in directory: URL? = nil,
                            ext: String? = nil,
                            date: Date = Date(),
                            sourceAppName: String? = nil) -> URL {
        let dir = directory ?? saveDirectory
        let suffix = parse(fileType: ext ?? fileType)
        let base = filename(date: date,
                            ext: suffix,
                            includeDate: includeDate,
                            baseName: sanitized(sourceAppName: sourceAppName) ?? baseName)

        var candidate = dir.appendingPathComponent(base)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let stem = (base as NSString).deletingPathExtension
        var counter = 2
        repeat {
            candidate = dir.appendingPathComponent("\(stem) (\(counter)).\(suffix)")
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path) && counter < 10_000
        return candidate
    }
}
