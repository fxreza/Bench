# Changelog

## 0.3.1 (2026-09-10)

### Added

- Klip: the history window can be dragged around by any part of it that nothing else uses (the title, the gaps around the search field and filter chips, the action bar). Clip rows, the scroll areas and the pane resizers keep their own behaviour.
- Klip: a "Remember the last window position" setting under Settings > Klip > General > Window, off by default. Off, every open puts the window back at its default spot, centred on the screen under the mouse. On, the window reopens where it was last dragged to, nudged back onto the nearest screen if that display has since gone away; switching the setting off clears the saved position.

## 0.3.0 (2026-09-08)

### Fixed

- Klip: icon-only buttons (copy, delete, pin, favorite, lock, extract text, save to disk, sidebar and preview toggles) told their available and disabled states apart with `.secondary`/`.tertiary` opacity, which read as too faint in both light and dark mode to make the glyph out. They now use weight together with a fixed `Color.primary` opacity: bold and near-full opacity when available, regular weight and dimmer when disabled. Disabled preview-pane buttons switch to a no-op action instead of `.disabled()`, which on macOS 26 dimmed the label a second time on top of the new color and made the glyph unreadable.

## 0.2.1 (2026-09-08)

### Added

- Tap: hold fn and click normally for a middle click, on by default and independent of the three-finger triggers, so any combination of the three can be on. It counts no fingers, so it works whenever the trackpad gesture will not; fn is the one modifier a click has spare, with Command, Shift, Option and Control all meaning something already.
- Tap: a three-finger click that the trackpad driver reports as a two-finger secondary click is converted too, instead of passing through and opening a context menu.

### Fixed

- Bench no longer quits at launch on any Mac other than the one it was built on. Piko looked up its now-playing resources through SwiftPM's generated `Bundle.module`, which trapped when neither the app root nor the build machine's build directory held the bundle; the lookup now returns nil and only turns now playing off.

## 0.2.0 (2026-09-08)

### Added

- Tap: a new module that turns three fingers on the trackpad into the middle mouse button, by clicking with three fingers down, by a quick three-finger tap, or both (Settings > Tap). It replaces the last BetterTouchTool trigger. Palm rejection runs on the raw touch stream: hovering contacts, palms and the base of the thumb are dropped, and only a tight three-finger cluster of one hand counts, so a hand resting elsewhere on the pad neither cancels the gesture nor fires it by accident.
- Snap: hold Shift+Option and move the mouse to move the window under the pointer, or Shift+Control to resize it, without clicking. Modifiers, drag threshold and bring-to-front are in Settings > Snap.
- Snap: three Open App shortcuts. Pick an app in Settings > Snap, then bind a key in the shortcut list.
- Shot: files are named after the app that was captured, for example "Safari 2026-09-08 at 14.03.10.png" (Settings > Shot > General, on by default), and saved files get a Finder "Where from" entry naming that app.
- Klip: a clip copied from a screenshot is credited to the app that was captured instead of Bench.
- General settings: Dock gaps. Two steppers add or remove macOS's own invisible Dock spacer tiles, full and half width, to drag between icons.
- General settings: menu bar divider lines, thin inert items to Command-drag between menu bar icons to group them.

### Changed

- Snap: New Terminal Window and Open Downloads in Finder moved from Control+Command+T and Command+E to Control+Option+T and Control+Option+E, out of the way of the window-layout shortcuts and the system Command+E.

### Fixed

- Klip: a screenshot or any other clip taken shortly after pasting from the history was sometimes dropped. The "ignore my own write" flag now expires after 1.5 seconds.
- Klip: Shift+Up and Shift+Down in the history list keep a fixed anchor and shrink the selection again when walking back, like Finder and Mail.

## 0.1.0 (2026-09-07)

### Fixed

- Piko no longer slows the menu bar. Its notch used a system-wide mouse-moved event monitor that throttled menu highlighting while any menu was open; it now samples the pointer on a timer with no event tap, so menus track the pointer at full speed.

### Added

- Bench: one menu bar app hosting five modules - Shot (screenshots), Klip (clipboard history), Lingo (translation), Snap (window management) and Piko (Dynamic Island for the notch).
- Snap: window layouts, restore, previous window and the two scripts, replacing the BetterTouchTool triggers. See docs/snap.md.
- Status menu with a section per module, Settings, Permissions, Check for Updates, Launch at Login and the running version.
- Settings window: General, Shortcuts, Permissions and About, plus one pane per module with its own on/off switch. A module that is off holds no shortcuts, timers or windows.
- One shortcut store for the whole app: every module's global shortcuts in one list, rebindable, with conflicts checked across modules and macOS refusals reported on the row.
- Appearance: an app-wide accent color and Light/Dark/System choice.
- In-app updater: checks GitHub releases once a day, verifies that a downloaded build carries Bench's bundle identifier and the same signing identity as the running copy before installing, and shows what changed after it relaunches.
- First launch registers Launch at Login and opens Permissions when Accessibility or Screen Recording is missing.
- A one-time warning when Klip, Snapper, Transi or Piko are still running, since they register the same shortcuts Bench does.
- Copy-only import of the standalone apps' settings and data on first launch; Klip, Snapper, Transi and Piko are never written to.
