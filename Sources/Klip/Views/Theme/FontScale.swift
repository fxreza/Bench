// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley)

import SwiftUI

/// Named font roles used throughout Klip's list and preview UI. Base sizes
/// mirror the ~60 hardcoded `.font(.system(size:))` literals currently
/// scattered across `HistoryWindow.swift` / `ClipboardItemRow.swift` /
/// `TagChip.swift` (see docs/analysis/buffer.md change map F); Phase 2/3H
/// replace those literals with `Font.klip(_:)` calls so they track the
/// user's "List text size" / "Preview text size" settings. This file only
/// defines the scale — it does not sweep the existing views.
enum KlipFontRole {
    case sidebarTitle
    case sidebar
    case sectionHeader
    case chip
    case rowTitle
    case rowTitleMono
    case rowSubtitle
    case caption
    case preview
    case previewMono
    case badge

    /// Base point size at 100% scale.
    var baseSize: CGFloat {
        switch self {
        case .sidebarTitle: return 15
        case .sidebar: return 13
        case .sectionHeader: return 10
        case .chip: return 11
        case .rowTitle: return 13
        case .rowTitleMono: return 12.5
        case .rowSubtitle: return 11
        case .caption: return 10
        case .preview: return 13
        case .previewMono: return 12.5
        case .badge: return 10
        }
    }

    /// `true` for roles that live in the preview pane and therefore scale
    /// with `previewFontScale` instead of `listFontScale`.
    var isPreviewRole: Bool {
        switch self {
        case .preview, .previewMono: return true
        default: return false
        }
    }

    var isMonospaced: Bool {
        switch self {
        case .rowTitleMono, .previewMono: return true
        default: return false
        }
    }
}

extension Font {
    /// Font for a given role, scaled by the user's list/preview font-size setting.
    @MainActor static func klip(_ role: KlipFontRole) -> Font {
        let settings = SettingsManager.shared
        let scale = role.isPreviewRole ? settings.previewFontScale : settings.listFontScale
        let size = role.baseSize * scale
        return role.isMonospaced ? .system(size: size, design: .monospaced) : .system(size: size)
    }
}

extension CGFloat {
    /// Scales a base frame/padding value (row height, badge size, icon frame,
    /// ...) by the list or preview font-size setting, so layout metrics that
    /// must track the text size stay proportional to it.
    @MainActor static func klipScaled(_ base: CGFloat, preview: Bool = false) -> CGFloat {
        let settings = SettingsManager.shared
        let scale = preview ? settings.previewFontScale : settings.listFontScale
        return base * scale
    }
}
