import AppKit
import BenchCore

/// Thin vertical divider lines the user can ⌘-drag anywhere in the menu bar,
/// e.g. to visually group icons from other apps - the same idea as
/// BetterTouchTool's "Menubar Item: │".
///
/// Each line is its own `NSStatusItem` with a stable `autosaveName`, so
/// macOS remembers where the user dragged it across launches, the same way
/// `StatusBarController` remembers Bench's own icon. Independent of
/// `AppSettings.hideMenuBarIcon`: separators stay in the bar even when
/// Bench's own icon is hidden, since they belong to no module.
///
/// ## Removing one by dragging it off the bar
///
/// Without `.removalAllowed`, ⌘-dragging a status item out of the menu bar
/// makes macOS hide *every* item of the app (it flips the app's "allow in
/// menu bar" switch in System Settings), which took Bench's own icon down
/// with the line. With the behaviour set, dragging a line off removes just
/// that line: macOS sets its `isVisible` to false, the KVO observer below
/// drops the item and lowers the count, and the stepper in Settings shows
/// the new number. Bench's icon deliberately does not opt in.
@MainActor
final class MenuBarSeparators {
    /// Live items by slot (1...maximum). Slots, not positions: a line dragged
    /// off frees its slot, and the next added line takes the lowest free one,
    /// so no two live items ever share an autosave name.
    private var items: [Int: NSStatusItem] = [:]
    private var visibilityObservers: [Int: NSKeyValueObservation] = [:]
    private let settings = AppSettings.shared

    static let maximum = 5

    init() {
        // Deferred by one run-loop turn for the same reason as
        // `StatusBarController.init`: a status item created inside
        // `applicationDidFinishLaunching` - before AppKit has finished
        // setting up the menu bar - is registered but never laid out.
        DispatchQueue.main.async { [weak self] in
            self?.reconcile()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reconcile),
            name: .benchMenuBarSeparatorsChanged,
            object: nil)
    }

    /// Adds or removes items so the live count matches
    /// `settings.menuBarSeparatorCount`. Removing takes the highest slot
    /// first; adding fills the lowest free slot.
    @objc private func reconcile() {
        let target = min(max(settings.menuBarSeparatorCount, 0), Self.maximum)
        while items.count < target, let slot = (1...Self.maximum).first(where: { items[$0] == nil }) {
            add(slot: slot)
        }
        while items.count > target, let slot = items.keys.max() {
            remove(slot: slot)
        }
    }

    private func add(slot: Int) {
        // 4 pt is the narrowest a status item draws at; the gap that remains
        // on each side is the system's spacing between every status item.
        let item = NSStatusBar.system.statusItem(withLength: 4)
        item.autosaveName = "BenchSeparator\(slot)"
        item.behavior = [.removalAllowed]
        // Explicit, even though it is the default: a slot whose line was
        // dragged off earlier has "hidden" remembered under this autosave
        // name, and setting the flag overwrites that memory.
        item.isVisible = true
        // No target/action: clicking a line does nothing. `isEnabled = false`
        // would grey it out instead, which is not wanted here - the line
        // should look the same as any other menu bar glyph, just inert.
        item.button?.image = Self.lineImage
        items[slot] = item

        visibilityObservers[slot] = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            MainActor.assumeIsolated { self?.draggedOff(slot: slot) }
        }
    }

    private func remove(slot: Int) {
        visibilityObservers[slot] = nil
        if let item = items.removeValue(forKey: slot) {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    /// The user ⌘-dragged this line out of the bar. Drop it and let the
    /// count follow; the resulting notification finds nothing to reconcile.
    private func draggedOff(slot: Int) {
        guard items[slot] != nil else { return }
        remove(slot: slot)
        settings.menuBarSeparatorCount = items.count
    }

    /// A 1pt-wide, ~16pt-tall vertical line, drawn once and shared by every
    /// separator item. Template so AppKit tints it for light and dark menu
    /// bars the same way it tints every other status item glyph.
    private static let lineImage: NSImage = {
        let size = NSSize(width: 1, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}
