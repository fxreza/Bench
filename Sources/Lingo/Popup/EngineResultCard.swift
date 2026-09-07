import SwiftUI
import BenchCore

/// One engine's stacked result card: badge header with hover-revealed
/// actions, then the translation / skeleton / error for that engine.
struct EngineResultCard: View {
    let card: EngineCardState
    @ObservedObject var controller: PopupController
    /// Whether siblings are visible — a lone card renders uncapped.
    let capLongText: Bool
    let textScale: Double
    /// 1.0 or 1.35 (Settings > Appearance > larger controls).
    let controlScale: Double
    @Binding var draggingEngine: EngineID?

    @ObservedObject private var settings = SettingsStore.shared

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
        // The panel is movable-by-background; without this, dragging a badge
        // to reorder moves the whole window instead. Blocking window-drag
        // inside the card lets the reorder drag (and text selection) win;
        // the padding around the cards still drags the window.
        .background(WindowDragBlocker())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Hide for Now") { controller.hide(engine: card.id) }
            Button("Disable \(card.id.displayName) Permanently") {
                controller.disablePermanently(engine: card.id)
            }
            Divider()
            Button("Copy") { controller.copy(engine: card.id) }
            Button("Retry") { controller.retry(engine: card.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // The badge doubles as the drag handle for reordering cards —
            // dragging the card body would fight text selection.
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10 * controlScale))
                    .foregroundColor(.secondary.opacity(isHovering ? 0.8 : 0.3))
                Text(card.id.displayName)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .help("Drag to reorder engines")
            .onDrag {
                draggingEngine = card.id
                return NSItemProvider(object: card.id.rawValue as NSString)
            }

            Spacer()

            // Present at all times, revealed by opacity — conditional
            // insertion would reflow the header on every hover.
            HStack(spacing: 12) {
                if card.status.isSuccess {
                    Button(action: { controller.copy(engine: card.id) }) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 20 * controlScale, height: 20 * controlScale)
                    }
                    .help("Copy this translation")
                    Button(action: { controller.speak(engine: card.id) }) {
                        Image(systemName: "speaker.wave.2")
                            .frame(width: 20 * controlScale, height: 20 * controlScale)
                    }
                    .help("Speak this translation")
                }
                Button(action: { controller.hide(engine: card.id) }) {
                    Image(systemName: "xmark")
                        .frame(width: 20 * controlScale, height: 20 * controlScale)
                }
                .help("Hide \(card.id.displayName) for this session")
            }
            .buttonStyle(.plain)
            .font(.system(size: 14 * controlScale))
            .foregroundColor(.secondary)
            .opacity(isHovering ? 1 : 0)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private var content: some View {
        switch card.status {
        case .loading:
            SkeletonLines(estimatedFor: controller.sourceText)

        case .success(let result):
            DirectionalText(
                text: result.translatedText,
                languageCode: controller.targetCode,
                font: .system(size: 16 * textScale),
                lineLimit: capLongText && !card.isExpanded ? 6 : nil)

            if capLongText, result.translatedText.count > 280 {
                Button(card.isExpanded ? "Show less" : "Show more") {
                    controller.toggleExpanded(card.id)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }

            if settings.showTransliteration, let transliteration = result.transliteration {
                // Romanization is Latin script — never inherits RTL layout.
                Text(transliteration)
                    .font(.system(size: 12 * textScale))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            }

            if !result.dictionary.isEmpty {
                dictionarySection(result.dictionary)
            }

        case .failure(let error):
            failureRow(error)
        }
    }

    @ViewBuilder
    private func failureRow(_ error: TranslationError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                // Orange, not red: three red cards reads as catastrophe.
                .foregroundColor(.orange)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            if case .notConfigured = error {
                Button("Add API Key…") { BenchSettings.open(.feature("lingo")) }
                    .controlSize(.small)
            } else if case .modelBusy = error {
                // Retrying a model Google has no capacity for just repeats the
                // wait; the useful action is switching model.
                Button("Change Model…") { BenchSettings.open(.feature("lingo")) }
                    .controlSize(.small)
            } else {
                Button("Retry") { controller.retry(engine: card.id) }
                    .controlSize(.small)
            }
        }
    }

    /// Google-Translate-style dictionary, collapsed by default and shown
    /// under the engine that provided it — merging across engines would mean
    /// reconciling part-of-speech taxonomies and destroying provenance.
    private func dictionarySection(_ dictionary: [DictionaryEntry]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(dictionary.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.partOfSpeech.capitalized)
                            .font(.caption.bold())
                            .foregroundColor(.accentColor)
                        ForEach(Array(entry.meanings.prefix(6).enumerated()), id: \.offset) { _, meaning in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(meaning.word)
                                    .font(.system(size: 13 * textScale, weight: .medium))
                                    .environment(
                                        \.layoutDirection,
                                        LanguageCatalog.isRTL(controller.targetCode)
                                            ? .rightToLeft : .leftToRight)
                                if !meaning.reverseTranslations.isEmpty {
                                    Text(meaning.reverseTranslations.prefix(4).joined(separator: ", "))
                                        .font(.system(size: 12 * textScale))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Definitions (\(dictionary.reduce(0) { $0 + $1.meanings.count }))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// AppKit escape hatch: an invisible backing view that answers "no" when the
/// window asks whether a mouse-down here may drag the window. SwiftUI text
/// and drag gestures render on the hosting view, which normally says yes for
/// every empty spot — this wins the hit test for the area it backs.
struct WindowDragBlocker: NSViewRepresentable {
    final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ view: BlockerView, context: Context) {}
}

/// Shimmer placeholder sized from the source length so the card's height
/// barely changes when the real text lands.
struct SkeletonLines: View {
    let lineCount: Int

    init(estimatedFor source: String) {
        lineCount = min(max(source.count / 60 + 1, 1), 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<lineCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 12)
                    .frame(maxWidth: index == lineCount - 1 ? 140 : .infinity)
            }
        }
        .padding(.vertical, 2)
    }
}
