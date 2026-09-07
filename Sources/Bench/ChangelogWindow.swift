// The "What's New" window. Snapper showed the parsed changelog in an NSAlert
// because it had not ported Klip's window; this is the window, modelled on
// Klip's Views/Changelog (MIT, Copyright 2026 Sam Reza).

import AppKit
import BenchCore
import SwiftUI

// MARK: - Inline Markdown

/// Renders one line of inline Markdown (`**bold**`, `` `code` ``, links).
///
/// `.inlineOnlyPreservingWhitespace` keeps the text as written and leaves
/// block syntax alone, which is the division of labour we want:
/// `ChangelogService` owns the blocks, this owns the spans. A string the
/// parser cannot digest degrades to plain text rather than throwing.
private struct MarkdownText: View {
    let source: String

    var body: some View {
        Text(Self.attributed(source))
    }

    static func attributed(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}

// MARK: - Blocks

private struct ChangelogBlocksView: View {
    let blocks: [ChangelogBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                case .bullet(let text):
                    // .firstTextBaseline so the dot sits on the first line of
                    // a bullet that wraps, not centred against the paragraph.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        MarkdownText(source: text)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .paragraph(let text):
                    MarkdownText(source: text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .rule:
                    Divider().padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - One entry

private struct ChangelogEntryView: View {
    let entry: ChangelogEntry
    /// The running version's entry gets the full-strength heading; older ones
    /// are demoted so the scroll reads as "what just changed, then history".
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.version)
                    .font(.system(size: isCurrent ? 20 : 15, weight: .bold))
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("Installed")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                }
            }
            ChangelogBlocksView(blocks: entry.blocks)
                .opacity(isCurrent ? 1 : 0.86)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Window content

struct ChangelogView: View {
    /// Newest first. Empty is a legitimate state (no bundled changelog).
    let entries: [ChangelogEntry]
    /// The running app's `CFBundleShortVersionString`.
    let currentVersion: String
    /// The notes GitHub returned for the version that just installed. Used
    /// only when `entries` has nothing for `currentVersion`.
    let fallbackNotes: String?
    /// Where "View on GitHub" goes.
    let githubURL: URL

    private var currentEntry: ChangelogEntry? {
        ChangelogService.entry(for: currentVersion, in: entries)
    }

    /// The current version's entry hoisted to the front, everything else after
    /// it in file order.
    private var orderedEntries: [ChangelogEntry] {
        guard let current = currentEntry else { return entries }
        return [current] + entries.filter { $0.version != current.version }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        if currentEntry == nil, let fallback = fallbackNotes, !fallback.isEmpty {
                            fallbackSection(fallback)
                            Divider()
                        }
                        ForEach(Array(orderedEntries.enumerated()), id: \.offset) { index, entry in
                            ChangelogEntryView(entry: entry, isCurrent: entry.version == currentEntry?.version)
                            if index < orderedEntries.count - 1 { Divider() }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Link("View on GitHub", destination: githubURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .benchAppearance()
    }

    /// Shown when the running version has no section in the bundled changelog:
    /// an out-of-band build, or a bundle assembled without the copy step.
    private func fallbackSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(currentVersion.isEmpty ? "What's New" : currentVersion)
                    .font(.system(size: 20, weight: .bold))
                Text("release notes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ChangelogBlocksView(blocks: ChangelogService.blocks(fromMarkdown: notes))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(currentVersion.isEmpty ? "Bench" : "Bench \(currentVersion)")
                .font(.system(size: 20, weight: .bold))
            if let fallback = fallbackNotes, !fallback.isEmpty {
                ChangelogBlocksView(blocks: ChangelogService.blocks(fromMarkdown: fallback))
            } else {
                Text("The release notes for this build were not included in the app. They are on the release page on GitHub.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Window controller

/// Presents `ChangelogView` in an ordinary window.
///
/// A singleton: "What's New" on the post-update toast and the same link in
/// Settings > About should bring one window forward, not stack a second copy
/// behind the first.
@MainActor
final class ChangelogWindowController: NSWindowController {
    static let shared = ChangelogWindowController()

    private static let defaultSize = NSSize(width: 460, height: 560)
    private static let minSize = NSSize(width: 380, height: 320)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "What's New"
        window.minSize = Self.minSize
        // The app is an accessory (LSUIElement) with no main window, so AppKit
        // would otherwise deallocate this on close and leave `shared` holding
        // a zombie.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - releaseURL: the GitHub page for the release that just installed, if
    ///     known; the footer link falls back to the releases index.
    ///   - fallbackNotes: the GitHub release `body`, used only when the
    ///     running version has no section in the bundled `CHANGELOG.md`.
    func show(releaseURL: URL? = nil, fallbackNotes: String? = nil) {
        guard let window else { return }

        let entries = ChangelogService.allEntries()
        let version = BenchInfo.shortVersion
        window.title = "What's New in Bench \(version)"
        window.contentView = NSHostingView(
            rootView: ChangelogView(
                entries: entries,
                currentVersion: version,
                fallbackNotes: fallbackNotes,
                githubURL: releaseURL ?? BenchInfo.repositoryURL.appendingPathComponent("releases")))
        // Re-applied after swapping the content view: NSHostingView reports
        // its own fitting size and can shrink the frame out from under minSize.
        window.minSize = Self.minSize
        if window.frame.width < Self.minSize.width || window.frame.height < Self.minSize.height {
            window.setContentSize(Self.defaultSize)
            window.center()
        }

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // An accessory app is never frontmost on its own; without this the
        // window opens behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
    }
}
