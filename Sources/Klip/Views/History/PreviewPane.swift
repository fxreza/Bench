// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley) —
// UI/Overlay/ClipPreviewPane.swift.

import SwiftUI
import AppKit

/// Right-hand detail pane. Replaces `Views/History/DetailPane.swift`.
///
/// Layout follows Clipfield: a kind header with the action cluster, a rich
/// body (image / colour swatch / text / file placeholder), and a metadata
/// footer. Everything Buffer already did is preserved — chunked loading of
/// large text, inline edit mode, OCR, the multi-selection summary and the tag
/// strip with its add-tag input (now part of the footer).
struct PreviewPane: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState.Binding var isTextEditorFocused: Bool
    /// Edit mode's title field. Tracked separately from the body editor so
    /// clicking between the two does not read as "left the editor".
    @FocusState.Binding var isEditTitleFocused: Bool
    @FocusState.Binding var isTagInputFocused: Bool

    /// Matches `SearchBar`'s top padding. 3.0.1 made the pane a full-height
    /// sibling of the sidebar (it used to be boxed between the chip bar and
    /// the action bar), so its header now sits at the top of the window and
    /// has to line up with the search field rather than with a divider.
    static let topPadding: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.selectionCount > 1 {
                multiSelectionHeader
                    .padding(.horizontal, 16)
                    .padding(.top, Self.topPadding)
                    .padding(.bottom, 12)
                ScrollView {
                    MultiSelectionSummary(viewModel: viewModel)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Spacer(minLength: 0)
            } else if let item = viewModel.selectedItem {
                header(for: item)
                    .padding(.horizontal, 16)
                    .padding(.top, Self.topPadding)
                    .padding(.bottom, item.displayTitle == nil || viewModel.isEditing ? 12 : 6)

                if let name = item.displayTitle, !viewModel.isEditing {
                    titleStrip(name, for: item)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                ScrollView {
                    ScrollViewReader { proxy in
                        body(for: item)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id("editArea")
                            .onChange(of: viewModel.isEditing) { _, newValue in
                                if newValue {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation {
                                            proxy.scrollTo("editArea", anchor: .top)
                                        }
                                    }
                                }
                            }
                    }
                }

                Spacer(minLength: 0)

                footer(for: item)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No animation on selection. There used to be
        // `.animation(.easeOut(duration: 0.18), value: viewModel.selectedItem?.id)`
        // here, and it is the reason moving onto an image looked like the pane
        // blinked.
        //
        // Text and image clips render structurally different bodies
        // (`textBody` vs `imageBody`), so SwiftUI does not update the old view
        // — it removes it and inserts the new one. Under an implicit animation
        // that removal and insertion become a cross-fade, so every step onto a
        // clip of a different type faded the whole pane out and back in. On
        // top of that the image itself arrives a frame or two later, off a
        // background decode, so what actually played was: fade out the text,
        // fade in an empty pane, then pop the image in. Any height difference
        // in between — the header wrapping its action icons onto a second row
        // for the kinds that have more of them — slid rather than cut, which
        // is the sideways movement that came with it.
        //
        // A preview pane is not a place where motion carries meaning; it
        // shows whatever is selected, and the selection has already moved.
        // Finder's and Mail's cut too.
    }

    // MARK: - Header

    private var multiSelectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Theme.multiSelectTint)
            Text("\(viewModel.selectionCount) items selected")
                .font(.klip(.sidebarTitle))
                .fontWeight(.semibold)
            Spacer(minLength: 0)
        }
    }

    /// Kind + badges on the left, the action cluster on the right. With nine
    /// possible buttons the row does not always fit a 200pt-wide preview pane,
    /// so it falls back to stacking the actions under the title rather than
    /// wrapping the kind label mid-word.
    private func header(for item: ClipboardItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headerTitle(for: item)
                Spacer(minLength: 6)
                actionIcons(for: item)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    headerTitle(for: item)
                    Spacer(minLength: 0)
                }
                // Centred, not pushed right. On its own line the row is
                // narrower than the pane by whatever the pane happens to be
                // wider than its minimum, and a single trailing spacer put
                // every point of that on the left — so the icons sat hard
                // against the right margin with a visibly bigger gap on the
                // left. Two spacers split the difference, and the margins
                // match at any width (at the pane's minimum there is no
                // slack to split, and the row is flush with both).
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actionIcons(for: item)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func headerTitle(for item: ClipboardItem) -> some View {
        Image(systemName: item.displayKind.systemImage)
            .foregroundStyle(Theme.kindTint(item.displayKind))
        Text(viewModel.isEditing ? "Editing" : item.displayKind.label)
            .font(.klip(.sidebarTitle))
            .fontWeight(.semibold)
            .foregroundStyle(viewModel.isEditing ? Theme.accent : Color.primary)
            .lineLimit(1)
            .fixedSize()

        if item.isFileBacked {
            Text("Large")
                .font(.klip(.badge))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.largeBadgeTint.opacity(0.8)))
                .fixedSize()
        }

        if let size = viewModel.preview(for: item).byteSize, size > 0 {
            Text(viewModel.formattedByteCount(size))
                .font(.klip(.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func actionIcons(for item: ClipboardItem) -> some View {
        // 5E: a trashed clip has two things worth doing to it, and every
        // other icon here would write to `store.items`, where it no longer is.
        if viewModel.isTrashScope {
            trashActionIcons(for: item)
        } else {
            historyActionIcons(for: item)
        }
    }

    private func trashActionIcons(for item: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            iconButton(
                "arrow.uturn.backward",
                tint: Theme.accent,
                help: "Restore to the top of All (\(ShortcutManager.shared.displayString(for: .paste)))"
            ) {
                viewModel.restore(item)
            }

            iconButton("doc.on.doc", tint: .secondary, help: "Copy") {
                viewModel.copy(item)
            }

            iconButton(
                "trash.slash",
                tint: .secondary,
                help: "Delete permanently (\(ShortcutManager.shared.displayString(for: .delete)))"
            ) {
                viewModel.requestPurge(ids: [item.id])
            }
        }
    }

    /// The nine history actions, always all nine, always in this order.
    ///
    /// They used to be built conditionally — no Edit on an image, no Save or
    /// Extract Text on anything but an image — so the row's contents changed
    /// as the selection moved and every icon after the missing one shifted
    /// sideways. Stepping from a text clip to an image slid Pin, Favorite,
    /// Lock and Delete under the pointer, and because the count changed the
    /// row could also wrap onto a second line for one clip and not the next,
    /// moving the preview below it.
    ///
    /// An icon that does not apply to the selected clip is drawn greyed and
    /// disabled instead of being dropped, so the row is the same shape on
    /// every clip and the target you want is always in the same place. The
    /// tooltip on a disabled icon says why it is off.
    private func historyActionIcons(for item: ClipboardItem) -> some View {
        let shortcuts = ShortcutManager.shared
        let canExtract = item.type == .image && item.ocrText == nil

        return HStack(spacing: 12) {
            iconButton(
                "square.and.pencil",
                tint: viewModel.isEditing ? Theme.accent : .secondary,
                help: !item.isEditable
                    ? "Only text clips can be edited"
                    : viewModel.isEditing
                        ? "Stop editing (auto-saved) (\(shortcuts.displayString(for: .edit)) or \(shortcuts.displayString(for: .escape)))"
                        : "Edit item (\(shortcuts.displayString(for: .edit)))",
                enabled: item.isEditable
            ) { viewModel.toggleEditMode() }

            iconButton("doc.on.doc", tint: .secondary, help: "Copy (\(shortcuts.displayString(for: .copy)))") {
                viewModel.copy(item)
            }

            // Every kind can be written to disk — an image in its captured
            // format, text as .txt, files straight through — which is what ⌘S
            // has always done. The icon used to appear for images only, so it
            // was both a moving target and a narrower promise than the key.
            iconButton(
                "arrow.down.to.line",
                tint: .secondary,
                help: "Save to disk (\(shortcuts.displayString(for: .saveToDisk)))"
            ) { viewModel.saveSelectedToDisk() }

            // Sits next to Save to Disk rather than next to Lock: both are
            // ways of getting a clip *out* of Klip, one onto the disk and one
            // onto a phone.
            iconButton(
                "qrcode",
                tint: .secondary,
                help: viewModel.qrUnavailableReason(for: item)
                    ?? "Show QR Code (\(shortcuts.displayString(for: .showQR)))",
                enabled: viewModel.canShowQRCode(for: item)
            ) { viewModel.requestQRCode(id: item.id) }

            iconButton(
                viewModel.isExtractingText ? "ellipsis.circle" : "text.viewfinder",
                tint: .secondary,
                help: item.type != .image
                    ? "Text can only be extracted from images"
                    : item.ocrText != nil
                        ? "Text has already been extracted from this image"
                        : "Extract text from image",
                enabled: canExtract && !viewModel.isExtractingText
            ) {
                Task { @MainActor in await viewModel.extractTextFromSelection() }
            }

            iconButton(
                item.isPinned ? "pin.fill" : "pin",
                tint: item.isPinned ? Theme.pinTint : .secondary,
                help: item.isPinned
                    ? "Unpin (\(shortcuts.displayString(for: .pin)))"
                    : "Pin to top (\(shortcuts.displayString(for: .pin)))"
            ) { viewModel.togglePinOnSelection() }

            iconButton(
                item.isBookmarked ? "star.fill" : "star",
                tint: item.isBookmarked ? Theme.bookmarkTint : .secondary,
                help: item.isBookmarked
                    ? "Unfavorite (\(shortcuts.displayString(for: .star)))"
                    : "Favorite — protects from cleanup (\(shortcuts.displayString(for: .star)))"
            ) { viewModel.toggleBookmarkOnSelection() }

            iconButton(
                item.isLocked ? "lock.fill" : "lock.open",
                tint: item.isLocked ? Theme.lockTint : .secondary,
                help: "\(item.isLocked ? "Unlock" : "Lock") (\(shortcuts.displayString(for: .lock)))"
            ) { viewModel.toggleLockSelection() }

            iconButton(
                "trash",
                tint: .secondary,
                help: item.isLocked
                    ? "Locked - unlock to delete"
                    : "Delete (\(shortcuts.displayString(for: .delete)))",
                enabled: !item.isLocked
            ) { viewModel.deleteSelection() }
        }
    }

    /// A header action. `enabled: false` greys it and takes its click, rather
    /// than the caller dropping it from the row — see `historyActionIcons`.
    /// The tooltip still works while disabled, which is where the reason it
    /// is off gets said.
    private func iconButton(
        _ systemImage: String,
        tint: Color,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.icon(13, preview: true))
                // `.disabled` alone does not dim a `.plain` button carrying
                // its own `foregroundStyle`, so the off state is drawn here.
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .klipHelp(help)
    }

    // MARK: - Title

    /// The clip's name, shown under the kind header when it has one. Click to
    /// rename — the same inline card F2 and the row menu open.
    private func titleStrip(_ name: String, for item: ClipboardItem) -> some View {
        Button {
            viewModel.requestRenameClip(id: item.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.cursor")
                    .font(Theme.icon(11, preview: true))
                    .foregroundStyle(.tertiary)
                Text(name)
                    .font(.klip(.preview))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isTrashScope)
        .klipHelp(viewModel.isTrashScope
                  ? "Restore the clip to rename it"
                  : "Rename (\(ShortcutManager.shared.displayString(for: .renameClip)))")
    }

    /// Edit mode's title field. Sits above the body editor and commits with
    /// it; leaving it empty removes the name.
    private var editTitleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TITLE")
                .font(.klip(.caption))
                .fontWeight(.semibold)
                .kerning(0.6)
                .foregroundStyle(.secondary)
            TextField("Name this clip (optional)", text: $viewModel.editTitleText)
                .textFieldStyle(.plain)
                .font(.klip(.preview))
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isEditTitleFocused ? Theme.accent : Theme.hairline, lineWidth: 1)
                )
                .focused($isEditTitleFocused)
                // Return moves to the body rather than committing, so the
                // title can be typed and the text edited in one pass.
                .onSubmit { isTextEditorFocused = true }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for item: ClipboardItem) -> some View {
        switch item.type {
        case .text:
            textBody(item)
        case .image:
            imageBody(item)
        case .file:
            fileBody(item)
        }
    }

    @ViewBuilder
    private func textBody(_ item: ClipboardItem) -> some View {
        if let swatch = item.swatchColor, !viewModel.isEditing {
            colorBody(item, swatch: swatch)
        } else if item.isFileBacked || (item.textContent?.count ?? 0) > 5000 {
            chunkedText(item)
        } else if viewModel.isEditing {
            VStack(alignment: .leading, spacing: 6) {
                editTitleField
                    .padding(.bottom, 4)

                TextEditor(text: $viewModel.editText)
                    .font(.klip(.previewMono))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
                    .focused($isTextEditorFocused)

                // Phase 3D deliverable 3: editing a rich item saves plain
                // text and drops its RTF/flavors on commit.
                if item.rtfFilename != nil || item.flavorsFilename != nil {
                    Text("Editing keeps plain text only — formatting will be dropped when you save.")
                        .font(.klip(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(item.textContent ?? "")
                .font(.klip(item.displayKind == .code ? .previewMono : .preview))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func colorBody(_ item: ClipboardItem, swatch: Color) -> some View {
        let text = (item.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14)
                .fill(swatch)
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.swatchStroke, lineWidth: 1))
                .shadow(color: swatch.opacity(0.5), radius: 10, y: 4)
            Text(text.uppercased())
                .font(.klip(.previewMono))
                .fontWeight(.semibold)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func imageBody(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let img = viewModel.preview(for: item).image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1))
                    // Double-click opens the same Quick Look panel as Space.
                    // The pane caps the image at 240pt, so anything larger is
                    // only ever shown shrunk — this is the way to see it at
                    // full size without leaving Klip. `contentShape` so the
                    // whole rounded rect is the target, not just the painted
                    // pixels; it routes through `keyQuickLook()` so the key
                    // and the click cannot drift apart.
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture(count: 2) { viewModel.keyQuickLook() }
                    .klipHelp("Double-click to Quick Look")
            }
            // No placeholder on purpose. There used to be a `ProgressView` in
            // a 200pt frame here, and it was not information: the image is
            // decoded off a local disk and is usually on screen within a frame
            // or two, so what it produced was a spinner flashing and then the
            // pane jumping from the spinner's height to the image's — two
            // layout changes back to back, which is what made moving between
            // image clips look like it blinked. Nothing, then the image, is
            // one change.

            if viewModel.isExtractingText {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 12)
            } else if let ocrText = item.ocrText {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: 0.5)

                    HStack(alignment: .top, spacing: 8) {
                        Text(ocrText)
                            .font(.klip(.preview))
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        // The tappable area used to be the glyph's own
                        // painted pixels — a ~12 pt target with no padding
                        // and no `contentShape`, which is half of why this
                        // button "did nothing" (user item 11).
                        Button(action: { viewModel.copyOCRText(ocrText) }) {
                            Image(systemName: "doc.on.doc")
                                .font(Theme.icon(12, preview: true))
                                .foregroundStyle(.secondary)
                                .padding(5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .klipHelp("Copy extracted text")
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    /// `.file` item preview: a static QuickLook *thumbnail* of the first file
    /// (pane width × 320 pt) above the fallback card — icon, name(s), size,
    /// kind, a "Reference" badge for files that were only referenced (not
    /// copied in), a "File not found" badge, and Reveal in Finder / Open.
    ///
    /// 3.0.1: the live `QLPreviewView` that used to sit at the top is gone.
    /// Setting its preview item from `updateNSView` — i.e. from inside a
    /// SwiftUI layout pass — hits a QuickLook assertion that aborts the
    /// process (three user crash reports on 3.0.0). Nothing in this path
    /// touches a QuickLook UI class any more; see `FilePreview.swift`.
    @ViewBuilder
    private func fileBody(_ item: ClipboardItem) -> some View {
        let attachment = item.fileAttachment
        let fileURL = store.fileURLs(for: item).first
        let isMissing = store.fileIsMissing(item)

        VStack(alignment: .leading, spacing: 10) {
            if let fileURL, !isMissing {
                FileThumbnailView(url: fileURL, itemID: item.id, maxHeight: 320)
            }

            fileFallbackCard(item, attachment: attachment, fileURL: fileURL, isMissing: isMissing)

            HStack(spacing: 8) {
                if attachment?.isReference == true {
                    Text("Reference — original file")
                        .font(.klip(.badge))
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.chipInactive))
                }
                if isMissing {
                    Text("File not found")
                        .font(.klip(.badge))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.destructive)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.destructive.opacity(0.12)))
                }

                Spacer(minLength: 0)

                if let fileURL, !isMissing {
                    Button(action: { NSWorkspace.shared.open(fileURL) }) {
                        Label("Open", systemImage: "arrow.up.forward.app")
                            .font(.klip(.caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if let fileURL {
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }) {
                        Label("Reveal in Finder", systemImage: "folder")
                            .font(.klip(.caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// Name / size / kind block. The big icon is only drawn when there is no
    /// thumbnail above it, so a previewable file doesn't show its artwork
    /// twice.
    @ViewBuilder
    private func fileFallbackCard(
        _ item: ClipboardItem,
        attachment: FileAttachment?,
        fileURL: URL?,
        isMissing: Bool
    ) -> some View {
        let showIcon = fileURL == nil || isMissing

        VStack(spacing: 10) {
            if showIcon {
                Group {
                    if let icon = item.fileIcon(store: store) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "doc")
                            .font(Theme.icon(46, preview: true))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 72, height: 72)
                .opacity(isMissing ? 0.5 : 1)
            }

            Text(attachment?.originalName ?? "File")
                .font(.klip(.preview))
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let extra = attachment?.additionalNames, !extra.isEmpty {
                Text("+\(extra.count) more file\(extra.count == 1 ? "" : "s")")
                    .font(.klip(.caption))
                    .foregroundStyle(.secondary)
            }

            if let kind = FilePreview.kindLabel(for: fileURL, name: attachment?.originalName) {
                Text(kind)
                    .font(.klip(.caption))
                    .foregroundStyle(.secondary)
            }

            if let bytes = attachment?.byteSize, bytes > 0 {
                Text(viewModel.formattedByteCount(Int(bytes)))
                    .font(.klip(.caption))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func chunkedText(_ item: ClipboardItem) -> some View {
        LazyVStack(spacing: 8, pinnedViews: []) {
            Text(viewModel.chunkedText.visibleText)
                .font(.klip(.previewMono))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            if viewModel.chunkedText.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 8)
            } else if viewModel.chunkedText.hasMore {
                // Fires .onAppear only when it scrolls into view (LazyVStack),
                // which is what triggers the next chunk load.
                Text("— \(viewModel.formattedByteCount(viewModel.chunkedText.totalBytes)) total · scroll to load more —")
                    .font(.klip(.caption))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .onAppear {
                        Task { await viewModel.loadNextChunk(for: item) }
                    }
            }
        }
    }

    // MARK: - Footer

    private func footer(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            VStack(alignment: .leading, spacing: 5) {
                // Ordered by how specific each fact is to the clip itself,
                // most first: what it is, how big, where it lives, then where
                // it came from and when. The two that are the same on whole
                // runs of clips — the app they were copied from, the minute
                // they were copied in — sit at the bottom, out of the way of
                // the ones being scanned.
                //
                // Every row is always drawn, with an em dash where a clip has
                // no value for it, so the list is read by position: Kind is
                // always the first line and Copied always the last, whatever
                // is selected. See the notes on Kind and Dimensions below.

                // What the thing actually is: "PNG image", "Word document",
                // "Excel spreadsheet". Labelled **Kind** because that is the
                // word Finder uses for exactly this — Get Info's Kind line
                // reads "PNG image" too — so it is already where a Mac user
                // looks. (The code below says *format* only to keep clear of
                // `ContentKind`, which is the broader Text / Image / File
                // classification shown in the header.)
                metaRow("Kind", value: formatLabel(for: item) ?? "—")
                metaRow("Size", value: viewModel.preview(for: item).byteSize.map { viewModel.formattedByteCount($0) } ?? "—")
                // Under Size because the two answer the same question ("how
                // big is this?") from different angles.
                //
                // The value is a dash rather than the row waiting for it:
                // dimensions are measured off the file header, and a row
                // conditional on the value arrived a beat after the image did
                // — a second reflow, right behind the one the image itself
                // caused.
                metaRow("Dimensions", value: viewModel.preview(for: item).dimensions?.displayString ?? "—")
                metaRow("Folder", value: folderName(for: item))
                metaRow("From", value: item.sourceApp ?? "—")
                metaRow("Copied", value: item.timestamp.formatted(date: .abbreviated, time: .shortened))
            }
            .padding(.horizontal, 16)

            if Features.tagsEnabled {
                TagSection(
                    store: store,
                    viewModel: viewModel,
                    item: item,
                    isTagInputFocused: $isTagInputFocused
                )
            }
        }
        .padding(.bottom, 12)
        // The pane as a whole animates on selection (see `body`), and that is
        // right for the content above — but not here. Every value in this
        // list is right-aligned, so animating a change slides each one
        // sideways from its old position to its new one, and switching clips
        // read as the footer wobbling rather than updating. Values that fill
        // in a moment later (size, dimensions) did it a second time. The
        // footer swaps instantly instead.
        .transaction { $0.animation = nil }
    }

    /// The **Kind** row's value. See `ItemFormat`.
    private func formatLabel(for item: ClipboardItem) -> String? {
        if let attachment = item.fileAttachment {
            return ItemFormat.label(forFile: attachment)
        }
        if item.type == .image {
            return ItemFormat.label(forImage: item)
        }
        return ItemFormat.label(forText: item)
    }

    private func folderName(for item: ClipboardItem) -> String {
        guard let id = item.folderID else { return "—" }
        return store.folders.first(where: { $0.id == id })?.name ?? "—"
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.klip(.caption))
    }

    // MARK: - Empty state

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(Theme.icon(30, preview: true))
                .foregroundStyle(.tertiary)
            Text("Select an item")
                .font(.klip(.preview))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
