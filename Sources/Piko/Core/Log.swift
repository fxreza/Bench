import Foundation
import os

/// Piko's log categories. The subsystem is Bench's; the categories keep the
/// module's own prefix so `log show --predicate 'category BEGINSWITH "piko."'`
/// still isolates this module.
enum Log {
    private static let subsystem = "com.fxreza.bench"

    static let notch = Logger(subsystem: subsystem, category: "piko.notch")
    static let hud = Logger(subsystem: subsystem, category: "piko.hud")
    static let media = Logger(subsystem: subsystem, category: "piko.media")
    static let devices = Logger(subsystem: subsystem, category: "piko.devices")
    static let app = Logger(subsystem: subsystem, category: "piko.app")
}
