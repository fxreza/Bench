import Foundation
import BenchCore

/// Where the popup's source text came from.
enum SourceOrigin {
    case selection, ocr, typed
}

/// The popup's source-side lifecycle. Engine results have their own per-card
/// status; this only tracks how the text itself is being produced.
enum SourcePhase: Equatable {
    /// AX/⌘C selection capture in flight, no text yet.
    case capturing
    /// OCR reading a screenshot.
    case recognizing
    /// The user is typing into the input field.
    case composing
    /// Source text is final; engines may still be in flight.
    case ready
}

enum EngineStatus {
    case loading
    case success(EngineResult)
    case failure(TranslationError)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// One engine's card in the stacked results list.
struct EngineCardState: Identifiable {
    let id: EngineID
    var status: EngineStatus = .loading
    /// Long-text "Show more" toggle; per-card, so expanding one card never
    /// moves its siblings.
    var isExpanded = false
}

/// Whole-popup failure (no text captured, missing permission); replaces the
/// body, unlike per-engine failures which stay inside their card.
struct PopupError {
    let message: String
    let settingsPane: SystemSettingsPane?
}
