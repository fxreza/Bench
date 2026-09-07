import AppKit
import BenchCore

/// One borderless, non-activating panel covering a single display while a
/// capture is in progress. It shows that display's frozen bitmap, so the
/// desktop underneath can keep moving without the user noticing.
///
/// The level is `.screenSaver` on purpose: `CGShieldingWindowLevel()` sits
/// above everything including sheets, which would hide the "discard changes"
/// alert and the Save panel.
final class OverlayPanel: NSPanel {

    let frozen: FrozenScreen
    let overlayView: OverlayView

    init(frozen: FrozenScreen, controller: OverlayController) {
        self.frozen = frozen
        overlayView = OverlayView(frozen: frozen, controller: controller)
        super.init(contentRect: frozen.screenFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        worksWhenModal = true
        acceptsMouseMovedEvents = true
        appearance = AppearanceSettings.shared.colorScheme.nsAppearance
        contentView = overlayView
        setFrame(frozen.screenFrame, display: false)
        overlayView.frame = CGRect(origin: .zero, size: frozen.screenFrame.size)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape anywhere cancels the whole overlay.
    override func cancelOperation(_ sender: Any?) { overlayView.escapePressed() }

    /// Releases the frozen bitmap and the chrome.
    func teardown() {
        overlayView.teardown()
        orderOut(nil)
        contentView = nil
        close()
    }
}
