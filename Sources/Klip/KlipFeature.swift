import AppKit
import SwiftUI
import BenchCore

/// Placeholder until the Klip module is ported. Replace this file with the
/// real feature; keep the type name and the id.
public final class KlipFeature: BenchFeature {
    public let id = "klip"
    public let title = "Klip"
    public let symbolName = "doc.on.clipboard"
    public let summary = "Clipboard history"
    public let requiredPermissions: [BenchPermission] = []
    public let hotkeyActions: [HotkeyAction] = []

    public init() {}

    public func start() {}
    public func stop() {}
    public func menuItems() -> [NSMenuItem] { [] }
    public func makeSettingsView() -> AnyView {
        AnyView(Text("Klip is not ported yet.").padding())
    }
}
