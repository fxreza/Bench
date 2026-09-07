import AppKit
import SwiftUI
import BenchCore

/// Placeholder until the Shot module is ported. Replace this file with the
/// real feature; keep the type name and the id.
public final class ShotFeature: BenchFeature {
    public let id = "shot"
    public let title = "Shot"
    public let symbolName = "camera.viewfinder"
    public let summary = "Screenshots and annotation"
    public let requiredPermissions: [BenchPermission] = []
    public let hotkeyActions: [HotkeyAction] = []

    public init() {}

    public func start() {}
    public func stop() {}
    public func menuItems() -> [NSMenuItem] { [] }
    public func makeSettingsView() -> AnyView {
        AnyView(Text("Shot is not ported yet.").padding())
    }
}
