import SwiftUI
import AppKit
import BenchCore

/// Klip's pane in Bench's Settings window. Every control binds directly to
/// `SettingsManager.shared` — there is no separate view-model layer, and
/// every change applies immediately (this matches how native macOS Settings
/// panes behave, and loses nothing versus the old explicit "Save" flow: the
/// only thing that flow ever did was copy a local draft back into
/// `SettingsManager` and call `.save()`, which now happens as soon as you
/// touch a control).
///
/// What the standalone Klip's window had and this pane does not, because
/// Bench owns it: Launch at Login, the menu bar icon toggle, update checks,
/// the Permissions tab, the accent and light/dark pickers, and the About
/// footer. The tabs left are the Klip-specific ones.
struct KlipSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            HistorySettingsTab()
                .tabItem { Label("History", systemImage: "clock") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            SyncTab()
                .tabItem { Label("Sync", systemImage: "icloud") }
        }
        .frame(minWidth: 520, minHeight: 460)
    }
}

/// The global open-Klip hotkey as BenchCore currently resolves it, for the
/// two captions that mention it. Observed through `ShortcutStore.shared` by
/// the tabs, so a rebind in Bench's Shortcuts pane updates the text.
@MainActor
func klipToggleHotkeyDisplay() -> String {
    let display = ShortcutStore.shared.displayString(for: KlipHotkeys.toggleHistoryID)
    return display.isEmpty ? "the Open Klip shortcut" : display
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Form {
            Section("Global Shortcut") {
                Text("Open Klip: \(klipToggleHotkeyDisplay()) - change in Shortcuts")
                    .foregroundStyle(.secondary)
            }

            Section("Search") {
                Toggle("Keep search text between opens", isOn: $settings.keepSearchBetweenOpens)
                Text(settings.keepSearchBetweenOpens
                     ? "What you type in the search box stays there until you clear it, however long Klip has been closed."
                     : "The search box is empty every time Klip opens, so an old query never hides the rest of your history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window") {
                Toggle("Keep the window open after pasting", isOn: $settings.keepWindowOpen)
                Text("On, Klip stays on screen after you paste a clip, so you can paste several in a row. Pasting hands the keyboard back to the app you pasted into, so pick the next clip with the mouse, or press \(klipToggleHotkeyDisplay()) to put the keyboard back in Klip. Esc closes the window. Toggle it any time with the window button at the bottom-left of the history window (\(ShortcutManager.shared.displayString(for: .toggleKeepOpen))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remember the last window position", isOn: $settings.rememberWindowPosition)
                Text(settings.rememberWindowPosition
                     ? "Drag the window by any empty part of it. It reopens where you left it."
                     : "Drag the window by any empty part of it. Every time Klip opens it goes back to its default spot, centred on the screen under the mouse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste") {
                Toggle("Always Paste as Plain Text", isOn: $settings.alwaysPastePlain)
                Text(settings.alwaysPastePlain
                     ? "Copy and Paste strip formatting by default. Use Paste with Formatting (\(ShortcutManager.shared.displayString(for: .pastePlain))) or the row menu to get it back for one item."
                     : "Copy and Paste keep formatting when it's available. Use Paste as Plain Text (\(ShortcutManager.shared.displayString(for: .pastePlain))) or the row menu to strip it for one item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Pasting multiple selected items always joins them as plain text — rich text can't be combined across items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

private struct HistorySettingsTab: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var pendingTier: HistoryLimit?
    @State private var showingTrimAlert = false
    @State private var customCapText: String = ""

    var body: some View {
        Form {
            Section("History Size") {
                HStack(spacing: 12) {
                    ForEach(HistoryLimit.allCases, id: \.self) { tier in
                        tierButton(tier)
                    }
                }
                Text(Features.tagsEnabled
                     ? "Older unpinned, unfavorited, untagged items are removed once the limit is reached."
                     : "Older unpinned, unfavorited items are removed once the limit is reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Trash") {
                Picker("Keep deleted clips for", selection: $settings.trashRetention) {
                    ForEach(TrashRetention.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Text("Deleted clips move to the trash and are erased for good after this. Open the history window and click Trash in the sidebar to search them, restore them, or empty the trash. The trash stays on this Mac and is never synced to iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Lock / Protect") {
                Text(Features.tagsEnabled
                     ? "Locked clips can't be deleted until you unlock them. Clips inside folders are locked automatically. Pinned, favorited, tagged, locked and folder clips never count toward the history limit."
                     : "Locked clips can't be deleted until you unlock them. Clips inside folders are locked automatically. Pinned, favorited, locked and folder clips never count toward the history limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Files") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy files into storage up to")
                    HStack(spacing: 8) {
                        ForEach(FileCopyCapTier.allCases) { tier in
                            capButton(tier)
                        }
                        customCapField
                    }
                }
                .padding(.vertical, 2)

                Text(settings.fileCopyCapMB == 0
                     ? "Every copied file is stored in full, however large — this can use a lot of disk space over time."
                     : "Files larger than this are kept as a reference to the original instead of being copied in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Storage Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ClipboardStore.storageDirectoryURL])
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { customCapText = String(settings.fileCopyCapMB) }
        .alert("Reduce History Limit?", isPresented: $showingTrimAlert) {
            Button("Cancel", role: .cancel) { pendingTier = nil }
            Button("Reduce & Delete", role: .destructive) {
                if let tier = pendingTier {
                    apply(tier)
                }
                pendingTier = nil
            }
        } message: {
            Text("This will permanently delete your oldest unfavorited items to fit the new size. This action cannot be undone.")
        }
    }

    private func tierButton(_ tier: HistoryLimit) -> some View {
        let isSelected = settings.historyLimit == tier
        return Button(action: { select(tier) }) {
            VStack(alignment: .center, spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.3))
                    .font(.body)

                Text(tier.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Text(tier.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowCornerRadius)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rowCornerRadius)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func select(_ tier: HistoryLimit) {
        if isDowngrade(from: settings.historyLimit, to: tier) {
            pendingTier = tier
            showingTrimAlert = true
        } else {
            apply(tier)
        }
    }

    private func apply(_ tier: HistoryLimit) {
        settings.historyLimit = tier
        NotificationCenter.default.post(name: .bufferHistoryLimitChanged, object: nil)
    }

    /// True when `new` keeps fewer items than `current` — i.e. items could be
    /// trimmed. `nil` `maxItems` means "unlimited".
    private func isDowngrade(from current: HistoryLimit, to new: HistoryLimit) -> Bool {
        switch (current.maxItems, new.maxItems) {
        case (nil, nil): return false
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(currentMax), .some(newMax)): return newMax < currentMax
        }
    }

    // MARK: - Files cap (Phase 3F, D6)

    private func capButton(_ tier: FileCopyCapTier) -> some View {
        let isSelected = settings.fileCopyCapMB == tier.megabytes
        return Button(action: {
            settings.fileCopyCapMB = tier.megabytes
            customCapText = String(tier.megabytes)
        }) {
            Text(tier.label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                )
                .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Free-form entry for a cap that isn't one of the preset tiers.
    private var customCapField: some View {
        let isCustom = FileCopyCapTier.matching(settings.fileCopyCapMB) == nil
        return HStack(spacing: 4) {
            TextField("Custom", text: $customCapText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyCustomCap() }
            Text("MB")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isCustom ? 1 : 0.6)
    }

    private func applyCustomCap() {
        guard let value = Int(customCapText), value >= 0 else {
            customCapText = String(settings.fileCopyCapMB)
            return
        }
        settings.fileCopyCapMB = value
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section("Theme") {
                Text("The accent colour and light/dark appearance are set once for all of Bench, under General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text Size") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("List text size")
                        Spacer()
                        Text("\(Int(settings.listFontScale * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.listFontScale, in: 0.8...1.6)
                    Text("Sample clipboard item")
                        .font(.klip(.rowTitle))
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Preview text size")
                        Spacer()
                        Text("\(Int(settings.previewFontScale * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.previewFontScale, in: 0.8...1.6)
                    Text("Sample preview text")
                        .font(.klip(.preview))
                }
                .padding(.vertical, 4)
            }

            Section("Layout") {
                Toggle("Show preview pane", isOn: $settings.showPreviewPane)
            }
        }
        .formStyle(.grouped)
    }
}
