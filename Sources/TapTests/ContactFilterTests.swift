import Foundation
import BenchTestKit
@testable import Tap

// MARK: - Helpers

/// Builds a `ContactFilter.Contact` from an id and an absolute (millimetre)
/// position. The normalized position is derived from the absolute one (the
/// pad's extents are approximated as 160mm x 115mm) so summed positions are
/// non-trivial, the way a real trackpad frame would report both.
func contact(
    _ id: Int32, _ x: Float, _ y: Float,
    stage: ContactFilter.Stage = .touching, majorAxis: Float = 8, total: Float = 0.6
) -> ContactFilter.Contact {
    ContactFilter.Contact(
        id: id,
        stage: stage.rawValue,
        majorAxis: majorAxis,
        total: total,
        position: MTPoint(x: x / 160, y: y / 115),
        absolute: MTPoint(x: x, y: y)
    )
}

/// Three fingertips ~30mm apart, well within `Config.linkDistance` (40mm).
func threeFingers(ids: [Int32] = [1, 2, 3]) -> [ContactFilter.Contact] {
    [
        contact(ids[0], 0, 0),
        contact(ids[1], 30, 0),
        contact(ids[2], 60, 0),
    ]
}

/// The summed normalized positions of a list of contacts, computed the same
/// way `ContactFilter.frame(of:)` does, for comparing against a returned
/// `Frame`.
func summedPosition(_ contacts: [ContactFilter.Contact]) -> (x: Float, y: Float) {
    var sumX: Float = 0
    var sumY: Float = 0
    for contact in contacts {
        sumX += contact.position.x
        sumY += contact.position.y
    }
    return (sumX, sumY)
}

// MARK: - ContactFilter

