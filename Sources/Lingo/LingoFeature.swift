import AppKit
import SwiftUI
import BenchCore

/// Placeholder until the Lingo module is ported. Replace this file with the
/// real feature; keep the type name and the id.
public final class LingoFeature: BenchFeature {
    public let id = "lingo"
    public let title = "Lingo"
    public let symbolName = "character.bubble"
    public let summary = "Translation"
    public let requiredPermissions: [BenchPermission] = []
    public let hotkeyActions: [HotkeyAction] = []

    public init() {}

    public func start() {}
    public func stop() {}
    public func menuItems() -> [NSMenuItem] { [] }
    public func makeSettingsView() -> AnyView {
        AnyView(Text("Lingo is not ported yet.").padding())
    }
}
