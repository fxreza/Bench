import AppKit
import UniformTypeIdentifiers

/// Copy / Save / Save As / default action shared by the overlay and the editor.
@MainActor
enum EditorActions {
    static func flattened(_ document: AnnotationDocument) -> CGImage { ImageFlattener.flatten(document) }

    /// ⌘C: puts the flattened image on the clipboard, in the format the
    /// capture shortcut asked for.
    static func copy(_ document: AnnotationDocument) {
        ImageExporter.copyToPasteboard(flattened(document),
                                       pixelScale: document.pixelScale,
                                       format: document.outputFormat?.imageFormat ?? .png,
                                       quality: lossyQuality)
        playCaptureSound()
    }

    /// Puts recognized text on the clipboard as plain text. Nothing else is
    /// written - no image, no file - so a clipboard manager only ever sees the
    /// string.
    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        playCaptureSound()
    }

    /// The compression Image I/O should use, read only when the destination
    /// format is lossy. One global value, shared by every shortcut set to JPG.
    static var lossyQuality: CGFloat { SettingsManager.shared.jpegQualityFraction }

    /// ⌘S: saves into the macOS screenshot folder with the macOS file name
    /// pattern, in the format the capture shortcut asked for.
    @discardableResult
    static func save(_ document: AnnotationDocument) -> URL? {
        let url = ScreenshotDefaults.nextFileURL(ext: document.outputFormat?.fileExtension)
        do {
            try ImageExporter.write(flattened(document),
                                    pixelScale: document.pixelScale,
                                    to: url,
                                    quality: lossyQuality)
            playCaptureSound()
            return url
        } catch {
            presentError("Could not save the screenshot.", error)
            return nil
        }
    }

    /// ⇧⌘S: asks where to save.
    static func saveAs(_ document: AnnotationDocument, for window: NSWindow?, completion: ((URL?) -> Void)? = nil) {
        let panel = NSSavePanel()
        // The document's own format goes first, so the panel opens on it.
        var types: [UTType] = [.png, .jpeg, .tiff, .heic]
        if let preferred = document.outputFormat?.imageFormat.utType, let i = types.firstIndex(of: preferred) {
            types.remove(at: i)
            types.insert(preferred, at: 0)
        }
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.directoryURL = ScreenshotDefaults.saveDirectory
        panel.nameFieldStringValue = ScreenshotDefaults.nextFileURL(ext: document.outputFormat?.fileExtension).lastPathComponent
        let image = flattened(document)
        let scale = document.pixelScale
        let quality = lossyQuality
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion?(nil); return }
            do {
                try ImageExporter.write(image, pixelScale: scale, to: url, quality: quality)
                playCaptureSound()
                completion?(url)
            } catch {
                presentError("Could not save the screenshot.", error)
                completion?(nil)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// Enter: what macOS itself would do with a screenshot (copy or save to the default folder).
    @discardableResult
    static func performDefault(_ document: AnnotationDocument) -> URL? {
        switch ScreenshotDefaults.target {
        case .clipboard: copy(document); return nil
        case .file: return save(document)
        }
    }

    static func playCaptureSound() {
        guard SettingsManager.shared.playCaptureSound else { return }
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
            "/System/Library/Sounds/Tink.aiff",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSSound(contentsOfFile: path, byReference: true)?.play()
            return
        }
    }

    static func presentError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Escape on a dirty document: true = discard.
    static func confirmDiscard(for window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Discard your changes?"
        alert.informativeText = "The annotations you added will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Formats a size for the dimension label honoring the px/pt setting.
    static func dimensionString(pointSize: CGSize, pixelScale: CGFloat) -> String {
        if SettingsManager.shared.dimensionsInPixels {
            return "\(Int((pointSize.width * pixelScale).rounded())) × \(Int((pointSize.height * pixelScale).rounded())) px"
        }
        return "\(Int(pointSize.width.rounded())) × \(Int(pointSize.height.rounded())) pt"
    }
}
