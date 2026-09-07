# Changelog

## 0.1.0 (2026-09-07)

### Added

- Bench: one menu bar app hosting four modules - Shot (screenshots), Klip (clipboard history), Lingo (translation) and Snap (window management).
- Status menu with a section per module, Settings, Permissions, Check for Updates, Launch at Login and the running version.
- Settings window: General, Shortcuts, Permissions and About, plus one pane per module with its own on/off switch. A module that is off holds no shortcuts, timers or windows.
- One shortcut store for the whole app: every module's global shortcuts in one list, rebindable, with conflicts checked across modules and macOS refusals reported on the row.
- Appearance: an app-wide accent color and Light/Dark/System choice.
- In-app updater: checks GitHub releases once a day, verifies that a downloaded build carries Bench's bundle identifier and the same signing identity as the running copy before installing, and shows what changed after it relaunches.
- First launch registers Launch at Login and opens Permissions when Accessibility or Screen Recording is missing.
- A one-time warning when Klip, Snapper or Transi are still running, since they register the same shortcuts Bench does.
- Copy-only import of the standalone apps' settings and data on first launch; Klip, Snapper and Transi are never written to.
