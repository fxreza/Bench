import AppKit
import SwiftUI
import BenchCore

/// Placeholder until the Snap module is ported. Replace this file with the
/// real feature; keep the type name and the id.
public final class SnapFeature: BenchFeature {
    public let id = "snap"
    public let title = "Snap"
    public let symbolName = "macwindow.on.rectangle"
    public let summary = "Window management"
    public let requiredPermissions: [BenchPermission] = []
    public let hotkeyActions: [HotkeyAction] = []

    public init() {}

    public func start() {}
    public func stop() {}
    public func menuItems() -> [NSMenuItem] { [] }
    public func makeSettingsView() -> AnyView {
        AnyView(Text("Snap is not ported yet.").padding())
    }
}
