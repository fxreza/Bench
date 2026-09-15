import CoreGraphics

/// Identity of a window, stable across the moves Snap makes to it.
///
/// The private `_AXUIElementGetWindow` gives the real `CGWindowID`, which is
/// what we want: it survives a title change and a move, and never collides
/// between two windows of the same app. When it is unavailable (it is
/// private SPI and may one day stop answering) the fallback is pid + title,
/// which is stable enough for the one thing this key is used for -
/// remembering a frame between "maximize" and "restore" - and simply loses
/// the memory if the title changes in between.
struct WindowIdentity: Hashable {
    let pid: pid_t
    /// The real window number, or 0 when the SPI did not answer.
    let windowID: CGWindowID
    /// Only consulted when `windowID` is 0.
    let title: String

    init(pid: pid_t, windowID: CGWindowID, title: String = "") {
        self.pid = pid
        self.windowID = windowID
        // A window id makes the title irrelevant; dropping it keeps two
        // lookups of the same window equal even after it is renamed.
        self.title = windowID == 0 ? title : ""
    }
}

/// "What did this window look like before Snap last touched it?"
///
/// One frame per window, the way Raycast's Restore works: every Snap change
/// (a layout, Make Larger, Almost Maximize, a modifier-key drag) records the
/// frame the window had *just before* it, overwriting whatever was there. So
/// the memory always holds the previous state, however the window got there,
/// including a move the user made by hand in between.
///
/// `swap` is Restore: it hands the remembered frame back and stores the
/// window's current frame in its place, so pressing Restore twice flips
/// between the last two states rather than restoring once and forgetting.
///
/// Bounded: the oldest entry is dropped past `capacity`, because a window
/// that was closed hours ago can never be restored and its `AXUIElement` is
/// long dead.
final class RestoreMemory {
    static let defaultCapacity = 64

    private var frames: [WindowIdentity: CGRect] = [:]
    /// Insertion order, oldest first - the eviction queue.
    private var order: [WindowIdentity] = []
    let capacity: Int

    init(capacity: Int = RestoreMemory.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { frames.count }

    /// Records `frame` as the window's previous state, replacing any earlier
    /// memory of it.
    func remember(_ identity: WindowIdentity, frame: CGRect) {
        if frames.updateValue(frame, forKey: identity) == nil {
            order.append(identity)
        }
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            frames.removeValue(forKey: oldest)
        }
    }

    func frame(for identity: WindowIdentity) -> CGRect? { frames[identity] }

    func has(_ identity: WindowIdentity) -> Bool { frames[identity] != nil }

    /// Restore: the remembered frame, with `current` stored in its place so
    /// the next call comes back here. Nil, and nothing stored, when the
    /// window was never touched by Snap.
    func swap(_ identity: WindowIdentity, current: CGRect) -> CGRect? {
        guard let previous = frames[identity] else { return nil }
        frames[identity] = current
        return previous
    }

    func forget(_ identity: WindowIdentity) {
        guard frames.removeValue(forKey: identity) != nil else { return }
        order.removeAll { $0 == identity }
    }

    /// Drops everything for one process - what happens when an app quits.
    func forgetAll(pid: pid_t) {
        for identity in order where identity.pid == pid {
            frames.removeValue(forKey: identity)
        }
        order.removeAll { $0.pid == pid }
    }

    func removeAll() {
        frames.removeAll()
        order.removeAll()
    }
}
