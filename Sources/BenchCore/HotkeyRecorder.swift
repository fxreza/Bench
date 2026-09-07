// Ported from Transi's Shortcuts/HotkeyRecorder.swift (MIT), by way of Klip's
// Views/Settings/HotkeyRecorder.swift, from Clipfield's HotkeyRecorder (MIT,
// Copyright 2026 Alex Jolley).

import AppKit
import SwiftUI

/// A click-to-record control that captures a key + modifier combination and
/// reports it via `onRecord`. Escape cancels an in-progress recording, so a
/// bare Escape can never be recorded. Delete/Backspace while recording
/// clears the binding (`onClear`), when a clear handler is given.
public struct HotkeyRecorder: NSViewRepresentable {
    public var display: String
    public var isRebindable: Bool = true
    public var onRecord: (KeyBinding) -> Void
    public var onClear: (() -> Void)? = nil

    public init(display: String, isRebindable: Bool = true, onRecord: @escaping (KeyBinding) -> Void, onClear: (() -> Void)? = nil) {
        self.display = display
        self.isRebindable = isRebindable
        self.onRecord = onRecord
        self.onClear = onClear
    }

    public func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.display = display
        view.isRebindable = isRebindable
        view.onRecord = onRecord
        view.onClear = onClear
        return view
    }

    public func updateNSView(_ view: RecorderView, context: Context) {
        view.isRebindable = isRebindable
        view.onRecord = onRecord
        view.onClear = onClear
        if !view.isRecording {
            view.display = display
            view.needsDisplay = true
        }
    }
}

public final class RecorderView: NSView {
    public var display: String = ""
    public var isRebindable: Bool = true {
        didSet { needsDisplay = true }
    }
    public var isRecording = false {
        didSet { needsDisplay = true }
    }
    public var onRecord: ((KeyBinding) -> Void)?
    public var onClear: (() -> Void)?

    private static let textFontSize: CGFloat = 12
    private static let cornerRadius: CGFloat = 6

    public override var acceptsFirstResponder: Bool { isRebindable }
    public override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        let accent = NSColor.controlAccentColor
        let fill: NSColor
        if isRecording {
            fill = accent.withAlphaComponent(0.18)
        } else if isRebindable {
            fill = .controlBackgroundColor
        } else {
            fill = NSColor.controlBackgroundColor.withAlphaComponent(0.5)
        }
        fill.setFill()
        path.fill()

        let stroke = isRecording ? accent : NSColor.separatorColor.withAlphaComponent(isRebindable ? 1 : 0.5)
        stroke.setStroke()
        path.stroke()

        let text: String
        if !isRebindable {
            text = display
        } else if isRecording {
            text = "Press shortcut…"
        } else {
            text = display.isEmpty ? "Click to record" : display
        }

        let color: NSColor
        if isRecording {
            color = accent
        } else if isRebindable {
            color = display.isEmpty ? .secondaryLabelColor : .labelColor
        } else {
            color = .tertiaryLabelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: RecorderView.textFontSize, weight: .medium),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    public override func mouseDown(with event: NSEvent) {
        guard isRebindable else { return }
        isRecording = true
        window?.makeFirstResponder(self)
    }

    /// What a key press does to an in-progress recording. A pure function
    /// so the rules (Escape cancels, Delete clears, a combination without
    /// ⌘/⌃/⌥ is rejected) are unit-testable without a window.
    public enum RecordingOutcome: Equatable {
        case cancel
        case clear
        case reject
        case record(KeyBinding)
    }

    public static func outcome(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> RecordingOutcome {
        if keyCode == 53 { return .cancel }
        let mods = KeyModifiers(eventFlags: flags.intersection(.deviceIndependentFlagsMask))
        if (keyCode == 51 || keyCode == 117) && mods.isEmpty { return .clear }
        // Require at least one of ⌘⌃⌥ so a rebind cannot collide with
        // ordinary typing (shift alone is not enough).
        guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
            return .reject
        }
        return .record(KeyBinding(keyCode: keyCode, modifiers: mods))
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        switch RecorderView.outcome(keyCode: event.keyCode, flags: event.modifierFlags) {
        case .cancel:
            isRecording = false
        case .clear:
            if let onClear {
                onClear()
                isRecording = false
                window?.makeFirstResponder(nil)
            } else {
                NSSound.beep()
            }
        case .reject:
            NSSound.beep()
        case .record(let binding):
            onRecord?(binding)
            isRecording = false
            window?.makeFirstResponder(nil)
        }
    }

    public override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }
}
