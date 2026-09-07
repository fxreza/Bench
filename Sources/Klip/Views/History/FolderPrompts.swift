import SwiftUI

/// Inline folder prompts rendered inside the panel (never `NSAlert` — see
/// `PromptCard`).
///
/// `FolderPromptLayer` is the single entry point: `HistoryContentView` renders
/// it once and it decides which of New Folder / Rename / Delete / Move to show.
struct NewFolderPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState.Binding var isFieldFocused: Bool

    var body: some View {
        PromptCard(width: 280, onDismiss: { viewModel.cancelNewFolder() }) {
            Label("New Folder", systemImage: "folder.badge.plus")
                .font(.klip(.sidebarTitle))

            TextField("Folder name", text: $viewModel.newFolderName)
                .textFieldStyle(.plain)
                .font(.klip(.preview))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .focused($isFieldFocused)
                .onSubmit { viewModel.confirmNewFolder() }

            HStack(spacing: 10) {
                Spacer()
                PromptButton(title: "Cancel", isProminent: false) {
                    viewModel.cancelNewFolder()
                }
                PromptButton(title: "Create", isProminent: true) {
                    viewModel.confirmNewFolder()
                }
                .disabled(viewModel.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            // One run loop later, so the field is in the hierarchy first.
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }
}

/// Small pill button used inside `PromptCard`s. `.borderedProminent` would pull
/// in the system control background, which reads wrong on the material panel.
struct PromptButton: View {
    let title: String
    var isProminent: Bool = false
    /// Destructive actions (delete) get the red fill instead of the accent one.
    var isDestructive: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.klip(.chip))
                .fontWeight(.medium)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background { fill }
                .foregroundStyle(isProminent || isDestructive ? Color.white : Color.primary)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var fill: some View {
        if isDestructive {
            Capsule().fill(Theme.destructive)
        } else if isProminent {
            Capsule().fill(Theme.accentGradient)
        } else {
            Capsule().fill(Theme.chipInactive)
        }
    }
}

// MARK: - Prompt layer (3B)

/// Renders whichever folder prompt is active, over the whole panel.
///
/// `HistoryContentView` renders exactly one of these; each prompt owns its own
/// `@FocusState` so no focus plumbing has to cross file boundaries.
struct FolderPromptLayer: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        ZStack {
            if viewModel.showRenameFolderPrompt {
                RenameFolderPrompt(viewModel: viewModel)
            } else if viewModel.showDeleteFolderPrompt {
                DeleteFolderPrompt(viewModel: viewModel)
            } else if viewModel.showMoveToFolderPrompt {
                MoveToFolderPrompt(viewModel: viewModel)
            } else if let message = viewModel.folderActionMessage {
                FolderResultPrompt(viewModel: viewModel, message: message)
            }
        }
        .animation(Theme.promptSpring, value: viewModel.showRenameFolderPrompt)
        .animation(Theme.promptSpring, value: viewModel.showDeleteFolderPrompt)
        .animation(Theme.promptSpring, value: viewModel.showMoveToFolderPrompt)
    }
}

// MARK: - Rename

/// Inline rename, opened by double-clicking a sidebar folder, the folder
/// context menu, or `keyRenameFolder()`. Return saves, Esc cancels (through
/// `dismissTopPrompt`).
struct RenameFolderPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        PromptCard(width: 280, onDismiss: { viewModel.cancelRenameFolder() }) {
            Label("Rename Folder", systemImage: "pencil")
                .font(.klip(.sidebarTitle))

            TextField("Folder name", text: $viewModel.renameFolderName)
                .textFieldStyle(.plain)
                .font(.klip(.preview))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .focused($isFieldFocused)
                .onSubmit { viewModel.confirmRenameFolder() }

            HStack(spacing: 10) {
                Spacer()
                PromptButton(title: "Cancel", isProminent: false) {
                    viewModel.cancelRenameFolder()
                }
                PromptButton(title: "Rename", isProminent: true) {
                    viewModel.confirmRenameFolder()
                }
                .disabled(!viewModel.canConfirmRenameFolder)
            }
        }
        .onAppear {
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }
}

// MARK: - Delete

