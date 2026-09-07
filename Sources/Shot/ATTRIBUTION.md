# Attribution - Shot

Shot is the standalone macOS app **Snapper** ported into Bench as one feature
module.

## Snapper

Copyright (c) 2026 Sam Reza

MIT License - https://github.com/fxreza/snapper

Everything in `Sources/Shot` comes from Snapper's committed source, with the
app plumbing removed (Bench provides it) and the module boundaries applied:

- `Models/Annotation.swift`, `Models/AnnotationDocument.swift`,
  `Models/AnnotationStyle.swift`, `Models/CaptureResult.swift`
- `Services/Capture/*` (`CaptureCoordinator`, `ScreenCapturer`,
  `ScrollCaptureSession`, `ScrollStitcher`, `TextRecognizer`,
  `WindowEnumerator`)
- `Services/Export/*` (`EditorActions`, `ImageExporter`, `ImageFlattener`)
- `Services/ScreenshotDefaults.swift`
- `Services/SettingsManager.swift` (keys re-prefixed `shot.`, hotkey storage
  handed to `BenchCore.ShortcutStore`, app-level settings removed)
- `Views/Canvas/*`, `Views/Editor/*`, `Views/Overlay/*`,
  `Views/ScrollCapture/*`
- `Views/Theme/Theme.swift` (accent now read from
  `BenchCore.AppearanceSettings`)
- `Views/Settings/GeneralTab.swift`, `Views/Settings/ShortcutsTab.swift`,
  `Views/Settings/AppearanceTab.swift`
- `ShotFeature.swift` replaces Snapper's `AppDelegate.swift` and
  `Views/StatusBarController.swift`
- `Sources/ShotTests/*` are Snapper's `Tests/*` suites, running on
  `BenchTestKit` instead of Snapper's own `Tests/TestRunner.swift`

## Upstreams Snapper itself credited

Snapper ported a handful of platform-integration services from **Klip**
(MIT, Copyright 2026 Sam Reza - https://github.com/fxreza/klip). Of those,
the ones that survive inside Shot are:

- `Views/Theme/Theme.swift`

The rest of Snapper's Klip-derived files - `SnapperDefaults.swift`,
`UpdateService.swift`, `ChangelogService.swift`, `HotkeyManager.swift`,
`SystemHotkeys.swift`, `PermissionsState.swift`,
`Views/Theme/Appearance.swift`, `Views/Settings/HotkeyRecorder.swift`,
`Tests/TestRunner.swift` - are not part of this module: BenchCore and
BenchTestKit carry the shared versions, and they credit the same upstreams.

Klip itself ported some of that code from **Clipfield** (MIT, Copyright 2026
Alex Jolley), so `Theme.swift` traces back there too.

## Studied for behaviour only - no code copied

Carried over from Snapper's own attribution; these projects were read to
understand how they behave, not for their source. Nothing in Shot is derived
from their code:

- **MacShot** (GPLv3)
- **Capso** (Business Source License 1.1 - forbids screenshot-app derivatives)
- **Shottr** (closed source; behaviour reverse-engineered from screenshots,
  UserDefaults keys and binary strings only)
