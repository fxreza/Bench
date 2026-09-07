# Attribution

Klip, the clipboard module of Bench, is built on and incorporates code from the
following open-source projects. This is the standalone Klip's attribution,
carried over unchanged below; note that inside Bench four of the Clipfield
ports listed (`Appearance.swift`, `HotkeyRecorder.swift`,
`PermissionsState.swift`, `OnboardingView.swift`) now live in `BenchCore` (or
the app shell) and carry the same attribution in their file headers there.

## Buffer

Copyright (c) 2026 Samir Patil

MIT License - see LICENSE file.

Klip is a fork of Buffer, incorporating the core clipboard manager architecture, pasteboard monitoring, and history management.

## Clipfield

Copyright (c) 2026 Alex Jolley

MIT License - see reference/clipfield/LICENSE.

Ported and adapted design tokens and UI components:
- `Views/Theme/Theme.swift` - design tokens (colors, gradients, border radius)
- `Views/Theme/Appearance.swift` - light/dark mode support, accent themes
- `Views/History/PanelResizer.swift` - sidebar resize control
- `Views/Settings/HotkeyRecorder.swift` - keyboard shortcut binding UI
- `Services/PermissionsState.swift` - Accessibility permission polling
- `Views/Permissions/OnboardingView.swift` - first-launch permission request
- `Services/PasteboardFlavors.swift` - rich text format detection and handling
- `Services/ContentDetector.swift` - link, email, phone, color, code detection heuristics

## Pesty

Copyright (c) 2026 Moamen Basel

MIT License - see reference/pesty/LICENSE.

iCloud Drive file sync approach: per-device snapshot files, content-hash deduplication, tombstone-based deletion tracking, and `NSFileCoordinator` coordination.