enum ContactFilterTests {
    static let tests: [TestCase] = [
        ("three close fingertips report fingerCount 3 and matching sums", {
            var filter = ContactFilter()
            let fingers = threeFingers()
            let sum = summedPosition(fingers)
            let frame = filter.update(contacts: fingers)
            try expectEqual(frame.fingerCount, 3)
            try expectEqual(frame.sumX, sum.x)
            try expectEqual(frame.sumY, sum.y)
        }),

        ("two fingers report zero", {
            var filter = ContactFilter()
            let two = Array(threeFingers().prefix(2))
            try expectEqual(filter.update(contacts: two), .empty)
        }),

        ("hovering contacts are not counted", {
            var filter = ContactFilter()
            let fingers = [
                contact(1, 0, 0, stage: .hoverInRange),
                contact(2, 30, 0, stage: .hoverInRange),
                contact(3, 60, 0, stage: .hoverInRange),
            ]
            try expectEqual(filter.update(contacts: fingers), .empty)
        }),

        ("lingering contacts are not counted", {
            var filter = ContactFilter()
            let fingers = [
                contact(1, 0, 0, stage: .lingerInRange),
                contact(2, 30, 0, stage: .lingerInRange),
                contact(3, 60, 0, stage: .lingerInRange),
            ]
            try expectEqual(filter.update(contacts: fingers), .empty)
        }),

        ("contacts breaking touch are not counted", {
            var filter = ContactFilter()
            let fingers = [
                contact(1, 0, 0, stage: .breakTouch),
                contact(2, 30, 0, stage: .breakTouch),
                contact(3, 60, 0, stage: .breakTouch),
            ]
            try expectEqual(filter.update(contacts: fingers), .empty)
        }),

        ("makeTouch contacts are counted", {
            var filter = ContactFilter()
            let fingers = [
                contact(1, 0, 0, stage: .makeTouch),
                contact(2, 30, 0, stage: .makeTouch),
                contact(3, 60, 0, stage: .makeTouch),
            ]
            try expectEqual(filter.update(contacts: fingers).fingerCount, 3)
        }),

        ("a large contact nearby is ignored: three fingers still count", {
            var filter = ContactFilter()
            let palm = contact(99, 90, 0, majorAxis: 30)
            let frame = filter.update(contacts: threeFingers() + [palm])
            try expectEqual(frame.fingerCount, 3)
        }),

        ("a large contact nearby is ignored: two fingers still count zero", {
            var filter = ContactFilter()
            let two = Array(threeFingers().prefix(2))
            let palm = contact(99, 60, 0, majorAxis: 30)
            try expectEqual(filter.update(contacts: two + [palm]), .empty)
        }),

        ("a far finger-sized contact is ignored: three fingers still count", {
            var filter = ContactFilter()
            let far = contact(99, 120, 0)
            let frame = filter.update(contacts: threeFingers() + [far])
            try expectEqual(frame.fingerCount, 3)
        }),

        ("a far finger-sized contact is ignored: two fingers still count zero", {
            var filter = ContactFilter()
            let two = Array(threeFingers().prefix(2))
            let far = contact(99, 120, 0)
            try expectEqual(filter.update(contacts: two + [far]), .empty)
        }),

        ("four fingertips within link distance report zero", {
            var filter = ContactFilter()
            let four = [
                contact(1, 0, 0), contact(2, 30, 0), contact(3, 60, 0), contact(4, 90, 0),
            ]
            try expectEqual(filter.update(contacts: four), .empty)
        }),

        ("two separate three-finger clusters are ambiguous and report zero", {
            var filter = ContactFilter()
            let leftHand = threeFingers(ids: [1, 2, 3])
            let rightHand = [contact(4, 300, 0), contact(5, 330, 0), contact(6, 360, 0)]
            try expectEqual(filter.update(contacts: leftHand + rightHand), .empty)
        }),

        ("""
        a tracked cluster is followed as fingers lift one at a time, with a \
        resting far contact staying down throughout
        """, {
            var filter = ContactFilter()
            let far = contact(99, 300, 0)

            var frame = filter.update(contacts: threeFingers() + [far])
            try expectEqual(frame.fingerCount, 3)

            frame = filter.update(contacts: Array(threeFingers().prefix(2)) + [far])
            try expectEqual(frame.fingerCount, 2)

            frame = filter.update(contacts: Array(threeFingers().prefix(1)) + [far])
            try expectEqual(frame.fingerCount, 1)

            frame = filter.update(contacts: [far])
            try expectEqual(frame, .empty)
            try expect(filter.trackedIDs.isEmpty, "trackedIDs should be empty once the cluster fully lifts")
        }),

        ("a new finger landing next to a tracked cluster grows it, and lifting one shrinks it back", {
            var filter = ContactFilter()
            var frame = filter.update(contacts: threeFingers())
            try expectEqual(frame.fingerCount, 3)

            let fourth = contact(4, 90, 0)
            frame = filter.update(contacts: threeFingers() + [fourth])
            try expectEqual(frame.fingerCount, 4)

            frame = filter.update(contacts: threeFingers())
            try expectEqual(frame.fingerCount, 3)
        }),

        ("a tracked finger whose contact grows past the size limit is still counted while it stays down", {
            var filter = ContactFilter()
            var frame = filter.update(contacts: threeFingers())
            try expectEqual(frame.fingerCount, 3)

            let grown = [
                contact(1, 0, 0, majorAxis: 30), contact(2, 30, 0), contact(3, 60, 0),
            ]
            frame = filter.update(contacts: grown)
            try expectEqual(frame.fingerCount, 3)
        }),

        ("a broad but low contact the size of a thenar is not a finger", {
            // Measured on the Magic Trackpad: the thenar of a resting left
            // hand, major axis under the fingertip limit but twice the area.
            var filter = ContactFilter()
            let two = Array(threeFingers().prefix(2))
            let thenar = contact(99, 60, 0, majorAxis: 13, total: 1.5)
            try expectEqual(filter.update(contacts: two + [thenar]), .empty)
            try expectEqual(filter.update(contacts: threeFingers() + [thenar]).fingerCount, 3)
        }),

        ("the resting left hand from the contact log does not join the gesture", {
            // Frame from 2026-09-08 00:02:37: thumb pad, thenar and three
            // right-hand fingertips, positions and sizes as logged.
            var filter = ContactFilter()
            let frame = filter.update(contacts: [
                contact(1, -54.6, 33.8, majorAxis: 19.0, total: 3.08),
                contact(3, -19.4, 78.3, majorAxis: 16.8, total: 1.72),
                contact(4, 37.8, 67.1, majorAxis: 9.2, total: 0.38),
                contact(6, 15.0, 31.5, majorAxis: 9.1, total: 0.85),
                contact(9, 23.3, 54.1, majorAxis: 7.4, total: 0.23),
            ])
            try expectEqual(frame.fingerCount, 3)
            try expectEqual(filter.trackedIDs, [4, 6, 9])
        }),

        ("the config is the documented one", {
            let config = ContactFilter.Config()
            try expectEqual(config.fingers, 3)
            try expectEqual(config.maxFingerAxis, 14)
            try expectEqual(config.maxFingerSize, 1.2)
            try expectEqual(config.linkDistance, 40)
        }),

        ("chained contacts 0, 35 and 70mm apart still form one cluster of three", {
            var filter = ContactFilter()
            let chained = [contact(1, 0, 0), contact(2, 35, 0), contact(3, 70, 0)]
            let sum = summedPosition(chained)
            let frame = filter.update(contacts: chained)
            try expectEqual(frame.fingerCount, 3)
            try expectEqual(frame.sumX, sum.x)
            try expectEqual(frame.sumY, sum.y)
        }),

        ("reset clears trackedIDs", {
            var filter = ContactFilter()
            _ = filter.update(contacts: threeFingers())
            try expect(!filter.trackedIDs.isEmpty, "expected a tracked cluster before reset")
            filter.reset()
            try expect(filter.trackedIDs.isEmpty, "reset should clear trackedIDs")
        }),

        ("a quick three-finger tap through ContactFilter registers a middle click on lift", {
            var filter = ContactFilter()
            var detector = TapDetector()

            // A palm-sized contact rests nearby the whole time; it must never
            // be counted or affect the tap.
            let palm = contact(999, 30, 60, majorAxis: 30)

            var frame = filter.update(contacts: threeFingers() + [palm])
            try expectEqual(
                detector.update(
                    fingerCount: frame.fingerCount, sumX: frame.sumX, sumY: frame.sumY,
                    timestamp: 0),
                .none)

            frame = filter.update(contacts: [palm])
            try expectEqual(
                detector.update(
                    fingerCount: frame.fingerCount, sumX: frame.sumX, sumY: frame.sumY,
                    timestamp: 0.08),
                .middleClick)
        }),
    ]
}
