import AppKit
import SwiftUI
import BenchCore

/// Placeholder until the Piko module is ported. Replace this file with the
/// real feature; keep the type name and the id.
@MainActor
public final class PikoFeature: BenchFeature {
    public let id = "piko"
    public let title = "Piko"
    public let symbolName = "sparkles.rectangle.stack"
    public let summary = "Dynamic Island for the notch: HUDs, now playing, devices, battery"
    public let requiredPermissions: [BenchPermission] = []
    public let hotkeyActions: [HotkeyAction] = []

    public init() {}

    public func start() {}
    public func stop() {}
    public func menuItems() -> [NSMenuItem] { [] }
    public func makeSettingsView() -> AnyView {
        AnyView(Text("Piko is not ported yet.").padding())
    }
}
