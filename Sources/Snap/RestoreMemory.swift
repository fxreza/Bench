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

/// "What did this window look like before Snap first touched it?"
///
/// Written once per window - the frame remembered is the one from *before*
/// the first Snap move, so a maximize followed by three thirds and a restore
/// still lands back where the user left it. `restore` hands the frame back
/// and forgets it, so the next move starts a fresh memory.
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

    /// Records `frame` the first time this window is seen. A second call for
    /// the same window is ignored on purpose: the remembered frame must stay
    /// the pre-Snap one.
    func rememberIfNeeded(_ identity: WindowIdentity, frame: CGRect) {
        guard frames[identity] == nil else { return }
        frames[identity] = frame
        order.append(identity)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            frames.removeValue(forKey: oldest)
        }
    }

    func frame(for identity: WindowIdentity) -> CGRect? { frames[identity] }

    func has(_ identity: WindowIdentity) -> Bool { frames[identity] != nil }

    /// The remembered frame, forgotten in the same breath.
    func restore(_ identity: WindowIdentity) -> CGRect? {
        guard let frame = frames.removeValue(forKey: identity) else { return nil }
        order.removeAll { $0 == identity }
        return frame
    }

    func forget(_ identity: WindowIdentity) {
        _ = restore(identity)
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
