# Bench architecture

Bench is one menu-bar app made of four modules that used to be four apps:

| Module | Came from | Does |
|---|---|---|
| Shot  | Snapper (`../Snapper`) | screenshots, scrolling capture, annotation editor |
| Klip  | Klip (`../Klip`)       | clipboard history, folders, iCloud Drive sync |
| Lingo | Transi (`../Transi`)   | translation popup (Google, Bing, Gemini), OCR, speech |
| Snap  | new (replaces BetterTouchTool triggers) | window layout, previous window, titlebar double-click, two scripts |

Pure SwiftPM, macOS 14+, Swift 5 language mode. No Xcode on this Mac.

## Targets

```
Sources/
  BenchCore/      shared plumbing, the only module every other target imports
  BenchTestKit/   expect(), runSuites() - the no-XCTest test framework
  Shot/ Klip/ Lingo/ Snap/   one feature module each (library targets)
  Bench/          the app: entry point, status bar, Settings window, updater
  <Module>Tests/  one executable test runner per module (scripts/run_tests.sh)
```

Shot, Klip, Bench and the test runners compile with
`-default-isolation MainActor`; Lingo and BenchCore do not (they carry
explicit `@MainActor`). See `Package.swift`.

## The feature contract (`BenchCore/Feature.swift`)

Each module exposes exactly **one public type**, `<Module>Feature`, conforming
to `BenchFeature`. Everything else in the module stays `internal`, so two
modules can both have a `SettingsManager` or a `Theme` without colliding.

```swift
public protocol BenchFeature: AnyObject {
    var id: String { get }              // "shot" - prefixes every key and action id
    var title: String { get }           // "Shot"
    var symbolName: String { get }
    var summary: String { get }
    var requiredPermissions: [BenchPermission] { get }
    var hotkeyActions: [HotkeyAction] { get }
    func start()                        // enabled at launch, or switched on
    func stop()                         // switched off, or quitting
    func menuItems() -> [NSMenuItem]    // status bar section, rebuilt per open
    func makeSettingsView() -> AnyView  // the module's Settings pane
}
```

`FeatureRegistry.shared` owns the instances and the enabled flags
(`bench.feature.<id>.enabled`, default on). A stopped feature holds no
hotkeys, event taps, timers, windows or pasteboard polling.

## Global shortcuts

Modules never call Carbon. They declare `HotkeyAction`s (id `"<feature>.<name>"`,
title, default `KeyBinding` or nil for unbound) and in `start()` call

```swift
HotkeyCenter.shared.bind(action) { ... }             // follows ShortcutStore
HotkeyCenter.shared.bindFixed(id:binding:handler:)   // derived, e.g. Shot's ⌥ variants
HotkeyCenter.shared.unbindAll(featureID: id)         // in stop()
```

`ShortcutStore.shared` resolves each action to its effective binding (user
override, or default, or nil when the user cleared it), persists only the
overrides under `bench.shortcuts.*`, and refuses a combination any other
action in the whole app already owns. `HotkeyCenter` re-registers when the
store changes and publishes `failureMessages[id]` when macOS refused a
combination. `ShortcutRow(action:)` / `FeatureShortcutsSection(featureID:)`
are the reusable Settings rows.

## Preferences, files, imports

- `BenchDefaults.standard` is the `UserDefaults` to use (a test instance
  launched with `BENCH_DATA_DIR` gets its own suite).
- Every key is prefixed: `shot.`, `klip.`, `lingo.`, `snap.`, `bench.`.
- `BenchPaths.dataDirectory(feature: "Klip")` is
  `~/Library/Application Support/Bench/Klip`.
- First run imports from the standalone apps, copy-only, never touching
  them: `StandaloneImport.importDefaultsIfNeeded(sourceDomain:keys:flagKey:)`
  for preferences (`com.fxreza.klip`, `com.fxreza.snapper`, `com.fxreza.transi`)
  and `StandaloneImport.importDirectoryIfEmpty(from:to:)` for data folders.

## Permissions and appearance

`PermissionsState.shared` polls Accessibility and Screen Recording and
offers the system prompts; `SystemSettingsPane` deep-links. `LaunchAtLogin`
wraps `SMAppService`. `AppearanceSettings.shared` holds the app-wide accent
and light/dark choice and applies it to `NSApp`; `.benchAppearance()` applies
it to a SwiftUI root.

## Tests

`scripts/run_tests.sh` builds debug and runs every `<Module>Tests`
executable. Suites are `[(name, [(testName, () throws -> Void)])]` registered
by hand in each runner's `main.swift`; `@testable import <Module>` gives them
internal access.
