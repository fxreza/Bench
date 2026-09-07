import SwiftUI
import AppKit

/// The "Show QR Code" card: the focused clip as a QR code, big enough to scan
/// off the screen with a phone.
///
/// Opened by ⌘K, the preview pane's `qrcode` icon or the row context menu, and
/// dismissed by Esc through `HistoryViewModel.keyEscape()`'s prompt layer like
/// every other card. It is a card rather than a popover because the history
/// panel closes the moment it resigns key.
///
/// A clip with nothing encodable — an image, a file, an empty or an
/// over-long clip — still opens the card, which then says why rather than
/// leaving the key looking broken. `QRCodeService` owns both answers.
struct QRCodePrompt: View {
    @ObservedObject var viewModel: HistoryViewModel

    /// How big the code itself is drawn. The card is this plus its 12pt white
    /// quiet zone and `PromptCard`'s own padding.
    ///
    /// 320, not the 220 this shipped with, because the cap moved to the
    /// format's ceiling of 2,331 bytes: that is a 179×179 grid, and at 220pt
    /// each module would be 1.23pt — a wall of hairlines a phone has to be
    /// held against the glass to read. At 320 the same grid draws at 1.79pt
    /// per module, which is exactly the density a 1,000-byte code had at 220.
    /// Raising the cap without growing the code is what this constant exists
    /// to prevent.
    static let codeSize: CGFloat = 320

    /// Rendered once per payload rather than per redraw: generating and
    /// scaling the code is CoreImage work, and the card redraws on every
    /// hover inside it.
    @State private var rendered: NSImage?
    @State private var renderedPayload: String?

    private var payload: Result<String, QRCodeService.Unavailable>? { viewModel.qrPayload }

    var body: some View {
        PromptCard(width: Self.codeSize + 24, onDismiss: { viewModel.cancelQRCode() }) {
            Label("QR Code", systemImage: "qrcode")
                .font(.klip(.sidebarTitle))

            switch payload {
            case .success(let string):
                code(for: string)
            case .failure(let reason):
                unavailable(reason)
            case nil:
                unavailable(.empty)
            }
        }
    }

    // MARK: - Has a code

    @ViewBuilder
    private func code(for string: String) -> some View {
        // Always on white with a margin around it, in both appearances: a QR
        // code is read as dark modules on a light quiet zone, and a scanner
        // handed an inverted or edge-to-edge one has to work for it.
        Group {
            if let image = rendered {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Color.white
            }
        }
        .frame(width: Self.codeSize, height: Self.codeSize)
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: string) { render(string) }

        Text(subject(for: string))
            .font(.klip(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)

        Text(hint)
            .font(.klip(.caption))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
            Spacer()
            PromptButton(title: "Copy Image", isProminent: false) {
                if let image = rendered { viewModel.copyQRImage(image) }
            }
            .disabled(rendered == nil)
            PromptButton(title: "Save PNG…", isProminent: false) {
                if let image = rendered { viewModel.saveQRImage(image) }
            }
            .disabled(rendered == nil)
            PromptButton(title: "Done", isProminent: true) {
                viewModel.cancelQRCode()
            }
        }
    }

    /// One line of what the phone will receive, so it is obvious which clip is
    /// on screen when the card covers the list.
    private func subject(for string: String) -> String {
        let flattened = string
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let clipped = flattened.count > 90 ? String(flattened.prefix(90)) + "…" : flattened
        return "\(clipped)  ·  \(QRCodeService.byteCount(string)) bytes"
    }

    /// What actually happens on the phone, which is not the same for every
    /// kind — a link opens, plain text has to be copied out of the scanner.
    private var hint: String {
        switch viewModel.qrTarget?.displayKind {
        case .link:
            return "Point your phone's camera at it - it will offer to open the link."
        case .email:
            return "Point your phone's camera at it - it will offer to write to this address."
        case .phone:
            return "Point your phone's camera at it - it will offer to call the number."
        default:
            return "Point your phone's camera at it to read the text, then copy it from there."
        }
    }

    // MARK: - Has no code

    @ViewBuilder
    private func unavailable(_ reason: QRCodeService.Unavailable) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "qrcode.viewfinder")
                .foregroundStyle(.tertiary)
            Text(reason.reason)
                .font(.klip(.preview))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            PromptButton(title: "Done", isProminent: true) {
                viewModel.cancelQRCode()
            }
        }
    }

    // MARK: - Rendering

    private func render(_ string: String) {
        guard renderedPayload != string else { return }
        renderedPayload = string
        // 2x the drawn size, so the modules land on whole Retina pixels.
        rendered = QRCodeService.image(for: string, pixelSize: Self.codeSize * 2)
    }
}