/// The non-empty folder delete card.
///
/// Stage 1 offers the two outcomes; "Delete" only *arms* the destructive path
/// when locked clips are present — deleting those needs the word DELETE typed
/// into the field in stage 2, in the same card. Stage 3 reports what happened
/// when locked clips kept the folder alive.
struct DeleteFolderPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState private var isConfirmFocused: Bool

    private var name: String { viewModel.deleteFolderTarget?.name ?? "Folder" }
    private var count: Int { viewModel.deleteFolderItemCount }
    private var lockedCount: Int { viewModel.deleteFolderLockedCount }

    var body: some View {
        PromptCard(width: 340, onDismiss: { dismiss() }) {
            switch viewModel.deleteFolderStage {
            case .choice: choiceStage
            case .lockedConfirm: lockedStage
            case .result: resultStage
            }
        }
    }

    private func dismiss() {
        if viewModel.deleteFolderStage == .result {
            viewModel.acknowledgeFolderResult()
        } else {
            viewModel.cancelDeleteFolder()
        }
    }

    // Stage 1
    @ViewBuilder
    private var choiceStage: some View {
        Label("Delete “\(name)”", systemImage: "trash")
            .font(.klip(.sidebarTitle))

        Text("This folder holds \(count) \(count == 1 ? "clip" : "clips"). Choose what happens to them.")
            .font(.klip(.rowSubtitle))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 8) {
            PromptChoiceRow(
                title: "Move \(count) \(count == 1 ? "clip" : "clips") to All",
                subtitle: "Nothing is deleted. The clips stay in your history and keep their lock.",
                systemImage: "tray.full.fill",
                isProminent: true
            ) {
                viewModel.confirmDeleteFolderMovingOut()
            }

            PromptChoiceRow(
                title: "Delete \(count) \(count == 1 ? "clip" : "clips")",
                subtitle: lockedCount > 0
                    ? "\(lockedCount) of them are locked and need a separate confirmation."
                    : "The clips are removed from the history for good.",
                systemImage: "trash",
                isDestructive: true
            ) {
                viewModel.requestDeleteFolderItems()
            }
        }

        HStack {
            Spacer()
            PromptButton(title: "Cancel") { viewModel.cancelDeleteFolder() }
        }
    }

    // Stage 2
    @ViewBuilder
    private var lockedStage: some View {
        Label("Locked clips in “\(name)”", systemImage: "lock.fill")
            .font(.klip(.sidebarTitle))

        Text("\(lockedCount) of \(count) \(count == 1 ? "clip is" : "clips are") locked. Type \(HistoryViewModel.lockedDeleteConfirmationWord) to delete them too.")
            .font(.klip(.rowSubtitle))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        TextField(HistoryViewModel.lockedDeleteConfirmationWord, text: $viewModel.deleteLockedConfirmText)
            .textFieldStyle(.plain)
            .font(.klip(.previewMono))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        viewModel.isDeleteLockedConfirmValid ? Theme.destructive : Theme.hairline,
                        lineWidth: 1
                    )
            )
            .focused($isConfirmFocused)

        HStack(spacing: 10) {
            PromptButton(title: "Cancel") { viewModel.cancelDeleteFolder() }
            Spacer()
            PromptButton(title: "Keep Locked") { viewModel.confirmDeleteFolderKeepingLocked() }
            PromptButton(title: "Delete All", isDestructive: true) {
                viewModel.confirmDeleteFolderIncludingLocked()
            }
            .disabled(!viewModel.isDeleteLockedConfirmValid)
        }
        .onAppear {
            DispatchQueue.main.async { isConfirmFocused = true }
        }
    }

    // Stage 3
    @ViewBuilder
    private var resultStage: some View {
        Label("Locked clips kept", systemImage: "lock.fill")
            .font(.klip(.sidebarTitle))

        Text(viewModel.folderActionMessage ?? "")
            .font(.klip(.rowSubtitle))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
            Spacer()
            PromptButton(title: "Delete Locked Too", isDestructive: true) {
                viewModel.deleteLockedConfirmText = ""
                viewModel.deleteFolderStage = .lockedConfirm
            }
            PromptButton(title: "Done", isProminent: true) {
                viewModel.acknowledgeFolderResult()
            }
        }
    }
}

