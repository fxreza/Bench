import Foundation
import Carbon.HIToolbox
import BenchTestKit
import BenchCore
@testable import Klip

// The seams Bench added around Klip: the feature's contract, the `klip.`
// key namespace, the first-run import mapping, and the sync snapshot name
// that keeps Bench and a still-running standalone Klip apart.
enum KlipFeatureTests {
    static let tests: [(String, () throws -> Void)] = [
        ("feature_idTitleAndHotkeyAction", testFeatureContract),
        ("settingsKeys_allCarryTheKlipPrefix", testKeyPrefix),
        ("standaloneImport_mapsEveryKnownKey", testImportMap),
        ("standaloneImport_hotkeyTranslation", testHotkeyTranslation),
        ("cloudSync_deviceIDGetsTheBenchSuffix", testDeviceIDSuffix),
        ("menuItems_emptyUntilStarted", testMenuItemsBeforeStart),
    ]

    static func testFeatureContract() throws {
        let feature = KlipFeature()
        try expectEqual(feature.id, "klip")
        try expectEqual(feature.title, "Klip")
        try expectEqual(feature.requiredPermissions, [.accessibility])
        try expectEqual(feature.hotkeyActions.map { $0.id }, ["klip.toggleHistory"])
        try expectEqual(feature.hotkeyActions.first?.defaultBinding?.display, "⇧⌘V")
        try expect(feature.hotkeyActions.allSatisfy { $0.featureID == "klip" }, "every action belongs to klip")
    }

    static func testKeyPrefix() throws {
        try expectEqual(SettingsManager.Key.name("historyLimit"), "klip.historyLimit")
        for key in SettingsManager.standaloneKeys {
            try expect(!key.hasPrefix("klip."), "standalone key \(key) is stored unprefixed")
        }
    }

    static func testImportMap() throws {
        let map = KlipStandaloneImport.keyMap
        for key in SettingsManager.standaloneKeys {
            try expectEqual(map[key], "klip." + key, "\(key) maps to its prefixed form")
        }
        try expectEqual(map["shortcuts.bindings"], "klip.shortcuts.bindings")
        try expectEqual(map["hotkeyKeyCode"], KlipStandaloneImport.hotkeyKeyCodeKey)
        try expectEqual(map["hotkeyModifiers"], KlipStandaloneImport.hotkeyModifiersKey)
        try expect(map.values.allSatisfy { $0.hasPrefix("klip.") }, "every imported key lands under klip.")
    }

    static func testHotkeyTranslation() throws {
        try expectEqual(
            KlipStandaloneImport.importedHotkey(modifiers: ["shift", "command"], keyCode: 9),
            KeyBinding(kVK_ANSI_V, [.shift, .command])
        )
        try expectEqual(
            KlipStandaloneImport.importedHotkey(modifiers: ["control", "option"], keyCode: 8),
            KeyBinding(kVK_ANSI_C, [.control, .option])
        )
        try expectNil(KlipStandaloneImport.importedHotkey(modifiers: nil, keyCode: 9), "no stored modifiers, nothing to import")
        try expectNil(KlipStandaloneImport.importedHotkey(modifiers: ["command"], keyCode: nil), "no stored key code, nothing to import")
        try expectNil(KlipStandaloneImport.importedHotkey(modifiers: ["command"], keyCode: 0), "0 was Klip's 'unset' key code")
    }

    static func testDeviceIDSuffix() throws {
        try withTempDir { root in
            let cloud = root.appendingPathComponent("cloud", isDirectory: true)
            try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
            let sync = CloudDriveSync(cloudRoot: cloud)
            try expect(sync.deviceID.hasSuffix(CloudDriveSync.deviceIDSuffix),
                       "the app's own snapshot directory ends in -bench: \(sync.deviceID)")
            try expectEqual(sync.deviceID, SettingsManager.shared.syncDeviceID + "-bench")
            let explicit = CloudDriveSync(cloudRoot: cloud, deviceID: "device-X")
            try expectEqual(explicit.deviceID, "device-X", "an explicit id is used verbatim")
        }
    }

    static func testMenuItemsBeforeStart() throws {
        let feature = KlipFeature()
        try expect(feature.menuItems().isEmpty, "a stopped feature contributes no menu items")
    }
}
