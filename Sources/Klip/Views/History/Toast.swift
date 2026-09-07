import SwiftUI
import AppKit

/// Bottom-of-content transient message (currently: "N locked clips were not
/// deleted"). Owns its own show/hide animation so the call site in
/// `HistoryContentView` stays a single `.overlay(alignment: .bottom)` line -
/// this view renders nothing when `toast` is `nil`.
///
/// State (`HistoryViewModel.toast`, `ToastMessage`) and the 3s auto-clear live
/// in `HistoryViewModel` / `HistoryViewModel+Lock.swift`.
struct ToastOverlay: View {
    let toast: HistoryViewModel.ToastMessage?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        Group {
            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.systemImage)
                        .foregroundStyle(Theme.lockTint)
                    Text(toast.text)
                        .font(.klip(.caption))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: Theme.promptShadow, radius: 12, y: 4)
                .padding(.bottom, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.01) : Theme.promptSpring, value: toast)
    }
}
