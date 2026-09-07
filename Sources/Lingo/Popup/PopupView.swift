import SwiftUI
import UniformTypeIdentifiers
import BenchCore

struct PopupView: View {
    @ObservedObject var controller: PopupController
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var inputFocused: Bool
    @State private var sourceExpanded = false
    @State private var showCopied = false
    /// Engine currently being dragged to a new slot (by its name badge).
    @State private var draggingEngine: EngineID?

    private var scale: Double { settings.popupTextSize }
    /// Control sizing is a discrete toggle (Settings > Appearance), separate
    /// from the text-size slider so enlarging buttons never bloats the text.
    private var ctrl: Double { settings.largePopupControls ? 1.35 : 1.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if let error = controller.popupError {
                fatalErrorView(error)
            } else {
                bodyContent
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(
            minWidth: SettingsStore.minPopupSize.width, maxWidth: .infinity,
            minHeight: SettingsStore.minPopupSize.height, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 8)
        )
        // Accent color and light/dark are app-wide now (BenchCore.AppearanceSettings),
        // not per-popup like Transi's own settings.accentTheme/colorScheme.
        .benchAppearance()
        .onChange(of: controller.focusRequest) {
            // One turn after makeKey(), per the non-activating panel's focus
            // rules; a UUID token re-fires even when already requested once.
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: controller.inputDraft) { controller.draftChanged() }
    }

    // MARK: - Header

