import AppKit

/// Small HUD shown when a paste falls back to clipboard-only because Bench
/// lacks Accessibility access. Styled after the standalone Klip's update
/// toast: a borderless, non-activating `NSPanel` with an
/// `NSVisualEffectView` HUD material, fading in, auto-dismissing after a few
/// seconds. `KlipFeature` rate-limits calls to `show` to once per 60 s and
/// points the button at Bench's Permissions pane.
final class AccessibilityToast {
    static let shared = AccessibilityToast()
    private init() {}

    private var window: NSPanel?

    func show(onOpenPermissions: @escaping () -> Void) {
        dismiss()

        let w: CGFloat = 300
        let h: CGFloat = 118

        // NSPanel with .nonactivatingPanel never touches app activation state,
        // so it can't trigger the accessory-app-with-no-windows termination
        // path.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.alphaValue = 0
        window = panel

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let icon = NSImageView(frame: NSRect(x: 16, y: h - 42, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "accessibility", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        icon.contentTintColor = .white
        blur.addSubview(icon)

        let message = NSTextField(wrappingLabelWithString: "Copied. To paste automatically, give Bench Accessibility access.")
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .white
        message.backgroundColor = .clear
        message.isBezeled = false
        message.isEditable = false
        message.frame = NSRect(x: 44, y: 40, width: w - 60, height: 54)
        blur.addSubview(message)

        let button = NSButton(title: "Open Permissions…", target: self, action: #selector(openTapped))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.frame = NSRect(x: 16, y: 12, width: w - 32, height: 24)
        blur.addSubview(button)

        self.onOpenPermissions = onOpenPermissions

        positionBottomRight(panel)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }

        // Auto-dismiss after 6 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.dismiss()
        }
    }

    private var onOpenPermissions: (() -> Void)?

    private func positionBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 20)
        panel.setFrameOrigin(origin)
    }

    @objc private func openTapped() {
        let callback = onOpenPermissions
        dismiss()
        callback?()
    }

    func dismiss() {
        guard let window else { return }
        self.window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.close()
        })
    }
}