/// A tappable, two-line option inside a `PromptCard`.
struct PromptChoiceRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isProminent: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.klip(.chip))
                    .frame(width: .klipScaled(16))
                    .foregroundStyle(isDestructive ? Theme.destructive : Theme.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.klip(.preview))
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.klip(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isProminent ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isDestructive ? Theme.destructive.opacity(0.4) : Theme.hairline,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Move to folder

/// Folder picker for the current selection. Typing filters, ↑/↓ move the
/// highlight, Return applies, Esc cancels.
struct MoveToFolderPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState private var isFieldFocused: Bool

    private var options: [HistoryViewModel.MoveTarget] { viewModel.moveToFolderOptions }

    var body: some View {
        PromptCard(width: 300, onDismiss: { viewModel.cancelMoveToFolder() }) {
            Label(headline, systemImage: "folder")
                .font(.klip(.sidebarTitle))

            TextField("Filter folders", text: $viewModel.moveFolderQuery)
                .textFieldStyle(.plain)
                .font(.klip(.preview))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .focused($isFieldFocused)
                .onSubmit { viewModel.confirmMoveToFolder() }
                .onChange(of: viewModel.moveFolderQuery) { _, _ in
                    viewModel.moveFolderHighlight = 0
                }

            if options.isEmpty {
                Text("No folders yet — create one with New Folder.")
                    .font(.klip(.rowSubtitle))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            optionRow(option, isHighlighted: index == viewModel.moveFolderClampedHighlight)
                        }
                    }
                }
                // Hug the options until the list gets long enough to scroll,
                // otherwise a two-folder picker reserves a tall empty box.
                .frame(height: min(190, CGFloat(options.count) * .klipScaled(31) + 2))
            }

            HStack {
                Spacer()
                PromptButton(title: "Cancel") { viewModel.cancelMoveToFolder() }
                PromptButton(title: "Move", isProminent: true) { viewModel.confirmMoveToFolder() }
                    .disabled(options.isEmpty)
            }
        }
        .background(
            PromptKeyCatcher { keyCode, _ in
                switch keyCode {
                case 126: viewModel.moveHighlightBy(-1); return true
                case 125: viewModel.moveHighlightBy(1); return true
                case 36, 76: viewModel.confirmMoveToFolder(); return true
                default: return false
                }
            }
        )
        .onAppear {
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private var headline: String {
        let count = viewModel.pendingMoveIDs.count
        return count == 1 ? "Move Clip to Folder" : "Move \(count) Clips to Folder"
    }

    private func optionRow(_ option: HistoryViewModel.MoveTarget, isHighlighted: Bool) -> some View {
        Button {
            viewModel.apply(option)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: option.systemImage)
                    .font(.klip(.chip))
                    .frame(width: .klipScaled(16))
                Text(option.title)
                    .font(.klip(.preview))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Standalone "here is what happened" card, used when a folder delete finished
/// without leaving a stage open.
struct FolderResultPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel
    let message: String

    var body: some View {
        PromptCard(width: 300, onDismiss: { viewModel.acknowledgeFolderResult() }) {
            Label("Folder Deleted", systemImage: "checkmark.circle")
                .font(.klip(.sidebarTitle))

            Text(message)
                .font(.klip(.rowSubtitle))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                PromptButton(title: "Done", isProminent: true) {
                    viewModel.acknowledgeFolderResult()
                }
            }
        }
    }
}

// MARK: - Key catching inside a prompt

/// Local key monitor scoped to the lifetime of the prompt that installs it.
///
/// `GlobalKeyMonitor` deliberately stands down while a prompt is showing (only
/// Esc is intercepted) so text fields work, which means arrow keys inside the
/// move picker have to be caught here. Returning true from `onKey` consumes the
/// event.
struct PromptKeyCatcher: NSViewRepresentable {
    let onKey: (UInt16, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onKey = onKey
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    class Coordinator {
        var onKey: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, let onKey = self.onKey else { return event }
                return onKey(event.keyCode, event.modifierFlags) ? nil : event
            }
        }

        func remove() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
