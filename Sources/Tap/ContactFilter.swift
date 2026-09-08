import Foundation

// MARK: - Palm rejection and one-hand clustering

/// Reduces a raw multitouch frame to "how many fingers of *one hand* are
/// down, and where", which is what `TapDetector` and the click conversion
/// actually want to know.
///
/// macOS runs palm rejection on top of the same raw stream before its own
/// gestures ever count fingers; Tap reads the stream directly, so without
/// this step a resting palm is just another contact. Three things go wrong:
/// a palm plus three fingers is four contacts (the gesture is cancelled), a
/// palm plus two fingers is three (a middle click fires by accident), and
/// contacts that merely hover above the glass are counted as if they were
/// touching it. The filter takes each in turn:
///
/// 1. **Stage.** Only contacts in the `makeTouch` or `touching` stage count.
///    Hovering, lingering and lifting contacts are dropped.
/// 2. **Size.** A contact whose ellipse major axis is longer than
///    `Config.maxFingerAxis`, or whose total contact size is above
///    `Config.maxFingerSize`, is a palm, a thumb pad or the thenar (the
///    fleshy base of the thumb) and is dropped. Both checks are needed: the
///    thenar of a resting hand is only a little longer than a fingertip but
///    covers twice the area.
/// 3. **Cluster.** The remaining contacts are grouped by proximity: two
///    contacts within `Config.linkDistance` of each other belong to the same
///    hand, transitively. Only a cluster of exactly `Config.fingers` contacts
///    is a candidate gesture; everything outside it (the other hand, a palm
///    that slipped past the size check) is ignored rather than cancelling it.
///
/// Once a cluster is chosen it is followed by contact identifier until every
/// one of its fingers has lifted, so the reported count goes 3, 2, 1, 0 even
/// while a palm stays on the pad, and `TapDetector` sees the empty pad it
/// waits for. A new contact joining the tracked cluster grows it (four
/// fingers of one hand are still not a three-finger gesture); a new contact
/// far away is somebody else's business.
///
/// Pure and nonisolated: no framework handles, no clock, no logging, so the
/// tests feed it hand-made frames. `MultitouchMonitor` owns the live
/// instance and calls it under its lock at the pad's report rate, which is
/// why the clustering is a plain union-find over at most a dozen points.
nonisolated struct ContactFilter {
    struct Config: Equatable {
        /// How many fingers make the gesture.
        var fingers: Int = 3
        /// Longest ellipse major axis, in millimetres, still taken for a
        /// fingertip. Measured on a Magic Trackpad (contact log, 2026-09-08):
        /// fingertips land at 7-13, the thenar at 12-20, a thumb pad at
        /// 16-25. Tune from the contact log (`tap.logContacts`) if fingers
        /// on a given pad are dropped.
        var maxFingerAxis: Float = 14
        /// Largest `MTTouch.total` still taken for a fingertip. On the same
        /// pad fingertips report 0.3-1.0, the thenar 1.3-2.1 and a thumb pad
        /// 1.5-8; this is what separates a thenar from a broad fingertip.
        var maxFingerSize: Float = 1.2
        /// Two contacts closer than this, in millimetres, are on the same
        /// hand. Neighbouring fingertips sit 20-30 mm apart, spread ones up
        /// to 40; the resting thenar of the other hand was measured 48 mm
        /// from the nearest fingertip, which is why this is not 50.
        var linkDistance: Float = 40
    }

    /// `MTPathStage`, the `stage` field of `MTTouch`.
    enum Stage: Int32 {
        case notTracking = 0
        case startInRange = 1
        case hoverInRange = 2
        case makeTouch = 3
        case touching = 4
        case breakTouch = 5
        case lingerInRange = 6
        case outOfRange = 7

        /// Whether a contact in this stage is pressing the glass.
        var isDown: Bool { self == .makeTouch || self == .touching }
    }

    /// The parts of one `MTTouch` the filter reads.
    struct Contact {
        /// `MTTouch.identifier`: stable while one finger stays down.
        var id: Int32
        /// Raw `MTTouch.stage`; unknown values are treated as not down.
        var stage: Int32
        /// `MTTouch.majorAxis`, millimetres.
        var majorAxis: Float
        /// `MTTouch.total`, the contact's overall size.
        var total: Float
        /// `MTTouch.normalizedVector.position`, 0...1 across the pad.
        var position: MTPoint
        /// `MTTouch.absoluteVector.position`, millimetres.
        var absolute: MTPoint

        var isDown: Bool { Stage(rawValue: stage)?.isDown ?? false }

        func isFingerSized(_ config: Config) -> Bool {
            majorAxis <= config.maxFingerAxis && total <= config.maxFingerSize
        }
    }

    /// What `TapDetector` and the click conversion consume: the size of the
    /// tracked cluster and the summed normalized positions of its fingers.
    struct Frame: Equatable {
        var fingerCount: Int
        var sumX: Float
        var sumY: Float

        static let empty = Frame(fingerCount: 0, sumX: 0, sumY: 0)
    }

    let config: Config

    /// Identifiers of the cluster being followed; empty between gestures.
    private(set) var trackedIDs: Set<Int32> = []

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func reset() {
        trackedIDs = []
    }

    /// Feeds one frame. Returns the tracked cluster's count and position
    /// sums, or `.empty` when no cluster of `config.fingers` is on the pad.
    mutating func update(contacts: [Contact]) -> Frame {
        // 1 and 2: down, and finger-sized unless already part of the gesture.
        let admissible = contacts.filter { contact in
            contact.isDown && (contact.isFingerSized(config) || trackedIDs.contains(contact.id))
        }
        guard !admissible.isEmpty else {
            trackedIDs = []
            return .empty
        }

        // 3: group by proximity.
        let clusters = Self.cluster(admissible, linkDistance: config.linkDistance)

        if trackedIDs.isEmpty {
            let candidates = clusters.filter { $0.count == config.fingers }
            // Two hands each showing three fingers is ambiguous; wait.
            guard candidates.count == 1, let gesture = candidates.first else { return .empty }
            trackedIDs = Set(gesture.map(\.id))
            return Self.frame(of: gesture)
        }

        // Every cluster that contains a tracked finger is the gesture, even
        // if the fingers have drifted apart into two clusters.
        let present = clusters
            .filter { cluster in cluster.contains { trackedIDs.contains($0.id) } }
            .flatMap { $0 }
        if present.isEmpty {
            trackedIDs = []
            return .empty
        }
        let presentIDs = Set(present.map(\.id))
        if !presentIDs.isSubset(of: trackedIDs) {
            // A new finger landed next to the gesture: the cluster grew.
            trackedIDs = presentIDs
        }
        return Self.frame(of: present)
    }

    // MARK: Helpers

    private static func frame(of contacts: [Contact]) -> Frame {
        var frame = Frame(fingerCount: contacts.count, sumX: 0, sumY: 0)
        for contact in contacts {
            frame.sumX += contact.position.x
            frame.sumY += contact.position.y
        }
        return frame
    }

    /// Single-linkage clustering: contacts within `linkDistance` of each
    /// other, directly or through a chain, form one cluster. Union-find over
    /// the handful of contacts a trackpad reports.
    static func cluster(_ contacts: [Contact], linkDistance: Float) -> [[Contact]] {
        var parent = Array(0..<contacts.count)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        let limit = linkDistance * linkDistance
        for a in contacts.indices {
            for b in contacts.indices where b > a {
                let dx = contacts[a].absolute.x - contacts[b].absolute.x
                let dy = contacts[a].absolute.y - contacts[b].absolute.y
                if dx * dx + dy * dy <= limit {
                    parent[root(a)] = root(b)
                }
            }
        }
        var groups: [Int: [Contact]] = [:]
        var order: [Int] = []
        for index in contacts.indices {
            let key = root(index)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(contacts[index])
        }
        return order.map { groups[$0]! }
    }
}
