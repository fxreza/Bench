// Ported from Snapper's Services/UpdateService.swift (MIT, Copyright 2026 Sam
// Reza), which came from Klip. Changes: constants come from `BenchInfo`, keys
// are namespaced `bench.` on `BenchDefaults.standard`, the "What's New"
// NSAlert is replaced by `ChangelogWindowController`, and everything that
// touches the network or the file system runs as a `nonisolated static`
// function so the app's MainActor default isolation holds without hopping
// blind.

import AppKit
import BenchCore

@MainActor
final class UpdateService {
    static let shared = UpdateService()
    private init() {}

    private let defaults = BenchDefaults.standard

    private enum Key {
        static let lastCheck = "bench.lastUpdateCheckDate"
        static let includePrereleases = "bench.includePrereleases"
        /// Where the just-installed release's notes are parked across the
        /// restart.
        static let updateNotes = "bench.updateNotes"
        static let justUpdated = "bench.justUpdated"
        static let updateTag = "bench.updateTag"
    }

    private var progressWindow: NSWindow?
    private var toastWindow: NSWindow?
    private var pendingReleaseURL: URL?
    /// The release notes GitHub returned for the version that just installed.
    /// Only a fallback - the changelog display prefers the bundled
    /// `CHANGELOG.md` and reaches for this when the running version has no
    /// section there.
    private var pendingReleaseNotes: String?

    // MARK: - Checking

