import AppKit
import SwiftUI

/// The search field used by both language lists (Settings > Languages and the
/// popup's language pickers).
///
/// It wraps `NSSearchField` rather than using a plain SwiftUI `TextField` for
/// two reasons, both of which were real bugs:
///
/// 1. A `TextField` inside a grouped `Form` renders borderless on macOS, so
///    the Settings search field read as a heading. Users typed into it without
///    realising it was a field, the list filtered down to nothing, and it
///    looked as though their enabled languages had been wiped.
/// 2. The shared field editor applies smart substitutions by default, so two
///    spaces became ". " — a query that matches no language at all. The field
///    editor is reconfigured here to leave typed text alone.
///
/// `NSSearchField` also brings the magnifier and the clear button for free, so
/// a query is always visible and always one click from being undone.
struct LanguageSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = PlainSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    /// Turns off every substitution the shared field editor would otherwise
    /// apply — period-for-double-space above all, which is what silently
    /// emptied the language list.
    private final class PlainSearchField: NSSearchField {
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if let editor = currentEditor() as? NSTextView {
                // Zeroing the checking types is what actually stops period
                // substitution (there is no boolean for it); the individual
                // flags below cover the substitutions that have one.
                editor.enabledTextCheckingTypes = 0
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isAutomaticDataDetectionEnabled = false
                editor.isAutomaticLinkDetectionEnabled = false
            }
            return accepted
        }
    }
}
