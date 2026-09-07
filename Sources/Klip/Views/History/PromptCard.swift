// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley) — the inline prompt
// chrome in UI/Overlay/OverlayView.swift.

import SwiftUI

/// A modal card floating over a dimming scrim, used for every in-panel
/// confirmation.
///
/// The history window is a borderless `NSPanel` that closes as soon as it
/// resigns key, so an `NSAlert` or a SwiftUI `.alert` would dismiss the whole
/// window behind the dialog. Everything that would otherwise be an alert is
/// rendered inside the panel instead.
///
/// Esc is **not** wired here: it is routed through the existing chain in
/// `HistoryViewModel.keyEscape()` (edit mode → tag input → prompt → close) so
/// there is one place that decides what Esc unwinds.
struct PromptCard<Content: View>: View {
    /// Fixed content width; the card sizes to fit vertically.
    var width: CGFloat = 300
    /// Tapping the scrim dismisses, matching Clipfield.
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Theme.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(width: width)
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.promptCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.promptCornerRadius)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Theme.promptShadow, radius: Theme.promptShadowRadius, y: Theme.promptShadowY)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }
}
