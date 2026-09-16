import SwiftUI
import BenchCore

/// Settings > Sync (Phase 4A). Everything about iCloud Drive sync lives here:
/// the master toggle (disabled, with the reason, when iCloud Drive is not set
/// up), the live status line, a manual "Sync Now", the attachment size cap,
/// this Mac's display name, and the two ways to remove cloud data.
///
/// The toggle binds to `SettingsManager.shared.syncEnabled`; `CloudDriveSync`
/// observes that setting and starts/stops itself, so the switch and the service
/// can never disagree.
struct SyncTab: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var sync: CloudDriveSync

    @State private var showingRemoveAll = false
    @State private var removeAllConfirmation = ""
    @State private var showingCustomCap = false
    @State private var customCapText = ""
    @State private var now = Date()

    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    init(sync: CloudDriveSync? = nil) {
        self.sync = sync ?? .shared
    }

    var body: some View {
        Form {
            Section("iCloud Drive") {
                Toggle("Sync clipboard history across your Macs", isOn: Binding(
                    get: { settings.syncEnabled },
                    set: { settings.syncEnabled = $0 }
                ))
                .disabled(!sync.isAvailable)

                if let reason = sync.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(Features.tagsEnabled
                         ? "Your history is mirrored into the Bench/Klip folder in iCloud Drive. Each Mac writes only its own snapshot, so nothing is ever overwritten; deletes, locks, tags and folders travel with it."
                         : "Your history is mirrored into the Bench/Klip folder in iCloud Drive. Each Mac writes only its own snapshot, so nothing is ever overwritten; deletes, locks and folders travel with it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sync Now") { sync.syncNow() }
                        .buttonStyle(.bordered)
                        .disabled(!settings.syncEnabled || !sync.isAvailable || sync.isBusy)
                }

                if let error = sync.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("What to Sync") {
                ForEach(SyncKindFilter.selectable, id: \.self) { kind in
                    Toggle(isOn: kindBinding(kind)) {
                        Label(kind.label, systemImage: kind.systemImage)
                    }
                    .disabled(!sync.isAvailable)
                }

                HStack {
                    Button("Select All") { settings.syncedKinds = SyncKindFilter.all }
                        .disabled(!sync.isAvailable || settings.syncedKinds.count == SyncKindFilter.selectable.count)
                    Button("Select None") { settings.syncedKinds = [] }
                        .disabled(!sync.isAvailable || settings.syncedKinds.isEmpty)
                    Spacer()
                }
                .buttonStyle(.bordered)

                if settings.syncedKinds.isEmpty {
                    Text("Nothing is checked, so nothing will sync.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Only the kinds you check leave this Mac, and only those are taken from your other Macs. Unchecking a kind never deletes anything: clips already on this Mac stay, and copies already on your other Macs stay there too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("This Mac") {
                TextField("Device name", text: $settings.syncDeviceName)
                Text("Shown in the sync status on your other Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Attachments") {
                Picker("Don't sync files larger than", selection: capSelection) {
                    ForEach(SyncAttachmentCap.presets, id: \.self) { cap in
                        Text(cap.label).tag(cap.megabytes)
                    }
                    Text("Custom…").tag(SyncAttachmentCap.customTag)
                }

                if showingCustomCap || SyncAttachmentCap.isCustom(settings.syncMaxAttachmentMB) {
                    HStack {
                        Text("Custom limit")
                        Spacer()
                        TextField("MB", text: $customCapText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onSubmit(applyCustomCap)
                        Text("MB").foregroundStyle(.secondary)
                        Button("Apply", action: applyCustomCap)
                            .buttonStyle(.bordered)
                    }
                }

                Text("Bigger files stay on this Mac; the clip still syncs, marked local-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cloud Copy") {
                Button("Remove This Mac's Cloud Copy") {
                    sync.removeThisDeviceFromCloud()
                }
                .disabled(!sync.isAvailable)

                Button("Remove All Klip Cloud Data…", role: .destructive) {
                    removeAllConfirmation = ""
                    showingRemoveAll = true
                }
                .disabled(!sync.isAvailable)

                Text("Removing this Mac's copy leaves shared attachments in place; removing all data deletes the whole Bench/Klip folder from iCloud Drive. Neither touches the history on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(ticker) { now = $0 }
        .onAppear {
            now = Date()
            customCapText = String(settings.syncMaxAttachmentMB)
        }
        .sheet(isPresented: $showingRemoveAll) { removeAllSheet }
    }

    // MARK: - Status line

    private var statusLine: String {
        SyncStatusLine.text(
            enabled: settings.syncEnabled,
            available: sync.isAvailable,
            lastPush: sync.lastPush,
            lastPull: sync.lastPull,
            devices: sync.otherDevices.map { $0.name },
            now: now
        )
    }

    // MARK: - What to sync

    /// One checkbox. Rich text has no box of its own: it reads as text in the
    /// history, so `SyncKindFilter` files it under Text.
    private func kindBinding(_ kind: ContentKind) -> Binding<Bool> {
        Binding(
            get: { settings.syncedKinds.contains(kind) },
            set: { isOn in
                var kinds = settings.syncedKinds
                if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
                settings.syncedKinds = kinds
            }
        )
    }

    // MARK: - Attachment cap

    private var capSelection: Binding<Int> {
        Binding(
            get: {
                SyncAttachmentCap.isCustom(settings.syncMaxAttachmentMB)
                    ? SyncAttachmentCap.customTag
                    : settings.syncMaxAttachmentMB
            },
            set: { newValue in
                if newValue == SyncAttachmentCap.customTag {
                    showingCustomCap = true
                    customCapText = String(settings.syncMaxAttachmentMB)
                } else {
                    showingCustomCap = false
                    settings.syncMaxAttachmentMB = newValue
                }
            }
        )
    }

    private func applyCustomCap() {
        guard let value = Int(customCapText.trimmingCharacters(in: .whitespaces)), value >= 0 else {
            customCapText = String(settings.syncMaxAttachmentMB)
            return
        }
        settings.syncMaxAttachmentMB = value
    }

    // MARK: - Typed-confirm sheet

    private var removeAllSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove all Klip cloud data?")
                .font(.klip(.sidebarTitle).bold())

            Text("This deletes the entire Bench/Klip folder from iCloud Drive: every Mac's snapshot and every synced image, text and file. Your history on this Mac is not touched, but your other Macs lose anything they have not already downloaded.")
                .font(.klip(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Type DELETE to confirm.")
                .font(.klip(.caption))

            TextField("DELETE", text: $removeAllConfirmation)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { showingRemoveAll = false }
                Button("Delete Everything", role: .destructive) {
                    sync.removeAllCloudData()
                    showingRemoveAll = false
                }
                .disabled(removeAllConfirmation != "DELETE")
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Attachment cap presets

/// The size-cap picker's options. `0` is "Unlimited"; anything not in the
/// preset list is a custom value the user typed.
enum SyncAttachmentCap {
    struct Preset: Hashable {
        let megabytes: Int
        let label: String
    }

    /// Sentinel tag for the "Custom…" row. Negative so it can never collide
    /// with a real megabyte value.
    static let customTag = -1

    static let presets: [Preset] = [
        Preset(megabytes: 1, label: "1 MB"),
        Preset(megabytes: 5, label: "5 MB"),
        Preset(megabytes: 10, label: "10 MB"),
        Preset(megabytes: 50, label: "50 MB"),
        Preset(megabytes: 100, label: "100 MB"),
        Preset(megabytes: 500, label: "500 MB"),
        Preset(megabytes: 0, label: "Unlimited"),
    ]

    static func isCustom(_ megabytes: Int) -> Bool {
        !presets.contains { $0.megabytes == megabytes }
    }

    static func label(for megabytes: Int) -> String {
        presets.first { $0.megabytes == megabytes }?.label ?? "\(megabytes) MB"
    }
}

// MARK: - Status line text

/// The one-line sync summary. The text itself is `CloudSyncStatusLine` in
/// BenchCore, shared with the settings sync; this keeps Klip's call sites
/// and tests unchanged.
enum SyncStatusLine {
    static func text(
        enabled: Bool,
        available: Bool,
        lastPush: Date?,
        lastPull: Date?,
        devices: [String],
        now: Date = Date()
    ) -> String {
        CloudSyncStatusLine.text(
            enabled: enabled, available: available, lastPush: lastPush, lastPull: lastPull,
            devices: devices, now: now)
    }

    static func ago(from date: Date, to now: Date) -> String {
        CloudSyncStatusLine.ago(from: date, to: now)
    }
}