    /// Chrome stays LTR always; only text blocks flip for RTL languages.
    private var header: some View {
        HStack(spacing: 6) {
            LanguagePickerButton(
                title: sourceLabel,
                selectedCode: controller.sourceSetting,
                includeAuto: true,
                controller: controller
            ) { code in
                controller.setSource(code)
            }

            Button(action: { controller.swapLanguages() }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13 * ctrl))
                    .frame(width: 22 * ctrl, height: 22 * ctrl)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(controller.effectiveSourceCode == nil)
            .help(controller.effectiveSourceCode == nil
                  ? "Detecting language…" : "Swap languages")
            .keyboardShortcut("s", modifiers: [.command, .shift])

            LanguagePickerButton(
                title: LanguageCatalog.englishName(for: controller.targetCode),
                selectedCode: controller.targetCode,
                includeAuto: false,
                controller: controller
            ) { code in
                controller.retranslate(to: code)
            }

            tonePicker

            Spacer()

            Button(action: { controller.isPinned.toggle() }) {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13 * ctrl))
                    .rotationEffect(.degrees(45))
                    .foregroundColor(pinColor)
                    .frame(width: 22 * ctrl, height: 22 * ctrl)
            }
            .buttonStyle(.plain)
            .help(controller.isImplicitlyPinned
                  ? "Kept open while you type"
                  : "Keep open — clicks outside won't close (⌘P)")
            .keyboardShortcut("p", modifiers: .command)

            Button(action: { controller.close() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14 * ctrl))
                    .foregroundColor(.secondary)
                    .frame(width: 22 * ctrl, height: 22 * ctrl)
            }
            .buttonStyle(.plain)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    @State private var tonePickerOpen = false

    /// Tone selector for the engines that support one (Bing, Gemini). A
    /// popover like the language pickers, and for the same reason: an NSMenu
    /// dismissed by a click in another app would take the whole popup with it.
    private var tonePicker: some View {
        Button(action: { tonePickerOpen.toggle() }) {
            HStack(spacing: 2) {
                Image(systemName: "textformat")
                    .font(.system(size: 11 * ctrl))
                // Standard used to render as a bare icon, which left the
                // control unlabelled in its most common state.
                Text(settings.tone.label)
                Image(systemName: "chevron.down").font(.system(size: 9 * ctrl))
            }
            .font(.system(size: 12 * ctrl))
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .help("Tone — applies to Bing and Gemini")
        .popover(isPresented: $tonePickerOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(TranslationTone.allCases) { tone in
                    Button(action: {
                        tonePickerOpen = false
                        controller.toneChanged(tone)
                    }) {
                        HStack {
                            Text(tone.label)
                            Spacer()
                            if tone == settings.tone {
                                Image(systemName: "checkmark").font(.caption)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
                Text("Google always answers standard.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .frame(width: 170)
            .padding(.vertical, 4)
            .onAppear { controller.isPickerOpen = true }
            .onDisappear { controller.isPickerOpen = false }
        }
    }

    private var pinColor: Color {
        if controller.isPinned { return .accentColor }
        if controller.isImplicitlyPinned { return .accentColor.opacity(0.4) }
        return .secondary
    }

    private var sourceLabel: String {
        if controller.sourceSetting == LanguageCatalog.autoCode {
            if let detected = controller.effectiveSourceCode {
                return "Auto · \(LanguageCatalog.englishName(for: detected))"
            }
            return "Auto"
        }
        return LanguageCatalog.englishName(for: controller.sourceSetting)
    }

    // MARK: - Body

    private var bodyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sourceSection

                if let suggestion = controller.spellingSuggestion {
                    Button(action: {
                        Task { await controller.translateAndDisplay(text: suggestion) }
                    }) {
                        (Text("Did you mean: ").foregroundColor(.secondary)
                            + Text(suggestion).italic().foregroundColor(.accentColor))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                if allEnginesFailed {
                    allFailedBanner
                }

                ForEach(controller.visibleCards) { card in
                    EngineResultCard(
                        card: card,
                        controller: controller,
                        capLongText: controller.visibleCards.count >= 2,
                        textScale: scale,
                        controlScale: ctrl,
                        draggingEngine: $draggingEngine)
                    .onDrop(
                        of: [.plainText],
                        delegate: EngineDropDelegate(
                            target: card.id, dragging: $draggingEngine, controller: controller))
                    .opacity(draggingEngine == card.id ? 0.5 : 1)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch controller.phase {
        case .capturing:
            statusRow("Reading selection…")
        case .recognizing:
            statusRow("Reading screenshot…")
        case .composing:
            composer
        case .ready:
            VStack(alignment: .leading, spacing: 2) {
                DirectionalText(
                    text: controller.sourceText,
                    languageCode: controller.effectiveSourceCode,
                    font: .system(size: 13 * scale),
                    color: .secondary,
                    lineLimit: sourceExpanded ? nil : 3)

                HStack(spacing: 12) {
                    if controller.sourceText.count > 160 {
                        Button(sourceExpanded ? "less" : "more") { sourceExpanded.toggle() }
                    }
                    Button(action: { controller.enterComposing() }) {
                        Image(systemName: "pencil")
                            .frame(width: 20 * ctrl, height: 20 * ctrl)
                    }
                    .help("Edit text (⌘E)")
                    .keyboardShortcut("e", modifiers: .command)
                    Button(action: { controller.speakSource() }) {
                        Image(systemName: "speaker.wave.1")
                            .frame(width: 20 * ctrl, height: 20 * ctrl)
                    }
                    .help("Speak source text")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14 * ctrl))
                .foregroundColor(.secondary)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $controller.inputDraft)
                .font(.system(size: 13 * scale))
                .focused($inputFocused)
                .frame(minHeight: 60, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                )

            Button("Translate  ⌘↩") { controller.submitDraft() }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.small)
                .disabled(controller.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func statusRow(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var allEnginesFailed: Bool {
        let visible = controller.visibleCards
        guard !visible.isEmpty, !controller.isTranslating else { return false }
        return !visible.contains { $0.status.isSuccess }
    }

    private var allFailedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundColor(.orange)
            Text("No engine could translate this.")
                .font(.caption)
            Spacer()
            Button("Retry All") { controller.retryAll() }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private func fatalErrorView(_ error: PopupError) -> some View {
        VStack(spacing: 10) {
            Text(error.message)
                .foregroundColor(.red)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let pane = error.settingsPane {
                Button(pane.buttonTitle) { pane.open() }
            }
            if controller.origin == .selection {
                Button("Type Text Instead…") {
                    controller.showComposing(near: NSEvent.mouseLocation)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: { controller.speak() }) {
                Image(systemName: "speaker.wave.2.fill")
            }
            .help("Speak translation")
            .disabled(!controller.canSpeak)

            HStack(spacing: 0) {
                Button(action: copyPrimary) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                }
                .help(copyHelp)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(controller.primaryText.isEmpty)

                Menu {
                    ForEach(controller.visibleCards.filter(\.status.isSuccess)) { card in
                        Button("Copy \(card.id.displayName)") { controller.copy(engine: card.id) }
                    }
                    if controller.visibleCards.filter(\.status.isSuccess).count > 1 {
                        Button("Copy All (labelled)") { copyAll() }
                    }
                    Button("Copy with Source") { copyWithSource() }
                        .disabled(controller.primaryText.isEmpty)
                } label: {
                    EmptyView()
                }
                .menuStyle(.borderlessButton)
                .frame(width: 14)
            }

            historyButton

            Spacer()

            if let hidden = controller.lastHiddenEngine {
                HStack(spacing: 4) {
                    Text("\(hidden.displayName) hidden")
                        .foregroundColor(.secondary)
                    Button("Undo") { controller.undoHide() }
                    Button("Always") { controller.disablePermanently(engine: hidden) }
                }
                .font(.caption)
                .transition(.opacity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - History

    @State private var historyOpen = false
    @ObservedObject private var history = HistoryStore.shared

    /// A popover like the language pickers, and for the same reason: an
    /// NSMenu dismissed by a click in another app would close the popup too.
    private var historyButton: some View {
        Button(action: { historyOpen.toggle() }) {
            Image(systemName: "clock.arrow.circlepath")
        }
        .help("History")
        .popover(isPresented: $historyOpen, arrowEdge: .bottom) {
            historyContent
                .onAppear { controller.isPickerOpen = true }
                .onDisappear { controller.isPickerOpen = false }
        }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                Text("No history yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(history.entries) { entry in
                            historyRow(entry)
                            Divider().padding(.leading, 10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(width: 320, height: min(CGFloat(history.entries.count) * 46 + 20, 340))

                Divider()
                HStack {
                    Text("\(history.entries.count) of \(HistoryStore.maxEntries)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear History") {
                        history.clear()
                        historyOpen = false
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 6) {
            Button(action: {
                historyOpen = false
                controller.recall(entry)
            }) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.translatedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(entry.sourceText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Translate again")

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.translatedText, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy translation")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var copyHelp: String {
        if let primary = controller.primaryCard {
            return "Copy \(primary.id.displayName) translation (⌘C)"
        }
        return "Copy translation"
    }

    private func copyPrimary() {
        controller.copyTranslation()
        showCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            showCopied = false
        }
    }

    private func copyAll() {
        let lines = controller.visibleCards.compactMap { card -> String? in
            guard case .success(let result) = card.status else { return nil }
            return "\(card.id.displayName): \(result.translatedText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func copyWithSource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "\(controller.sourceText)\n\(controller.primaryText)", forType: .string)
    }
}

// MARK: - Engine drag reorder

/// Live-reorders the card stack while a badge is dragged over another card.
/// The write goes through `PopupController.moveEngine`, i.e. into
/// `SettingsStore.engineOrder`, so the new order is permanent and the
/// Engines tab shows it too.
private struct EngineDropDelegate: DropDelegate {
    let target: EngineID
    @Binding var dragging: EngineID?
    let controller: PopupController

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            controller.moveEngine(dragging, before: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Language picker

/// Popover-based language picker. A popover (not an NSMenu) because
/// dismissing a menu with a click in another app would also fire the popup's
/// global click-outside monitor and close the whole window; the popover binds
/// `controller.isPickerOpen`, which suspends that monitor while open.
private struct LanguagePickerButton: View {
    let title: String
    let selectedCode: String
    let includeAuto: Bool
    @ObservedObject var controller: PopupController
    let onSelect: (String) -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            HStack(spacing: 2) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .font(.system(size: 12 * (settings.largePopupControls ? 1.35 : 1.0)))
            .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 60, maxWidth: 170)
        .fixedSize(horizontal: true, vertical: false)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerContent
                .onAppear { controller.isPickerOpen = true }
                .onDisappear {
                    controller.isPickerOpen = false
                    query = ""
                }
        }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            LanguageSearchField(text: $query, prompt: "Search")
                .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if includeAuto, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        row(code: LanguageCatalog.autoCode, label: "Auto Detect")
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(filteredCodes, id: \.self) { code in
                        row(code: code, label: LanguageCatalog.language(for: code)?.displayName ?? code)
                    }
                    Divider().padding(.vertical, 2)
                    Button(action: {
                        isPresented = false
                        BenchSettings.open(.feature("lingo"))
                    }) {
                        Text("Edit Languages…")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
            .frame(width: 230, height: min(CGFloat(filteredCodes.count) * 28 + 90, 320))
        }
    }

    private var filteredCodes: [String] {
        let codes = settings.enabledLanguages
        // Trimmed: a stray space (or macOS turning a double space into ". ")
        // used to filter the whole list away and read as lost settings.
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return codes }
        return codes.filter {
            guard let lang = LanguageCatalog.language(for: $0) else { return false }
            return lang.englishName.localizedCaseInsensitiveContains(needle)
                || lang.nativeName.localizedCaseInsensitiveContains(needle)
                || lang.code.localizedCaseInsensitiveContains(needle)
        }
    }

    private func row(code: String, label: String) -> some View {
        Button(action: {
            isPresented = false
            onSelect(code)
        }) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                if code == selectedCode {
                    Image(systemName: "checkmark").font(.caption)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}