    /// The launch check, at most once a day.
    func checkOnLaunchIfNeeded() {
        if let lastCheck = defaults.object(forKey: Key.lastCheck) as? Date,
           Date().timeIntervalSince(lastCheck) < 86400 {
            let hoursAgo = Date().timeIntervalSince(lastCheck) / 3600
            NSLog("[UpdateService] Skipping launch check - last checked \(String(format: "%.1f", hoursAgo))h ago")
            return
        }
        checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool) {
        NSLog("[UpdateService] checkForUpdates(silent: \(silent))")
        defaults.set(Date(), forKey: Key.lastCheck)

        var request = URLRequest(url: BenchInfo.releasesAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let includePrereleases = defaults.bool(forKey: Key.includePrereleases)
        let currentVersion = BenchInfo.shortVersion

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                NSLog("[UpdateService] Network error: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse {
                NSLog("[UpdateService] GitHub API responded: HTTP \(http.statusCode)")
            }
            let candidate = Self.selectRelease(from: data, includePrereleases: includePrereleases)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.shared.handle(candidate, currentVersion: currentVersion, silent: silent)
                }
            }
        }.resume()
    }

    /// One release worth offering: the newest one with a downloadable zip.
    struct ReleaseCandidate: Sendable, Equatable {
        var tag: String
        var zipURL: String
        /// The release's Markdown notes, carried through the install so the
        /// relaunched app can show them if the bundled changelog has no
        /// section for the new version.
        var notes: String?
    }

    /// Picks the release to offer out of the GitHub response. Pure parsing, no
    /// UI: runs on the URLSession queue.
    nonisolated static func selectRelease(from data: Data?, includePrereleases: Bool) -> ReleaseCandidate? {
        guard let data,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            NSLog("[UpdateService] Failed to parse releases JSON")
            return nil
        }
        let sorted = releases
            .filter { includePrereleases || ($0["prerelease"] as? Bool) != true }
            .sorted { (($0["published_at"] as? String) ?? "") > (($1["published_at"] as? String) ?? "") }

        #if arch(arm64)
        let archKeyword = "Silicon"
        #else
        let archKeyword = "Intel"
        #endif

        for release in sorted {
            guard let tag = release["tag_name"] as? String,
                  let assets = release["assets"] as? [[String: Any]] else { continue }
            let archZip = assets.first {
                guard let name = $0["name"] as? String else { return false }
                return name.hasSuffix(".zip") && name.contains(archKeyword)
            }
            let anyZip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            guard let zip = archZip ?? anyZip,
                  let url = zip["browser_download_url"] as? String else { continue }
            NSLog("[UpdateService] Selected asset: \(zip["name"] as? String ?? "?") (\(archKeyword) preferred)")
            return ReleaseCandidate(
                tag: tag,
                zipURL: url,
                notes: (release["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        NSLog("[UpdateService] No release with a .zip asset found")
        return nil
    }

    private func handle(_ candidate: ReleaseCandidate?, currentVersion: String, silent: Bool) {
        guard let candidate else {
            if !silent { showUpToDateAlert() }
            return
        }
        let latest = Self.stripTagPrefix(candidate.tag)
        NSLog("[UpdateService] Latest: \(latest)  Current: \(currentVersion)")
        if Self.versionIsNewer(latest, than: currentVersion) {
            showUpdateAlert(version: latest, candidate: candidate)
        } else if !silent {
            showUpToDateAlert()
        }
    }

    nonisolated static func stripTagPrefix(_ tag: String) -> String {
        var v = tag
        let lower = v.lowercased()
        if lower.hasPrefix("bench-v") {
            v = String(v.dropFirst("bench-v".count))
        } else if lower.hasPrefix("v") {
            v = String(v.dropFirst(1))
        }
        return v
    }

    nonisolated static func versionIsNewer(_ latest: String, than current: String) -> Bool {
        let lp = latest.split(separator: ".").compactMap { Int($0) }
        let cp = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lp.count, cp.count) {
            let l = i < lp.count ? lp[i] : 0
            let c = i < cp.count ? cp[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    // MARK: - Alerts

    private func showUpdateAlert(version: String, candidate: ReleaseCandidate) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Bench \(version) is available"
        alert.informativeText = "A new version of Bench is ready to download and install."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        downloadAndInstall(candidate)
    }

    private func showUpToDateAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "You're up to date"
        alert.informativeText = "Bench is already on the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Post-update

    func checkIfJustUpdated() {
        guard defaults.bool(forKey: Key.justUpdated) else { return }
        defaults.removeObject(forKey: Key.justUpdated)
        let tag = defaults.string(forKey: Key.updateTag) ?? ""
        defaults.removeObject(forKey: Key.updateTag)
        // Read and clear in the same breath: these notes describe the update
        // that just landed, so leaving them behind would attach them to some
        // later version's toast.
        let notes = defaults.string(forKey: Key.updateNotes)
        defaults.removeObject(forKey: Key.updateNotes)
        NSLog("[UpdateService] Post-update launch, tag: \(tag), notes: \(notes?.count ?? 0) chars")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.showSuccessToast(tag: tag, notes: notes)
        }
    }

    private func showSuccessToast(tag: String, notes: String?) {
        let version = BenchInfo.shortVersion
        let w: CGFloat = 270
        let h: CGFloat = 190

        // An NSPanel with .nonactivatingPanel never touches app activation
        // state, so closing it cannot trigger AppKit's "accessory app with no
        // windows" termination.
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.alphaValue = 0
        toastWindow = window

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        window.contentView = blur

        let iconSize: CGFloat = 48
        let iconConfig = NSImage.SymbolConfiguration(pointSize: iconSize * 0.8, weight: .medium)
            .applying(.init(paletteColors: [.white, NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)]))
        let iconView = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: 124, width: iconSize, height: iconSize))
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        blur.addSubview(iconView)

        let title = NSTextField(labelWithString: version.isEmpty ? "Bench" : "Bench \(version)")
        title.font = .boldSystemFont(ofSize: 13)
        // Semantic, not `.white`: `.hudWindow` is only a *dark* HUD when the
        // effective appearance is dark - in Light Mode it renders light grey
        // and hardcoded white text would be invisible on it.
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 98, width: w, height: 20)
        blur.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Updated and ready.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: 78, width: w, height: 16)
        blur.addSubview(subtitle)

        let releases = BenchInfo.repositoryURL.appendingPathComponent("releases")
        pendingReleaseURL = tag.isEmpty ? releases : releases.appendingPathComponent("tag/\(tag)")
        pendingReleaseNotes = notes

        let button = NSButton(title: "What's New →", target: self, action: #selector(whatsNewButtonTapped))
        button.bezelStyle = .rounded
        button.font = .boldSystemFont(ofSize: 12)
        let buttonWidth: CGFloat = 150
        button.frame = NSRect(x: (w - buttonWidth) / 2, y: 18, width: buttonWidth, height: 30)
        blur.addSubview(button)

        // The toast auto-dismisses after 8 s, but there is no other way to get
        // rid of it sooner.
        let closeSize: CGFloat = 20
        let closeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
                .withSymbolConfiguration(closeConfig) ?? NSImage(),
            target: self,
            action: #selector(closeToastTapped))
        closeButton.isBordered = false
        closeButton.frame = NSRect(x: w - closeSize - 10, y: h - closeSize - 10, width: closeSize, height: closeSize)
        blur.addSubview(closeButton)

        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            self.dismissToast()
        }
    }

    @objc private func whatsNewButtonTapped() {
        showChangelogWindow()
        dismissToast()
    }

    /// Brings up the What's New window. Also called from Settings > About,
    /// where there is no pending release and both stashed values are nil.
    func showChangelogWindow() {
        ChangelogWindowController.shared.show(
            releaseURL: pendingReleaseURL,
            fallbackNotes: pendingReleaseNotes)
    }

    @objc private func closeToastTapped() { dismissToast() }

    private func dismissToast() {
        guard let window = toastWindow else { return }
        toastWindow = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.close()
        })
    }

    // MARK: - Download and install

    private func downloadAndInstall(_ candidate: ReleaseCandidate) {
        guard let downloadURL = URL(string: candidate.zipURL) else {
            NSLog("[UpdateService] Invalid download URL: \(candidate.zipURL)")
            return
        }
        NSLog("[UpdateService] Starting download: \(candidate.zipURL)")
        showProgressWindow()

        let runningBundlePath = Bundle.main.bundlePath
        URLSession.shared.downloadTask(with: downloadURL) { localURL, _, error in
            if let error {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Self.shared.finish(.failed("Download error: \(error.localizedDescription)"), candidate: candidate) }
                }
                return
            }
            let outcome = Self.stageAndLaunchInstaller(
                downloadedZip: localURL, runningBundlePath: runningBundlePath)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.shared.finish(outcome, candidate: candidate) }
            }
        }.resume()
    }

    /// What the background install attempt ended in.
    enum InstallOutcome: Sendable, Equatable {
        /// The installer script is running detached; the app must now quit.
        case launched
        /// The download was not what it claimed to be. Worth an alert.
        case refused(String)
        /// Something went wrong before anything was touched. Logged only.
        case failed(String)
    }

    private func finish(_ outcome: InstallOutcome, candidate: ReleaseCandidate) {
        hideProgressWindow()
        switch outcome {
        case .failed(let reason):
            NSLog("[UpdateService] \(reason)")
        case .refused(let reason):
            NSLog("[UpdateService] Refusing to install: \(reason)")
            showIdentityRefusedAlert(reason: reason)
        case .launched:
            // Hand the new app what it needs for the success toast.
            defaults.set(true, forKey: Key.justUpdated)
            defaults.set(candidate.tag, forKey: Key.updateTag)
            if let notes = candidate.notes, !notes.isEmpty {
                defaults.set(notes, forKey: Key.updateNotes)
            } else {
                defaults.removeObject(forKey: Key.updateNotes)
            }
            defaults.set(Date(), forKey: Key.lastCheck) // suppress the launch check in the new app
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
    }

    /// Extracts the downloaded zip, checks what came out of it, and detaches
    /// the installer script. Runs off the main actor: every step here is file
    /// system and subprocess work.
    nonisolated static func stageAndLaunchInstaller(
        downloadedZip: URL?, runningBundlePath: String
    ) -> InstallOutcome {
        guard let downloadedZip else { return .failed("Download returned no file") }

        // A UUID-based temp dir, not guessable by other processes.
        let fm = FileManager.default
        let tmpBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BenchUpdate_\(UUID().uuidString)")
        let zipURL = tmpBase.appendingPathComponent("update.zip")
        let extractURL = tmpBase.appendingPathComponent("extracted")
        let newAppURL = extractURL.appendingPathComponent("Bench.app")
        let scriptURL = tmpBase.appendingPathComponent("install.sh")

        do {
            try fm.createDirectory(
                at: tmpBase, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: downloadedZip, to: zipURL)
        } catch {
            return .failed("Failed to prepare temp dir: \(error)")
        }

        // Sanity-check the payload before handing it to ditto: an error page
        // or a truncated download is not worth extracting.
        let zipSize = ((try? fm.attributesOfItem(atPath: zipURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard zipSize > 100_000, zipSize < 500_000_000 else {
            return .failed("Downloaded asset has an implausible size (\(zipSize) bytes)")
        }

        // Extract before touching /Applications, so the contents can be
        // inspected first.
        if let reason = run("/usr/bin/ditto", ["-xk", zipURL.path, extractURL.path]) {
            return .failed("ditto extraction failed: \(reason)")
        }
        guard fm.fileExists(atPath: newAppURL.path) else {
            return .failed("Bench.app not found in the extracted zip at \(newAppURL.path)")
        }

        // Verify the signature *and* who signed it. `--verify` alone only
        // proves the signature is internally consistent - any ad-hoc or
        // self-signed bundle passes it, so it could not tell a genuine Bench
        // build from anything else that ended up at the download URL.
        if let reason = run("/usr/bin/codesign", ["--verify", "--strict", newAppURL.path]) {
            return .failed("Code signature verification failed: \(reason)")
        }

        // The downloaded bundle must carry the same signing identity as the
        // app asking for it, and our bundle identifier. A self-signed identity
        // cannot be pinned with an anchored designated requirement, so the
        // running app is the reference.
        guard let candidate = signingInfo(at: newAppURL.path) else {
            return .refused("the downloaded app's signature could not be read")
        }
        guard let running = signingInfo(at: runningBundlePath) else {
            return .refused("this app's own signature could not be read")
        }
        if let reason = identityMismatchReason(candidate: candidate, running: running) {
            return .refused(reason)
        }

        // The script only stages, swaps and opens; extraction is already done.
        // Paths are passed as positional arguments rather than interpolated
        // into the script text.
        do {
            try installScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed("Failed to write install script: \(error)")
        }
        if let reason = run("/bin/chmod", ["755", scriptURL.path]) {
            return .failed("Failed to chmod the install script: \(reason)")
        }

        // Detached via nohup so it survives the app quitting. `sh -c '…' arg0
        // arg1 arg2` binds $0/$1/$2, so no path is ever interpolated into
        // shell text.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [
            "-c",
            "nohup /bin/bash \"$0\" \"$1\" \"$2\" >/dev/null 2>&1 &",
            scriptURL.path,
            newAppURL.path,
            BenchInfo.installDestination,
        ]
        do {
            try launcher.run()
            launcher.waitUntilExit() // wait for the fork before we exit
        } catch {
            return .failed("Failed to launch install script: \(error)")
        }
        return .launched
    }

    /// Runs a tool, returning why it was unhappy - or nil when it was fine.
    private nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return "exit \(process.terminationStatus)"
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Install script

    /// The installer, as a standalone bash script.
    ///
    /// Arguments: `$1` = the extracted new bundle, `$2` = the destination.
    /// `$3`/`$4` exist only so a test can run this for real without waiting
    /// two seconds and without launching anything; the app passes neither.
    ///
    /// Stages the new bundle next to the destination first, moves the old one
    /// aside, swaps, and only then deletes the old copy - restoring it if any
    /// step fails, rather than deleting first and copying second (which would
    /// leave no app at all if the copy failed). Every path is quoted.
    nonisolated static func installScript() -> String {
        """
        #!/bin/bash
        # Bench updater. $1 = new bundle, $2 = destination,
        # $3 = seconds to wait first (default 2), $4 = relaunch? 1/0 (default 1).
        set -u

        NEW_APP="$1"
        TARGET="$2"
        WAIT="${3:-2}"
        RELAUNCH="${4:-1}"
        STAGE="${TARGET}.new"
        OLD="${TARGET}.old"

        fail() {
            osascript -e "display alert \\"Bench Update Failed\\" message \\"$1 Try updating manually.\\"" >/dev/null 2>&1
            exit 1
        }

        sleep "$WAIT"

        # Stage beside the destination, on the same volume, so the swap below
        # is an atomic rename rather than a copy.
        rm -rf "$STAGE"
        if ! cp -R "$NEW_APP" "$STAGE"; then
            rm -rf "$STAGE"
            fail "Could not stage the new app."
        fi
        xattr -cr "$STAGE" >/dev/null 2>&1

        rm -rf "$OLD"
        if [ -e "$TARGET" ]; then
            if ! mv "$TARGET" "$OLD"; then
                rm -rf "$STAGE"
                fail "Could not move the old app aside."
            fi
        fi

        if ! mv "$STAGE" "$TARGET"; then
            # Put the old app back before giving up.
            if [ -e "$OLD" ]; then mv "$OLD" "$TARGET"; fi
            rm -rf "$STAGE"
            fail "Could not install the new app."
        fi

        rm -rf "$OLD"

        if [ "$RELAUNCH" = "1" ]; then
            sleep 1
            /bin/launchctl asuser $(id -u) /usr/bin/open "$TARGET"
        fi
        """
    }

    // MARK: - Signing identity

    /// What `codesign -dvv` reports about a bundle.
    struct SigningInfo: Equatable, Sendable {
        var identifier: String?
        /// The `Authority=` chain, leaf first. Empty for an ad-hoc signature.
        var authorities: [String]
    }

    /// Parses `codesign -dvv` output (which goes to stderr).
    nonisolated static func parseSigningInfo(_ output: String) -> SigningInfo {
        var identifier: String?
        var authorities: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Identifier="), identifier == nil {
                identifier = String(trimmed.dropFirst("Identifier=".count))
            } else if trimmed.hasPrefix("Authority=") {
                authorities.append(String(trimmed.dropFirst("Authority=".count)))
            }
        }
        return SigningInfo(identifier: identifier, authorities: authorities)
    }

    /// Why `candidate` must not be installed over `running`, or nil if it may.
    ///
    /// A self-signed identity cannot be expressed as an anchored designated
    /// requirement, so the rule is "the update must be signed by exactly the
    /// same chain as the app asking for it, and must be Bench".
    nonisolated static func identityMismatchReason(candidate: SigningInfo, running: SigningInfo) -> String? {
        guard candidate.identifier == BenchInfo.bundleIdentifier else {
            return "the downloaded app identifies itself as \"\(candidate.identifier ?? "nothing")\", not \(BenchInfo.bundleIdentifier)"
        }
        guard candidate.authorities == running.authorities else {
            let signer = candidate.authorities.first ?? "no signing authority"
            let expected = running.authorities.first ?? "no signing authority"
            return "the downloaded app is signed by \(signer), but this copy of Bench is signed by \(expected)"
        }
        return nil
    }

    /// Reads a bundle's signing info via `codesign -dvv`.
    nonisolated static func signingInfo(at path: String) -> SigningInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", path]
        let pipe = Pipe()
        // codesign writes its display output to stderr.
        process.standardError = pipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return parseSigningInfo(String(decoding: data, as: UTF8.self))
        } catch {
            NSLog("[UpdateService] Failed to run codesign -dvv: \(error)")
            return nil
        }
    }

    private func showIdentityRefusedAlert(reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Update Refused"
        alert.informativeText = """
            Bench did not install this update because \(reason).

            Nothing has been changed. Download the update yourself from \
            \(BenchInfo.repositoryURL.appendingPathComponent("releases").absoluteString) \
            if you were expecting one.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Progress window

    private func showProgressWindow() {
        let w: CGFloat = 260
        let h: CGFloat = 168

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        window.contentView = blur

        let iconSize: CGFloat = 52
        let iconView = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: 100, width: iconSize, height: iconSize))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyDown
        blur.addSubview(iconView)

        let title = NSTextField(labelWithString: "Updating Bench…")
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 72, width: w, height: 20)
        blur.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Downloading, please wait…")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: 52, width: w, height: 16)
        blur.addSubview(subtitle)

        let spinner = NSProgressIndicator(frame: NSRect(x: (w - 20) / 2, y: 20, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        blur.addSubview(spinner)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressWindow = window
    }

    private func hideProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
    }
}
